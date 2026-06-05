defmodule ExOpcUA.Server.Connection do
  @moduledoc """
  One GenServer per connected OPC UA client.

  Responsibilities:
  - TCP recv loop (active: :once pattern)
  - UA-TCP HEL/ACK handshake
  - Chunk reassembly per request_id
  - OpenSecureChannel (SecurityMode=None)
  - Session lifecycle (CreateSession, ActivateSession, CloseSession)
  - Service dispatch to ExOpcUA.Services.*
  - Subscription Publish loop via timer

  The secure channel state machine is simple for SecurityMode=None:
  channel_id and token_id are assigned on OpenSecureChannel; all
  subsequent MSG chunks must carry matching channel_id.
  """

  use GenServer
  require Logger

  alias ExOpcUA.Codec.{Primitives, Types, Message, Services}
  alias ExOpcUA.Codec.Types.{NodeId, RequestHeader, ResponseHeader}
  alias ExOpcUA.Codec.Message.{Hello, Acknowledge, MsgChunk, SequenceHeader, SymmetricSecurityHeader, AsymmetricSecurityHeader}
  alias ExOpcUA.Codec.Services.{
    OpenSecureChannelRequest, OpenSecureChannelResponse, ChannelSecurityToken,
    GetEndpointsRequest, GetEndpointsResponse,
    FindServersRequest, FindServersResponse,
    CreateSessionRequest, CreateSessionResponse,
    ActivateSessionRequest, ActivateSessionResponse,
    ReadRequest, ReadResponse, WriteRequest, WriteResponse,
    BrowseRequest, BrowseResponse,
    CreateSubscriptionRequest, CreateSubscriptionResponse,
    CreateMonitoredItemsRequest, CreateMonitoredItemsResponse,
    PublishRequest, PublishResponse,
    NotificationMessage
  }

  @recv_timeout    30_000   # ms to wait for data before closing idle connection
  @session_timeout 600_000  # ms default session timeout
  @channel_lifetime 3_600_000  # ms

  # ── State ─────────────────────────────────────────────────────────────────────

  defstruct [
    # TCP
    socket:           nil,
    recv_buf:         <<>>,

    # Server config
    node_manager:     nil,
    server_config:    %{},

    # Negotiated transport limits
    send_buf_size:    65535,
    recv_buf_size:    65535,
    max_message_size: 0,
    max_chunk_count:  0,

    # Secure channel
    channel_state:    :awaiting_hello,   # :awaiting_hello | :open | :closed
    channel_id:       0,
    token_id:         0,
    channel_expires:  nil,
    sequence_number:  1,

    # Session
    session_state:    :none,   # :none | :created | :activated | :closed
    session_id:       nil,
    auth_token:       nil,
    session_timeout:  @session_timeout,
    session_timer:    nil,

    # In-flight chunk reassembly: %{request_id => [MsgChunk.t()]}
    pending_chunks:   %{},

    # Request counter for response correlation
    request_handle:   0,

    # Subscription state (owned by PublishEngine, queried here)
    subscriptions:    %{},   # sub_id => subscription state
    publish_queue:    :queue.new(),  # pending Publish requests
    next_sub_id:      1,
    next_mon_id:      1,
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # ── init ──────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %__MODULE__{
      socket:        Keyword.fetch!(opts, :socket),
      node_manager:  Keyword.fetch!(opts, :node_manager),
      server_config: Keyword.get(opts, :server_config, %{}),
      channel_id:    :rand.uniform(0xFFFFFFFF),
      session_id:    NodeId.numeric(0, :rand.uniform(0xFFFFFFFF)),
      auth_token:    NodeId.numeric(0, :rand.uniform(0xFFFFFFFF))
    }
    {:ok, state}
  end

  # ── Socket handoff ────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:socket_ready, state) do
    :inet.setopts(state.socket, [active: :once])
    {:noreply, state}
  end

  # ── TCP data ──────────────────────────────────────────────────────────────────

  def handle_info({:tcp, sock, data}, %{socket: sock} = state) do
    :inet.setopts(sock, [active: :once])
    buf = state.recv_buf <> data
    case process_buffer(buf, state) do
      {:ok, new_state}     -> {:noreply, new_state}
      {:error, reason}     ->
        Logger.warning("[ExOpcUA.Conn] Protocol error: #{inspect(reason)}, closing")
        send_error(state.socket, 0x80020000, "Protocol error: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, sock}, %{socket: sock} = state) do
    Logger.debug("[ExOpcUA.Conn] Client disconnected")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, sock, reason}, %{socket: sock} = state) do
    Logger.warning("[ExOpcUA.Conn] TCP error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  # ── Session timeout ───────────────────────────────────────────────────────────

  def handle_info(:session_timeout, state) do
    Logger.info("[ExOpcUA.Conn] Session timed out, closing")
    {:stop, :normal, state}
  end

  # ── Subscription publish trigger ──────────────────────────────────────────────

  def handle_info({:subscription_tick, sub_id}, state) do
    new_state = maybe_send_publish_response(sub_id, state)
    {:noreply, new_state}
  end

  # ── terminate ─────────────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    if state.session_timer, do: Process.cancel_timer(state.session_timer)
    :ok
  end

  # ── Buffer processing ─────────────────────────────────────────────────────────

  # Drain as many complete messages as possible from the buffer.
  defp process_buffer(<<>>, state), do: {:ok, %{state | recv_buf: <<>>}}
  defp process_buffer(buf, state) do
    case Message.decode_transport_header(buf) do
      {:error, :incomplete} ->
        {:ok, %{state | recv_buf: buf}}

      {:error, reason} ->
        {:error, reason}

      {:ok, msg_type, _is_final, _body} ->
        # Read the full framed message
        case extract_full_message(buf) do
          {:ok, msg_bytes, rest} ->
            case handle_message(msg_type, msg_bytes, state) do
              {:ok, new_state}  -> process_buffer(rest, new_state)
              {:error, _} = err -> err
            end

          {:incomplete} ->
            {:ok, %{state | recv_buf: buf}}
        end
    end
  end

  # Extract a complete length-framed message from buffer
  defp extract_full_message(<<_::24, _::8, size::little-32, _::binary>> = buf)
       when byte_size(buf) >= size do
    <<msg::binary-size(size), rest::binary>> = buf
    {:ok, msg, rest}
  end
  defp extract_full_message(_), do: {:incomplete}

  # ── Message routing ───────────────────────────────────────────────────────────

  defp handle_message(:hel, data, state) do
    case Message.decode_hello(data) do
      {:ok, %Hello{} = hello} -> handle_hello(hello, state)
      {:error, _} = err -> err
    end
  end

  defp handle_message(:opn, data, %{channel_state: cs} = state)
       when cs in [:awaiting_hello, :open] do
    case Message.decode_msg_chunk(data) do
      {:ok, chunk} -> handle_open_secure_channel(chunk, state)
      err -> err
    end
  end

  defp handle_message(:clo, data, state) do
    case Message.decode_msg_chunk(data) do
      {:ok, _chunk} -> {:ok, %{state | channel_state: :closed}}
      err -> err
    end
  end

  defp handle_message(:msg, data, state) do
    case Message.decode_msg_chunk(data) do
      {:ok, chunk} -> handle_msg_chunk(chunk, state)
      err -> err
    end
  end

  defp handle_message(type, _data, state) do
    Logger.warning("[ExOpcUA.Conn] Unexpected message type: #{inspect(type)}")
    {:ok, state}
  end

  # ── HEL / ACK ─────────────────────────────────────────────────────────────────

  defp handle_hello(%Hello{} = hello, %{channel_state: :awaiting_hello} = state) do
    Logger.debug("[ExOpcUA.Conn] HEL from #{inspect(hello.endpoint_url)}")
    ack = %Acknowledge{
      version:          0,
      recv_buf_size:    min(hello.send_buf_size, state.recv_buf_size),
      send_buf_size:    min(hello.recv_buf_size, state.send_buf_size),
      max_message_size: state.max_message_size,
      max_chunk_count:  state.max_chunk_count
    }
    tcp_send(state.socket, Message.encode_acknowledge(ack))
    {:ok, %{state |
      channel_state: :open,
      send_buf_size: ack.send_buf_size,
      recv_buf_size: ack.recv_buf_size
    }}
  end
  defp handle_hello(_hello, state) do
    send_error(state.socket, 0x80020000, "Unexpected HEL")
    {:error, :unexpected_hello}
  end

  # ── OpenSecureChannel ─────────────────────────────────────────────────────────

  defp handle_open_secure_channel(%MsgChunk{body: body, sequence_header: seq_hdr} = chunk, state) do
    # OPN body starts with a TypeId NodeId prefix — strip it before decoding,
    # same as dispatch_service does for MSG chunks.
    {_type_node_id, body_without_type_id} = Types.decode_node_id(body)

    case Services.decode(:open_secure_channel_req, body_without_type_id) do
      {:ok, %OpenSecureChannelRequest{} = req, _rest} ->
        token_id = state.token_id + 1
        expires  = DateTime.add(DateTime.utc_now(), @channel_lifetime, :millisecond)

        response = %OpenSecureChannelResponse{
          response_header: Services.ok_response_header(req.request_header.request_handle),
          server_protocol_version: 0,
          security_token: %ChannelSecurityToken{
            channel_id:       state.channel_id,
            token_id:         token_id,
            created_at:       DateTime.utc_now(),
            revised_lifetime: @channel_lifetime
          },
          server_nonce: :crypto.strong_rand_bytes(32)
        }

        send_service_response(state, chunk, :open_secure_channel_res, response, :opn)
        {:ok, %{state | token_id: token_id, channel_expires: expires}}

      {:error, reason} ->
        {:error, {:decode_failed, reason}}
    end
  end

  # ── Chunk reassembly ──────────────────────────────────────────────────────────

  defp handle_msg_chunk(%MsgChunk{sequence_header: seq_hdr, is_final: :abort} = chunk, state) do
    req_id = seq_hdr.request_id
    new_pending = Map.delete(state.pending_chunks, req_id)
    Logger.debug("[ExOpcUA.Conn] Chunk abort for request_id=#{req_id}")
    {:ok, %{state | pending_chunks: new_pending}}
  end

  defp handle_msg_chunk(%MsgChunk{sequence_header: seq_hdr, is_final: :continuation} = chunk, state) do
    req_id = seq_hdr.request_id
    existing = Map.get(state.pending_chunks, req_id, [])
    {:ok, %{state | pending_chunks: Map.put(state.pending_chunks, req_id, existing ++ [chunk])}}
  end

  defp handle_msg_chunk(%MsgChunk{sequence_header: seq_hdr, is_final: :final} = chunk, state) do
    req_id = seq_hdr.request_id
    all_chunks = Map.get(state.pending_chunks, req_id, []) ++ [chunk]
    new_pending = Map.delete(state.pending_chunks, req_id)

    case Message.reassemble(all_chunks) do
      {:ok, body} ->
        state2 = %{state | pending_chunks: new_pending}
        dispatch_service(body, chunk, state2)

      {:error, reason} ->
        {:error, {:reassembly_failed, reason}}
    end
  end

  # ── Service dispatch ──────────────────────────────────────────────────────────

  # Reads the TypeId NodeId prefix (first thing in the body after reassembly),
  # maps it to a service atom, delegates to the appropriate handler.

  defp dispatch_service(body, originating_chunk, state) do
    case Types.decode_node_id(body) do
      {%NodeId{type: type, id: type_id_int}, rest} when type in [:two_byte, :four_byte, :numeric] ->
        service = Services.from_type_id(type_id_int)
        handle_service(service, rest, originating_chunk, state)

      _ ->
        Logger.warning("[ExOpcUA.Conn] Could not decode service TypeId from body")
        {:ok, state}
    end
  end

  # ── Service handlers ──────────────────────────────────────────────────────────

  defp handle_service(:get_endpoints_req, body, chunk, state) do
    with {:ok, req, _} <- Services.decode(:get_endpoints_req, body) do
      response = build_get_endpoints_response(req, state)
      send_service_response(state, chunk, :get_endpoints_res, response)
      {:ok, state}
    end
  end

  defp handle_service(:find_servers_req, body, chunk, state) do
    with {:ok, req, _} <- Services.decode(:find_servers_req, body) do
      server_app = build_application_description(state)
      response = %FindServersResponse{
        response_header: Services.ok_response_header(req.request_header.request_handle),
        servers: [server_app]
      }
      send_service_response(state, chunk, :find_servers_res, response)
      {:ok, state}
    end
  end

  defp handle_service(:create_session_req, body, chunk, state) do
    with {:ok, req, _} <- Services.decode(:create_session_req, body) do
      timeout = min(req.requested_session_timeout, @session_timeout * 1.0)
      server_nonce = :crypto.strong_rand_bytes(32)

      response = %CreateSessionResponse{
        response_header:          Services.ok_response_header(req.request_header.request_handle),
        session_id:               state.session_id,
        authentication_token:     state.auth_token,
        revised_session_timeout:  timeout,
        server_nonce:             server_nonce,
        server_certificate:       nil,
        server_endpoints:         [build_endpoint_description(state)],
        server_signature:         %Services.SignatureData{}
      }

      send_service_response(state, chunk, :create_session_res, response)
      new_state = %{state |
        session_state: :created,
        session_timeout: round(timeout)
      }
      {:ok, new_state}
    end
  end

  defp handle_service(:activate_session_req, body, chunk, state) do
    with {:ok, req, _} <- Services.decode(:activate_session_req, body) do
      response = %ActivateSessionResponse{
        response_header: Services.ok_response_header(req.request_header.request_handle),
        server_nonce:    :crypto.strong_rand_bytes(32),
        results:         [],
        diagnostic_infos: []
      }
      send_service_response(state, chunk, :activate_session_res, response)

      timer = reset_session_timer(state)
      {:ok, %{state | session_state: :activated, session_timer: timer}}
    end
  end

  defp handle_service(:close_session_req, body, chunk, state) do
    with {:ok, req, _} <- Services.decode(:close_session_req, body) do
      response = %{response_header: Services.ok_response_header(req.request_header.request_handle)}
      send_service_response(state, chunk, :close_session_res, response)
      {:ok, %{state | session_state: :closed}}
    end
  end

  defp handle_service(:browse_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:browse_req, body) do
        results = Enum.map(req.nodes_to_browse, fn bd ->
          state.node_manager.handle_browse(bd)
        end)
        response = %BrowseResponse{
          response_header: Services.ok_response_header(req.request_header.request_handle),
          results: results
        }
        send_service_response(state, chunk, :browse_res, response)
        {:ok, state}
      end
    end, chunk, state)
  end

  defp handle_service(:read_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:read_req, body) do
        results = Enum.map(req.nodes_to_read, fn rvid ->
          state.node_manager.handle_read(rvid)
        end)
        response = %ReadResponse{
          response_header: Services.ok_response_header(req.request_header.request_handle),
          results: results
        }
        send_service_response(state, chunk, :read_res, response)
        {:ok, state}
      end
    end, chunk, state)
  end

  defp handle_service(:write_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:write_req, body) do
        results = Enum.map(req.nodes_to_write, fn wv ->
          state.node_manager.handle_write(wv)
        end)
        response = %WriteResponse{
          response_header: Services.ok_response_header(req.request_header.request_handle),
          results: results
        }
        send_service_response(state, chunk, :write_res, response)
        {:ok, state}
      end
    end, chunk, state)
  end

  defp handle_service(:create_subscription_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:create_subscription_req, body) do
        sub_id = state.next_sub_id
        interval = max(req.requested_publishing_interval, 50.0)
        lifetime = max(req.requested_lifetime_count, 3)
        keepalive = max(req.requested_max_keep_alive_count, 1)

        sub = %{
          id:                sub_id,
          publishing_interval: interval,
          lifetime_count:    lifetime,
          max_keep_alive:    keepalive,
          publishing_enabled: req.publishing_enabled,
          priority:          req.priority,
          monitored_items:   %{},
          sequence_number:   1,
          keep_alive_counter: keepalive,
          lifetime_counter:  lifetime,
          timer:             schedule_subscription_tick(sub_id, interval)
        }

        response = %CreateSubscriptionResponse{
          response_header:              Services.ok_response_header(req.request_header.request_handle),
          subscription_id:              sub_id,
          revised_publishing_interval:  interval,
          revised_lifetime_count:       lifetime,
          revised_max_keep_alive_count: keepalive
        }
        send_service_response(state, chunk, :create_subscription_res, response)
        {:ok, %{state |
          subscriptions: Map.put(state.subscriptions, sub_id, sub),
          next_sub_id: sub_id + 1
        }}
      end
    end, chunk, state)
  end

  defp handle_service(:create_monitored_items_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:create_monitored_items_req, body) do
        sub = Map.get(state.subscriptions, req.subscription_id)

        if sub == nil do
          send_fault(state, chunk, Primitives.status_bad_internal_error())
          {:ok, state}
        else
          {results, new_sub, next_mon_id} =
            Enum.reduce(req.items_to_create, {[], sub, state.next_mon_id},
              fn item, {acc, sub_acc, mon_id} ->
                si = item.requested_parameters.sampling_interval
                si = if si < 0, do: sub_acc.publishing_interval, else: max(si, 50.0)
                result = %Services.MonitoredItemCreateResult{
                  status_code:               0,
                  monitored_item_id:         mon_id,
                  revised_sampling_interval: si,
                  revised_queue_size:        max(item.requested_parameters.queue_size, 1)
                }
                mi = %{
                  id:             mon_id,
                  node_id:        item.item_to_monitor.node_id,
                  attribute_id:   item.item_to_monitor.attribute_id,
                  client_handle:  item.requested_parameters.client_handle,
                  sampling_interval: si,
                  monitoring_mode: item.monitoring_mode
                }
                new_items = Map.put(sub_acc.monitored_items, mon_id, mi)
                {acc ++ [result], %{sub_acc | monitored_items: new_items}, mon_id + 1}
              end)

          response = %CreateMonitoredItemsResponse{
            response_header: Services.ok_response_header(req.request_header.request_handle),
            results: results
          }
          send_service_response(state, chunk, :create_monitored_items_res, response)
          {:ok, %{state |
            subscriptions: Map.put(state.subscriptions, req.subscription_id, new_sub),
            next_mon_id: next_mon_id
          }}
        end
      end
    end, chunk, state)
  end

  defp handle_service(:publish_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:publish_req, body) do
        # Enqueue this Publish request; responses are sent on subscription tick
        new_queue = :queue.in({req, chunk}, state.publish_queue)
        {:ok, %{state | publish_queue: new_queue}}
      end
    end, chunk, state)
  end

  defp handle_service(:delete_subscriptions_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:delete_subscriptions_req, body) do
        {results, new_subs} =
          Enum.reduce(req.subscription_ids, {[], state.subscriptions},
            fn sid, {acc, subs} ->
              case Map.pop(subs, sid) do
                {nil, subs2}  -> {acc ++ [Primitives.status_bad_internal_error()], subs2}
                {sub, subs2}  ->
                  if sub.timer, do: Process.cancel_timer(sub.timer)
                  {acc ++ [0], subs2}
              end
            end)

        response = %{
          response_header: Services.ok_response_header(req.request_header.request_handle),
          results: results,
          diagnostic_infos: []
        }
        send_service_response(state, chunk, :delete_subscriptions_res, response)
        {:ok, %{state | subscriptions: new_subs}}
      end
    end, chunk, state)
  end

  defp handle_service(:browse_next_req, body, chunk, state) do
    require_session(state, fn ->
      with {:ok, req, _} <- Services.decode(:browse_next_req, body) do
        # We don't paginate in this implementation — return empty results
        response = %{
          response_header: Services.ok_response_header(req.request_header.request_handle),
          results: [],
          diagnostic_infos: []
        }
        send_service_response(state, chunk, :browse_next_res, response)
        {:ok, state}
      end
    end, chunk, state)
  end

  defp handle_service(nil, _body, chunk, state) do
    Logger.warning("[ExOpcUA.Conn] Unknown service TypeId")
    send_fault(state, chunk, Primitives.status_bad_service_unsupported())
    {:ok, state}
  end

  defp handle_service(service, _body, chunk, state) do
    Logger.debug("[ExOpcUA.Conn] Unhandled service: #{service}")
    send_fault(state, chunk, Primitives.status_bad_service_unsupported())
    {:ok, state}
  end

  # ── Publish tick ──────────────────────────────────────────────────────────────

  defp maybe_send_publish_response(sub_id, state) do
    sub = Map.get(state.subscriptions, sub_id)
    if sub == nil or not sub.publishing_enabled do
      reschedule_subscription(sub_id, sub, state)
    else
      case :queue.out(state.publish_queue) do
        {{:value, {_req, chunk}}, new_queue} ->
          # Collect current values from node_manager for all monitored items
          {notifications, has_changes} = collect_notifications(sub, state)

          if has_changes or sub.keep_alive_counter <= 1 do
            notif_msg = build_notification_message(sub, notifications)
            response = %PublishResponse{
              response_header:            Services.ok_response_header(0),
              subscription_id:            sub_id,
              available_sequence_numbers: [notif_msg.sequence_number],
              more_notifications:         false,
              notification_message:       notif_msg,
              results:                    [],
              diagnostic_infos:           []
            }
            send_service_response(state, chunk, :publish_res, response)
            new_seq = sub.sequence_number + 1
            new_sub = %{sub |
              sequence_number:    new_seq,
              keep_alive_counter: sub.max_keep_alive,
              lifetime_counter:   sub.lifetime_count
            }
            new_state = %{state |
              publish_queue:  new_queue,
              subscriptions:  Map.put(state.subscriptions, sub_id, new_sub)
            }
            reschedule_subscription(sub_id, new_sub, new_state)
          else
            new_sub = %{sub | keep_alive_counter: sub.keep_alive_counter - 1}
            new_state = %{state | subscriptions: Map.put(state.subscriptions, sub_id, new_sub)}
            reschedule_subscription(sub_id, new_sub, new_state)
          end

        {:empty, _} ->
          reschedule_subscription(sub_id, sub, state)
      end
    end
  end

  defp collect_notifications(sub, state) do
    Enum.reduce(sub.monitored_items, {[], false}, fn {_mid, mi}, {acc, changed} ->
      dv = state.node_manager.handle_read(%Services.ReadValueId{
        node_id: mi.node_id,
        attribute_id: mi.attribute_id
      })
      notif = %Services.MonitoredItemNotification{
        client_handle: mi.client_handle,
        value: dv
      }
      {acc ++ [notif], true}  # In a real impl, track last_value to only send on change
    end)
  end

  defp build_notification_message(sub, notifications) do
    data_change = %Services.DataChangeNotification{monitored_items: notifications}
    ext_obj = Services.encode_data_change_notification(data_change)
    %NotificationMessage{
      sequence_number:   sub.sequence_number,
      publish_time:      DateTime.utc_now(),
      notification_data: [ext_obj]
    }
  end

  # ── Response encoding & sending ───────────────────────────────────────────────

  defp send_service_response(state, originating_chunk, service_atom, response_struct, msg_type \\ :msg) do
    type_id = Services.type_id(service_atom)
    type_node_id = NodeId.ns0(type_id)

    body =
      Types.encode_node_id(type_node_id) <>
      Services.encode(service_atom, response_struct)

    seq_num = state.sequence_number
    req_id  = originating_chunk.sequence_header.request_id

    sec_hdr = case msg_type do
      :opn -> %AsymmetricSecurityHeader{}
      _    -> %SymmetricSecurityHeader{token_id: state.token_id}
    end

    chunk = %MsgChunk{
      msg_type:        msg_type,
      is_final:        :final,
      channel_id:      state.channel_id,
      security_header: sec_hdr,
      sequence_header: %SequenceHeader{sequence_number: seq_num, request_id: req_id},
      body:            body
    }

    tcp_send(state.socket, Message.encode_msg_chunk(chunk))
  end

  defp send_fault(state, originating_chunk, status_code) do
    req_handle = originating_chunk.sequence_header.request_id
    response   = %{response_header: Services.fault_response_header(req_handle, status_code)}
    send_service_response(state, originating_chunk, :service_fault, response)
  end

  defp send_error(socket, error_code, reason) do
    tcp_send(socket, Message.encode_error(error_code, reason))
  end

  defp tcp_send(socket, data) do
    case :gen_tcp.send(socket, data) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[ExOpcUA.Conn] Send failed: #{inspect(reason)}")
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp require_session(%{session_state: :activated} = state, fun, _chunk, _outer_state) do
    fun.()
  end
  defp require_session(_state, _fun, chunk, outer_state) do
    send_fault(outer_state, chunk, Primitives.status_bad_session_closed())
    {:ok, outer_state}
  end

  defp reset_session_timer(state) do
    if state.session_timer, do: Process.cancel_timer(state.session_timer)
    Process.send_after(self(), :session_timeout, state.session_timeout)
  end

  defp schedule_subscription_tick(sub_id, interval_ms) do
    Process.send_after(self(), {:subscription_tick, sub_id}, round(interval_ms))
  end

  defp reschedule_subscription(sub_id, sub, state) when sub != nil do
    timer = schedule_subscription_tick(sub_id, sub.publishing_interval)
    new_sub = %{sub | timer: timer}
    %{state | subscriptions: Map.put(state.subscriptions, sub_id, new_sub)}
  end
  defp reschedule_subscription(_sub_id, nil, state), do: state

  defp build_application_description(state) do
    cfg = state.server_config
    %Services.ApplicationDescription{
      application_uri:  Map.get(cfg, :application_uri, "urn:ExOpcUA:Server"),
      product_uri:      Map.get(cfg, :product_uri,     "urn:ex_opcua:0.1.0"),
      application_name: %Types.LocalizedText{locale: "en", text: Map.get(cfg, :application_name, "ExOpcUA Server")},
      application_type: 0,  # Server
      discovery_urls:   [endpoint_url(state)]
    }
  end

  defp build_endpoint_description(state) do
    %Services.EndpointDescription{
      endpoint_url:         endpoint_url(state),
      server:               build_application_description(state),
      security_mode:        1,   # None
      security_policy_uri:  "http://opcfoundation.org/UA/SecurityPolicy#None",
      user_identity_tokens: [
        %Services.UserTokenPolicy{policy_id: "anonymous", token_type: 0},
        %Services.UserTokenPolicy{policy_id: "username",  token_type: 1}
      ],
      security_level: 0
    }
  end

  defp build_get_endpoints_response(%GetEndpointsRequest{} = req, state) do
    %GetEndpointsResponse{
      response_header: Services.ok_response_header(req.request_header.request_handle),
      endpoints: [build_endpoint_description(state)]
    }
  end

  defp endpoint_url(state) do
    port = Map.get(state.server_config, :port, 4840)
    host = Map.get(state.server_config, :hostname, "localhost")
    "opc.tcp://#{host}:#{port}"
  end
end
