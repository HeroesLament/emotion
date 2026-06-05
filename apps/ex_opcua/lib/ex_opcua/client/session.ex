defmodule ExOpcUA.Client.Session do
  @moduledoc """
  Manages the OPC UA session handshake sequence and coordinates
  Transport, Channel, and SubManager.

  States:
    :disconnected  — waiting for Transport to connect
    :securing      — OPN sent, awaiting OpenSecureChannelResponse
    :creating      — CreateSession sent, awaiting response
    :activating    — ActivateSession sent, awaiting response
    :ready         — fully operational; forwards calls to Channel/SubManager

  Session owns no pending map. Each handshake state expects exactly one
  response type — no concurrency, no correlation needed.
  """

  @behaviour :gen_statem

  require Logger

  alias ExOpcUA.Codec.{Types, Services, Message}
  alias ExOpcUA.Codec.Types.NodeId
  alias ExOpcUA.Codec.Message.{MsgChunk, SequenceHeader, SymmetricSecurityHeader, AsymmetricSecurityHeader}
  alias ExOpcUA.Codec.Services.{
    OpenSecureChannelRequest, OpenSecureChannelResponse,
    CreateSessionRequest, CreateSessionResponse,
    ActivateSessionRequest, ActivateSessionResponse
  }

  defstruct [
    :url, :host, :port, :identity, :timeout,
    :transport, :channel, :sub_manager,
    # Handshake state
    channel_id:      0,
    token_id:        0,
    sequence_number: 1,
    request_id:      1,
    session_id:      nil,
    auth_token:      nil,
    server_nonce:    nil
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def read(pid, node_ids, attribute_id, timeout) do
    with_channel(pid, fn channel ->
      ExOpcUA.Client.Channel.read(channel, node_ids, attribute_id, timeout)
    end)
  end

  def write(pid, node_id, variant, timeout) do
    with_channel(pid, fn channel ->
      ExOpcUA.Client.Channel.write(channel, node_id, variant, timeout)
    end)
  end

  def browse(pid, node_id, opts, timeout) do
    with_channel(pid, fn channel ->
      ExOpcUA.Client.Channel.browse(channel, node_id, opts, timeout)
    end)
  end

  def subscribe(pid, node_ids, callback, opts) do
    with_sub_manager(pid, fn sm ->
      ExOpcUA.Client.SubManager.subscribe(sm, node_ids, callback, opts)
    end)
  end

  def unsubscribe(pid, sub_id, timeout) do
    with_sub_manager(pid, fn sm ->
      ExOpcUA.Client.SubManager.unsubscribe(sm, sub_id)
    end)
  end

  def disconnect(pid) do
    :gen_statem.call(pid, :disconnect)
  end

  def conn_state(pid) do
    :gen_statem.call(pid, :conn_state)
  end

  defp with_channel(pid, fun) do
    case :gen_statem.call(pid, :get_channel) do
      {:ok, channel} -> fun.(channel)
      err            -> err
    end
  end

  defp with_sub_manager(pid, fun) do
    case :gen_statem.call(pid, :get_sub_manager) do
      {:ok, sm} -> fun.(sm)
      err       -> err
    end
  end

  # ── gen_statem ────────────────────────────────────────────────────────────────

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)

    # Start children
    {:ok, transport}   = ExOpcUA.Client.Transport.start_link([url: url, session: self(), timeout: Keyword.get(opts, :timeout, 5_000)])
    {:ok, sub_manager} = ExOpcUA.Client.SubManager.start_link([transport: transport])
    {:ok, channel}     = ExOpcUA.Client.Channel.start_link([transport: transport, sub_manager: sub_manager])

    data = %__MODULE__{
      url:         url,
      identity:    Keyword.get(opts, :identity, :anonymous),
      timeout:     Keyword.get(opts, :timeout, 5_000),
      transport:   transport,
      channel:     channel,
      sub_manager: sub_manager
    }
    {:ok, :disconnected, data}
  end

  # ── State: disconnected ───────────────────────────────────────────────────────

  def disconnected(:enter, _old, _data), do: :keep_state_and_data

  def disconnected(:info, :transport_ready, data) do
    Logger.debug("[Session] Transport ready, opening secure channel")
    new_data = send_open_secure_channel(data)
    {:next_state, :securing, new_data}
  end

  def disconnected(:info, :transport_disconnected, _data), do: :keep_state_and_data
  def disconnected(:info, :transport_error, _data), do: :keep_state_and_data
  def disconnected(:info, {:frame, _, _}, _data), do: :keep_state_and_data

  def disconnected({:call, from}, :conn_state, _data) do
    {:keep_state_and_data, [{:reply, from, :disconnected}]}
  end
  def disconnected({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # ── State: securing ───────────────────────────────────────────────────────────

  def securing(:enter, _old, _data), do: :keep_state_and_data

  def securing(:info, {:frame, :opn, %MsgChunk{body: body}}, data) do
    # Strip TypeId before decode
    {_type_id, rest} = Types.decode_node_id(body)
    case Services.decode(:open_secure_channel_res, rest) do
      {:ok, res, _} ->
        token = res.security_token
        Logger.debug("[Session] Secure channel open, channel_id=#{token.channel_id}")
        new_data = %{data |
          channel_id: token.channel_id,
          token_id:   token.token_id
        }
        send_create_session(new_data)
        {:next_state, :creating, new_data}

      {:error, reason} ->
        Logger.warning("[Session] OpenSecureChannel failed: #{inspect(reason)}")
        {:next_state, :disconnected, data}
    end
  end

  def securing(:info, :transport_disconnected, data) do
    {:next_state, :disconnected, data}
  end

  def securing(:info, _, _data), do: :keep_state_and_data

  def securing({:call, from}, :conn_state, _data) do
    {:keep_state_and_data, [{:reply, from, :securing}]}
  end
  def securing({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # ── State: creating ───────────────────────────────────────────────────────────

  def creating(:enter, _old, _data), do: :keep_state_and_data

  def creating(:info, {:frame, :msg, %MsgChunk{body: body}}, data) do
    case dispatch_body(body) do
      {:create_session_res, rest} ->
        case Services.decode(:create_session_res, rest) do
          {:ok, res, _} ->
            Logger.debug("[Session] Session created, activating")
            new_data = %{data |
              session_id:   res.session_id,
              auth_token:   res.authentication_token,
              server_nonce: res.server_nonce
            }
            send_activate_session(new_data)
            {:next_state, :activating, new_data}

          {:error, reason} ->
            Logger.warning("[Session] CreateSession failed: #{inspect(reason)}")
            {:next_state, :disconnected, data}
        end

      _ ->
        :keep_state_and_data
    end
  end

  def creating(:info, :transport_disconnected, data) do
    {:next_state, :disconnected, data}
  end

  def creating(:info, _, _data), do: :keep_state_and_data

  def creating({:call, from}, :conn_state, _data) do
    {:keep_state_and_data, [{:reply, from, :creating}]}
  end
  def creating({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # ── State: activating ─────────────────────────────────────────────────────────

  def activating(:enter, _old, _data), do: :keep_state_and_data

  def activating(:info, {:frame, :msg, %MsgChunk{body: body}}, data) do
    case dispatch_body(body) do
      {:activate_session_res, _rest} ->
        Logger.info("[Session] Session activated — ready")
        # Activate Channel and SubManager with credentials
        ExOpcUA.Client.Channel.activate(
          data.channel, data.channel_id, data.token_id,
          data.session_id, data.auth_token
        )
        ExOpcUA.Client.SubManager.activate(
          data.sub_manager, data.channel_id, data.token_id, data.auth_token
        )
        {:next_state, :ready, data}

      _ ->
        :keep_state_and_data
    end
  end

  def activating(:info, :transport_disconnected, data) do
    {:next_state, :disconnected, data}
  end

  def activating(:info, _, _data), do: :keep_state_and_data

  def activating({:call, from}, :conn_state, _data) do
    {:keep_state_and_data, [{:reply, from, :activating}]}
  end
  def activating({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # ── State: ready ──────────────────────────────────────────────────────────────

  def ready(:enter, _old, _data), do: :keep_state_and_data

  @sub_services [:create_subscription_res, :create_monitored_items_res,
                 :delete_subscriptions_res, :publish_res, :service_fault]

  # Route MSG frames — sub-related go to SubManager, everything else to Channel
  def ready(:info, {:frame, :msg, %MsgChunk{body: body} = chunk}, data) do
    case dispatch_body(body) do
      {service, rest} when service in @sub_services ->
        ExOpcUA.Client.SubManager.handle_frame(data.sub_manager, service, rest)
      {_service, _} ->
        ExOpcUA.Client.Channel.handle_frame(data.channel, chunk)
    end
    :keep_state_and_data
  end

  def ready(:info, :transport_disconnected, data) do
    Logger.info("[Session] Disconnected, resetting")
    ExOpcUA.Client.Channel.flush(data.channel)
    ExOpcUA.Client.SubManager.deactivate(data.sub_manager)
    reset_data = %{data |
      channel_id:      0,
      token_id:        0,
      sequence_number: 1,
      request_id:      1,
      session_id:      nil,
      auth_token:      nil,
      server_nonce:    nil
    }
    {:next_state, :disconnected, reset_data}
  end

  def ready(:info, :transport_error, data) do
    # Treat same as disconnect
    ready(:info, :transport_disconnected, data)
  end

  def ready(:info, _, _data), do: :keep_state_and_data

  def ready({:call, from}, :conn_state, _data) do
    {:keep_state_and_data, [{:reply, from, :ready}]}
  end

  def ready({:call, from}, :get_channel, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.channel}}]}
  end

  def ready({:call, from}, :get_sub_manager, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.sub_manager}}]}
  end

  def ready({:call, from}, :disconnect, data) do
    send_close_session(data)
    ExOpcUA.Client.Channel.flush(data.channel)
    ExOpcUA.Client.SubManager.deactivate(data.sub_manager)
    {:next_state, :disconnected, data, [{:reply, from, :ok}]}
  end

  def ready({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :use_channel_directly}}]}
  end

  # ── Handshake senders ─────────────────────────────────────────────────────────

  defp send_open_secure_channel(data) do
    req = %OpenSecureChannelRequest{
      request_header:          make_request_header(data),
      client_protocol_version: 0,
      request_type:            0,
      security_mode:           1,
      client_nonce:            :crypto.strong_rand_bytes(32),
      requested_lifetime:      3_600_000
    }
    send_raw(:open_secure_channel_req, req, data, :opn)
  end

  defp send_create_session(data) do
    req = %CreateSessionRequest{
      request_header:            make_request_header(data),
      client_description:        client_app_description(),
      endpoint_url:              data.url,
      session_name:              "ExOpcUA-#{:erlang.unique_integer([:positive])}",
      client_nonce:              :crypto.strong_rand_bytes(32),
      requested_session_timeout: 600_000.0,
      max_response_message_size: 0
    }
    send_raw(:create_session_req, req, data, :msg)
  end

  defp send_activate_session(data) do
    identity_token = case data.identity do
      :anonymous        -> Services.anonymous_identity_token()
      {:username, u, p} -> Services.username_identity_token("username", u, p)
    end
    req = %ActivateSessionRequest{
      request_header:      make_request_header(data),
      client_signature:    %Services.SignatureData{},
      locale_ids:          ["en"],
      user_identity_token: identity_token
    }
    send_raw(:activate_session_req, req, data, :msg)
  end

  defp send_close_session(data) do
    req = %{request_header: make_request_header(data), delete_subscriptions: true}
    send_raw(:close_session_req, req, data, :msg)
  end

  # Fire-and-forget send; returns updated data (seq/request_id bumped)
  defp send_raw(service_atom, req_struct, data, msg_type) do
    type_id   = Services.type_id(service_atom)
    type_node = NodeId.ns0(type_id)
    body      = Types.encode_node_id(type_node) <> Services.encode(service_atom, req_struct)

    sec_hdr = case msg_type do
      :opn -> %AsymmetricSecurityHeader{}
      _    -> %SymmetricSecurityHeader{token_id: data.token_id}
    end

    chunk = %MsgChunk{
      msg_type:        msg_type,
      is_final:        :final,
      channel_id:      data.channel_id,
      security_header: sec_hdr,
      sequence_header: %SequenceHeader{
        sequence_number: data.sequence_number,
        request_id:      data.request_id
      },
      body: body
    }

    ExOpcUA.Client.Transport.send_bytes(data.transport, Message.encode_msg_chunk(chunk))

    %{data |
      sequence_number: data.sequence_number + 1,
      request_id:      data.request_id + 1
    }
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp dispatch_body(body) do
    case Types.decode_node_id(body) do
      {%NodeId{type: type, id: type_id_int}, rest} when type in [:two_byte, :four_byte, :numeric] ->
        {Services.from_type_id(type_id_int), rest}
      _ ->
        {:unknown, body}
    end
  end

  defp make_request_header(data) do
    %Types.RequestHeader{
      auth_token:     data.auth_token || NodeId.ns0(0),
      timestamp:      DateTime.utc_now(),
      request_handle: data.request_id,
      timeout_hint:   10_000
    }
  end

  defp client_app_description do
    %Services.ApplicationDescription{
      application_uri:  "urn:ExOpcUA:Client",
      product_uri:      "urn:ex_opcua:0.1.0",
      application_name: %Types.LocalizedText{locale: "en", text: "ExOpcUA Client"},
      application_type: 1
    }
  end
end
