defmodule ExOpcUA.Client.Channel do
  @moduledoc """
  Handles synchronous service calls (Read, Write, Browse) over an established
  session. Enforces exactly one in-flight request at a time per caller via
  gen_statem states:

    :idle     — ready to accept a call
    :waiting  — request sent, awaiting response; new calls queue behind

  Request/response correlation uses request_handle (echoed in response header)
  decoded directly from the response body — no "pop oldest" guessing.

  Publish responses are forwarded to SubManager and never touch the pending state.
  """

  @behaviour :gen_statem

  require Logger

  alias ExOpcUA.Codec.{Types, Services, Message}
  alias ExOpcUA.Codec.Types.NodeId
  alias ExOpcUA.Codec.Message.{MsgChunk, SequenceHeader, SymmetricSecurityHeader, AsymmetricSecurityHeader}
  alias ExOpcUA.Codec.Services.{
    ReadRequest, ReadValueId,
    WriteRequest, WriteValue,
    BrowseRequest, BrowseDescription
  }
  alias ExOpcUA.Codec.Types.{DataValue}

  @request_timeout 10_000

  defstruct [
    :transport,
    :sub_manager,
    # Session credentials (set on :activate)
    channel_id:      0,
    token_id:        0,
    sequence_number: 1,
    request_id:      1,
    session_id:      nil,
    auth_token:      nil,
    # Current in-flight: {from, request_handle, timer_ref}
    inflight:        nil,
    # Queued calls while waiting: [{from, service_atom, encoded_body}]
    queue:           :queue.new()
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def activate(pid, channel_id, token_id, session_id, auth_token) do
    :gen_statem.call(pid, {:activate, channel_id, token_id, session_id, auth_token})
  end

  def read(pid, node_ids, attribute_id, timeout) do
    :gen_statem.call(pid, {:read, node_ids, attribute_id}, timeout)
  end

  def write(pid, node_id, variant, timeout) do
    :gen_statem.call(pid, {:write, node_id, variant}, timeout)
  end

  def browse(pid, node_id, opts, timeout) do
    :gen_statem.call(pid, {:browse, node_id, opts}, timeout)
  end

  # Called by Session when a MSG frame arrives
  def handle_frame(pid, chunk) do
    :gen_statem.cast(pid, {:frame, chunk})
  end

  # Called by Session on disconnect — flush pending with error
  def flush(pid) do
    :gen_statem.cast(pid, :flush)
  end

  # ── gen_statem ────────────────────────────────────────────────────────────────

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    data = %__MODULE__{
      transport:   Keyword.fetch!(opts, :transport),
      sub_manager: Keyword.fetch!(opts, :sub_manager)
    }
    {:ok, :idle, data}
  end

  # ── State: idle ───────────────────────────────────────────────────────────────

  def idle(:enter, _old, _data), do: :keep_state_and_data

  def idle({:call, from}, {:activate, ch, tok, sid, auth}, data) do
    new_data = %{data |
      channel_id:  ch,
      token_id:    tok,
      session_id:  sid,
      auth_token:  auth
    }
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def idle({:call, from}, req, data) do
    case build_request(req, data) do
      {:ok, service_atom, req_struct, new_data} ->
        {handle, new_data2} = send_service(service_atom, req_struct, new_data)
        timer = Process.send_after(self(), {:request_timeout, handle}, @request_timeout)
        inflight = {from, handle, timer}
        {:next_state, :waiting, %{new_data2 | inflight: inflight}}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def idle(:cast, {:frame, chunk}, data) do
    # Could be a publish response — forward to sub_manager
    maybe_forward_publish(chunk, data)
    :keep_state_and_data
  end

  def idle(:internal, :drain, data), do: drain_queue(data)

  def idle(:cast, :flush, _data), do: :keep_state_and_data
  def idle(:info, {:request_timeout, _}, _data), do: :keep_state_and_data

  # ── State: waiting ────────────────────────────────────────────────────────────

  def waiting(:enter, _old, _data), do: :keep_state_and_data

  # Queue new service calls while waiting
  def waiting({:call, from}, {:activate, ch, tok, sid, auth}, data) do
    new_data = %{data | channel_id: ch, token_id: tok, session_id: sid, auth_token: auth}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def waiting({:call, from}, req, data) do
    # Queue it — we'll drain after response
    new_queue = :queue.in({from, req}, data.queue)
    {:keep_state, %{data | queue: new_queue}}
  end

  def waiting(:cast, {:frame, chunk}, data) do
    case decode_response_handle(chunk.body) do
      {:service, service, body, handle} ->
        process_response(service, body, handle, chunk, data)
      :unknown ->
        Logger.warning("[Channel] Could not decode response TypeId")
        :keep_state_and_data
    end
  end

  def waiting(:cast, :flush, data) do
    flush_inflight(data, {:error, :disconnected})
    {:next_state, :idle, %{data | inflight: nil, queue: :queue.new()}}
  end

  def waiting(:info, {:request_timeout, handle}, data) do
    case data.inflight do
      {from, ^handle, _timer} ->
        :gen_statem.reply(from, {:error, :timeout})
        new_data = %{data | inflight: nil}
        {:next_state, :idle, new_data, [{:next_event, :internal, :drain}]}
      _ ->
        :keep_state_and_data
    end
  end

  def waiting(:internal, :drain, data), do: drain_queue(data)

  # ── Response processing ───────────────────────────────────────────────────────

  defp process_response(service, body, handle, chunk, data) do
    case data.inflight do
      {from, ^handle, timer} ->
        Process.cancel_timer(timer)
        reply = dispatch_service_response(service, body)
        :gen_statem.reply(from, reply)
        new_data = %{data | inflight: nil}
        drain_queue(new_data)

      {_from, other_handle, _timer} ->
        # Handle mismatch — could be a publish response
        Logger.debug("[Channel] Handle mismatch: expected #{other_handle}, got #{handle}")
        maybe_forward_publish(chunk, data)
        :keep_state_and_data

      nil ->
        maybe_forward_publish(chunk, data)
        :keep_state_and_data
    end
  end

  defp dispatch_service_response(:read_res, body) do
    case Services.decode(:read_res, body) do
      {:ok, res, _} -> {:ok, res.results}
      {:error, r}   -> {:error, r}
    end
  end

  defp dispatch_service_response(:write_res, body) do
    case Services.decode(:write_res, body) do
      {:ok, res, _} ->
        if Enum.all?(res.results, &(&1 == 0)), do: :ok, else: {:error, res.results}
      {:error, r} -> {:error, r}
    end
  end

  defp dispatch_service_response(:browse_res, body) do
    case Services.decode(:browse_res, body) do
      {:ok, res, _} -> {:ok, Enum.flat_map(res.results, & &1.references)}
      {:error, r}   -> {:error, r}
    end
  end

  defp dispatch_service_response(:service_fault, body) do
    case Services.decode(:service_fault, body) do
      {:ok, fault, _} ->
        sc = fault.response_header.service_result
        {:error, {:service_fault, sc}}
      _ -> {:error, :service_fault}
    end
  end

  defp dispatch_service_response(service, _body) do
    Logger.debug("[Channel] Unexpected response: #{inspect(service)}")
    {:error, {:unexpected_response, service}}
  end

  # ── Queue drain ───────────────────────────────────────────────────────────────

  defp drain_queue(data) do
    case :queue.out(data.queue) do
      {:empty, _} ->
        {:next_state, :idle, data}

      {{:value, {from, req}}, rest_queue} ->
        new_data = %{data | queue: rest_queue}
        case build_request(req, new_data) do
          {:ok, service_atom, req_struct, built_data} ->
            {handle, sent_data} = send_service(service_atom, req_struct, built_data)
            timer = Process.send_after(self(), {:request_timeout, handle}, @request_timeout)
            inflight = {from, handle, timer}
            {:next_state, :waiting, %{sent_data | inflight: inflight}}

          {:error, reason} ->
            :gen_statem.reply(from, {:error, reason})
            drain_queue(new_data)
        end
    end
  end

  # ── Request building ──────────────────────────────────────────────────────────

  defp build_request({:read, node_ids, attribute_id}, data) do
    req = %ReadRequest{
      request_header:       make_request_header(data),
      max_age:              0.0,
      timestamps_to_return: 2,
      nodes_to_read:        Enum.map(node_ids, &%ReadValueId{node_id: &1, attribute_id: attribute_id})
    }
    {:ok, :read_req, req, data}
  end

  defp build_request({:write, node_id, value}, data) do
    dv = %DataValue{value: value, status_code: 0}
    req = %WriteRequest{
      request_header: make_request_header(data),
      nodes_to_write: [%WriteValue{node_id: node_id, attribute_id: 13, value: dv}]
    }
    {:ok, :write_req, req, data}
  end

  defp build_request({:browse, node_id, opts}, data) do
    req = %BrowseRequest{
      request_header:          make_request_header(data),
      max_references_per_node: Keyword.get(opts, :max_references, 0),
      nodes_to_browse: [%BrowseDescription{
        node_id:           node_id,
        browse_direction:  Keyword.get(opts, :direction, 0),
        reference_type_id: NodeId.ns0(0),
        include_subtypes:  true,
        node_class_mask:   0,
        result_mask:       63
      }]
    }
    {:ok, :browse_req, req, data}
  end

  defp build_request(req, _data) do
    Logger.warning("[Channel] Unknown request: #{inspect(req)}")
    {:error, :unknown_request}
  end

  # ── Wire helpers ──────────────────────────────────────────────────────────────

  # Returns {request_handle, new_data}
  defp send_service(service_atom, req_struct, data) do
    handle    = data.request_id
    type_id   = Services.type_id(service_atom)
    type_node = NodeId.ns0(type_id)
    body      = Types.encode_node_id(type_node) <> Services.encode(service_atom, req_struct)

    chunk = %MsgChunk{
      msg_type:        :msg,
      is_final:        :final,
      channel_id:      data.channel_id,
      security_header: %SymmetricSecurityHeader{token_id: data.token_id},
      sequence_header: %SequenceHeader{
        sequence_number: data.sequence_number,
        request_id:      data.request_id
      },
      body: body
    }

    ExOpcUA.Client.Transport.send_bytes(data.transport, Message.encode_msg_chunk(chunk))

    new_data = %{data |
      sequence_number: data.sequence_number + 1,
      request_id:      data.request_id + 1
    }
    {handle, new_data}
  end

  # Decode TypeId then pull request_handle out of the response header
  # Returns {:service, service_atom, body_after_type_id, request_handle} | :unknown
  defp decode_response_handle(body) do
    case Types.decode_node_id(body) do
      {%NodeId{type: type, id: type_id_int}, rest} when type in [:two_byte, :four_byte, :numeric] ->
        service = Services.from_type_id(type_id_int)
        # Response header starts with: auth_token (NodeId) + timestamp (8) + request_handle (4) + ...
        # We need request_handle. Decode it properly.
        case decode_request_handle_from_response(rest) do
          {:ok, handle} -> {:service, service, rest, handle}
          :error        -> {:service, service, rest, -1}
        end
      _ -> :unknown
    end
  end

  # Response header layout after TypeId: timestamp(8) + request_handle(4) + ...
  # No auth_token prefix — that's a request-side field only.
  defp decode_request_handle_from_response(body) do
    case Types.decode_response_header(body) do
      {%{request_handle: handle}, _rest} -> {:ok, handle}
      _ -> :error
    end
  end

  defp maybe_forward_publish(chunk, data) do
    case decode_response_handle(chunk.body) do
      {:service, service, body, _handle} when service in [:publish_res, :service_fault] ->
        if data.sub_manager do
          ExOpcUA.Client.SubManager.handle_frame(data.sub_manager, service, body)
        end
      _ -> :ok
    end
  end

  defp flush_inflight(%{inflight: {from, _handle, timer}}, reply) do
    Process.cancel_timer(timer)
    :gen_statem.reply(from, reply)
  end
  defp flush_inflight(_, _), do: :ok

  defp make_request_header(data) do
    %Types.RequestHeader{
      auth_token:     data.auth_token || NodeId.ns0(0),
      timestamp:      DateTime.utc_now(),
      request_handle: data.request_id,
      timeout_hint:   @request_timeout
    }
  end
end
