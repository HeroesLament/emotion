defmodule ExOpcUA.Client.SubManager do
  @moduledoc """
  Manages OPC UA subscriptions independently of the Channel.

  Responsibilities:
    - CreateSubscription + CreateMonitoredItems (two-step, tracked as a single
      caller-visible operation via a simple {:creating, from, ...} state)
    - DeleteSubscriptions (synchronous)
    - Publish loop — fire-and-callback, never blocks a caller
    - Dispatch DataChange notifications to user callbacks

  States:
    :inactive   — no session, ignore calls
    :idle       — session active, no pending sync operation
    :creating   — waiting for CreateSubscription response
    :monitoring — waiting for CreateMonitoredItems response
    :deleting   — waiting for DeleteSubscriptions response

  Publish responses arrive asynchronously and are always handled regardless
  of which sync state we're in.
  """

  @behaviour :gen_statem

  require Logger

  alias ExOpcUA.Codec.{Types, Services, Message}
  alias ExOpcUA.Codec.Types.NodeId
  alias ExOpcUA.Codec.Message.{MsgChunk, SequenceHeader, SymmetricSecurityHeader}
  alias ExOpcUA.Codec.Services.{
    CreateSubscriptionRequest,
    CreateMonitoredItemsRequest, MonitoredItemCreateRequest, MonitoringParameters,
    PublishRequest, ReadValueId
  }

  @request_timeout 10_000
  @publish_ahead   2

  defstruct [
    :transport,
    channel_id:      0,
    token_id:        0,
    request_id:      5000,   # offset from Channel to avoid collisions
    sequence_number: 5000,
    auth_token:      nil,
    # %{sub_id => %{id, callback, node_ids, monitored_item_ids}}
    subscriptions:   %{},
    # How many publish requests are currently in-flight
    publish_inflight: 0
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def activate(pid, channel_id, token_id, auth_token) do
    :gen_statem.cast(pid, {:activate, channel_id, token_id, auth_token})
  end

  def deactivate(pid) do
    :gen_statem.cast(pid, :deactivate)
  end

  def subscribe(pid, node_ids, callback, opts) do
    :gen_statem.call(pid, {:subscribe, node_ids, callback, opts}, @request_timeout + 1000)
  end

  def unsubscribe(pid, sub_id) do
    :gen_statem.call(pid, {:unsubscribe, sub_id}, @request_timeout + 1000)
  end

  # Called by Channel when it receives a publish_res or sub-related frame
  def handle_frame(pid, service, body) do
    :gen_statem.cast(pid, {:frame, service, body})
  end

  # ── gen_statem ────────────────────────────────────────────────────────────────

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    data = %__MODULE__{
      transport: Keyword.fetch!(opts, :transport)
    }
    {:ok, :inactive, data}
  end

  # ── State: inactive ───────────────────────────────────────────────────────────

  def inactive(:enter, _old, _data), do: :keep_state_and_data

  def inactive(:cast, {:activate, ch, tok, auth}, data) do
    new_data = %{data | channel_id: ch, token_id: tok, auth_token: auth}
    {:next_state, :idle, new_data}
  end

  def inactive(:cast, _, _data), do: :keep_state_and_data

  def inactive({:call, from}, _, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # ── State: idle ───────────────────────────────────────────────────────────────

  def idle(:enter, _old, data) do
    # Rearm publish loop if we have subscriptions.
    # state_enter callbacks cannot emit :next_event, so we cast to self.
    if map_size(data.subscriptions) > 0 do
      :gen_statem.cast(self(), :pump_publish)
    end
    :keep_state_and_data
  end

  def idle(:cast, :pump_publish, data) do
    new_data = pump_publish(data)
    {:keep_state, new_data}
  end

  def idle(:cast, {:activate, ch, tok, auth}, data) do
    new_data = %{data | channel_id: ch, token_id: tok, auth_token: auth}
    if map_size(new_data.subscriptions) > 0 do
      :gen_statem.cast(self(), :pump_publish)
    end
    {:keep_state, new_data}
  end

  def idle(:cast, :deactivate, _data) do
    {:next_state, :inactive, %__MODULE__{}}
  end

  def idle({:call, from}, {:subscribe, node_ids, callback, opts}, data) do
    interval = Keyword.get(opts, :interval, 500.0)
    req = %CreateSubscriptionRequest{
      request_header:                make_request_header(data),
      requested_publishing_interval: interval,
      requested_lifetime_count:      10,
      requested_max_keep_alive_count: 3,
      publishing_enabled:            true
    }
    {handle, new_data} = send_service(:create_subscription_req, req, data)
    timer = schedule_timeout(handle)
    meta  = {from, node_ids, callback, interval, handle, timer}
    {:next_state, :creating, {new_data, meta}}
  end

  def idle({:call, from}, {:unsubscribe, sub_id}, data) do
    case Map.get(data.subscriptions, sub_id) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}

      _sub ->
        req = %{
          request_header:   make_request_header(data),
          subscription_ids: [sub_id]
        }
        {handle, new_data} = send_service(:delete_subscriptions_req, req, data)
        timer = schedule_timeout(handle)
        meta  = {from, sub_id, handle, timer}
        {:next_state, :deleting, {new_data, meta}}
    end
  end

  def idle(:cast, {:frame, :publish_res, body}, data) do
    handle_publish(body, data)
  end

  def idle(:cast, {:frame, _, _}, _data), do: :keep_state_and_data

  # ── State: creating (awaiting CreateSubscription response) ────────────────────

  def creating(:enter, _old, _state_data), do: :keep_state_and_data

  def creating(:cast, {:frame, :create_subscription_res, body}, {data, meta}) do
    {from, node_ids, callback, _interval, handle, timer} = meta
    case Services.decode(:create_subscription_res, body) do
      {:ok, res, _} ->
        rh = response_handle(body)
        if rh == handle do
          Process.cancel_timer(timer)
          sub_id = res.subscription_id
          sub = %{id: sub_id, callback: callback, node_ids: node_ids, monitored_item_ids: []}
          new_data = %{data | subscriptions: Map.put(data.subscriptions, sub_id, sub)}
          # Now send CreateMonitoredItems
          {mi_handle, new_data2} = send_create_monitored_items(sub_id, node_ids, new_data)
          mi_timer = schedule_timeout(mi_handle)
          mi_meta  = {from, sub_id, mi_handle, mi_timer}
          {:next_state, :monitoring, {new_data2, mi_meta}}
        else
          {:keep_state_and_data}
        end

      {:error, reason} ->
        Process.cancel_timer(timer)
        :gen_statem.reply(from, {:error, reason})
        {:next_state, :idle, data}
    end
  end

  def creating(:cast, {:frame, :publish_res, body}, {data, meta}) do
    # Publish can arrive any time — handle it without leaving creating state
    new_data = elem(handle_publish(body, data), 1) |> extract_data()
    {:keep_state, {new_data, meta}}
  end

  def creating(:cast, {:frame, :service_fault, body}, {data, meta}) do
    {from, _, _, _, handle, timer} = meta
    case Services.decode(:service_fault, body) do
      {:ok, fault, _} ->
        if fault.response_header.request_handle == handle do
          Process.cancel_timer(timer)
          sc = fault.response_header.service_result
          :gen_statem.reply(from, {:error, {:service_fault, sc}})
          {:next_state, :idle, data}
        else
          :keep_state_and_data
        end
      _ -> :keep_state_and_data
    end
  end

  def creating(:cast, _, _), do: :keep_state_and_data

  def creating({:call, from}, {:subscribe, _, _, _}, _state_data) do
    # Reject concurrent subscribe
    {:keep_state_and_data, [{:reply, from, {:error, :subscribe_in_progress}}]}
  end

  def creating({:call, from}, _, _state_data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def creating(:info, {:request_timeout, handle}, {data, meta}) do
    {from, _, _, _, ^handle, _timer} = meta
    :gen_statem.reply(from, {:error, :timeout})
    {:next_state, :idle, data}
  end

  def creating(:info, {:request_timeout, _}, _), do: :keep_state_and_data

  # ── State: monitoring (awaiting CreateMonitoredItems response) ────────────────

  def monitoring(:enter, _old, _state_data), do: :keep_state_and_data

  def monitoring(:cast, {:frame, :create_monitored_items_res, body}, {data, meta}) do
    {from, sub_id, handle, timer} = meta
    case Services.decode(:create_monitored_items_res, body) do
      {:ok, res, _} ->
        rh = response_handle(body)
        if rh == handle do
          Process.cancel_timer(timer)
          mon_ids = Enum.map(res.results, & &1.monitored_item_id)
          sub     = Map.get(data.subscriptions, sub_id)
          new_sub = %{sub | monitored_item_ids: mon_ids}
          new_data = %{data | subscriptions: Map.put(data.subscriptions, sub_id, new_sub)}
          :gen_statem.reply(from, {:ok, sub_id})
          # Kick publish loop
          new_data2 = pump_publish(new_data)
          {:next_state, :idle, new_data2}
        else
          :keep_state_and_data
        end

      {:error, reason} ->
        Process.cancel_timer(timer)
        :gen_statem.reply(from, {:error, reason})
        {:next_state, :idle, data}
    end
  end

  def monitoring(:cast, {:frame, :publish_res, body}, {data, meta}) do
    new_data = do_handle_publish(body, data)
    {:keep_state, {new_data, meta}}
  end

  def monitoring(:cast, {:frame, :service_fault, body}, {data, meta}) do
    {from, _, handle, timer} = meta
    case Services.decode(:service_fault, body) do
      {:ok, fault, _} ->
        if fault.response_header.request_handle == handle do
          Process.cancel_timer(timer)
          sc = fault.response_header.service_result
          :gen_statem.reply(from, {:error, {:service_fault, sc}})
          {:next_state, :idle, data}
        else
          :keep_state_and_data
        end
      _ -> :keep_state_and_data
    end
  end

  def monitoring(:cast, _, _), do: :keep_state_and_data

  def monitoring({:call, from}, _, _) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def monitoring(:info, {:request_timeout, handle}, {data, meta}) do
    {from, _, ^handle, _} = meta
    :gen_statem.reply(from, {:error, :timeout})
    {:next_state, :idle, data}
  end

  def monitoring(:info, {:request_timeout, _}, _), do: :keep_state_and_data

  # ── State: deleting (awaiting DeleteSubscriptions response) ──────────────────

  def deleting(:enter, _old, _state_data), do: :keep_state_and_data

  def deleting(:cast, {:frame, :delete_subscriptions_res, body}, {data, meta}) do
    {from, sub_id, handle, timer} = meta
    rh = response_handle(body)
    if rh == handle do
      Process.cancel_timer(timer)
      new_subs = Map.delete(data.subscriptions, sub_id)
      new_data = %{data | subscriptions: new_subs, publish_inflight: 0}
      :gen_statem.reply(from, :ok)
      {:next_state, :idle, new_data}
    else
      :keep_state_and_data
    end
  end

  def deleting(:cast, {:frame, :publish_res, body}, {data, meta}) do
    new_data = do_handle_publish(body, data)
    {:keep_state, {new_data, meta}}
  end

  def deleting(:cast, {:frame, :service_fault, body}, {data, meta}) do
    {from, _, handle, timer} = meta
    case Services.decode(:service_fault, body) do
      {:ok, fault, _} ->
        if fault.response_header.request_handle == handle do
          Process.cancel_timer(timer)
          sc = fault.response_header.service_result
          :gen_statem.reply(from, {:error, {:service_fault, sc}})
          {:next_state, :idle, data}
        else
          :keep_state_and_data
        end
      _ -> :keep_state_and_data
    end
  end

  def deleting(:cast, _, _), do: :keep_state_and_data

  def deleting({:call, from}, _, _) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  def deleting(:info, {:request_timeout, handle}, {data, meta}) do
    {from, _, ^handle, _} = meta
    :gen_statem.reply(from, {:error, :timeout})
    {:next_state, :idle, data}
  end

  def deleting(:info, {:request_timeout, _}, _), do: :keep_state_and_data

  # ── Publish handling ──────────────────────────────────────────────────────────

  defp handle_publish(body, data) do
    new_data = do_handle_publish(body, data)
    {:keep_state, new_data}
  end

  defp do_handle_publish(body, data) do
    case Services.decode(:publish_res, body) do
      {:ok, res, _} ->
        sub = Map.get(data.subscriptions, res.subscription_id)
        if sub, do: dispatch_notifications(sub, res.notification_message)
        new_inflight = max(0, data.publish_inflight - 1)
        new_data = %{data | publish_inflight: new_inflight}
        pump_publish(new_data)

      {:error, _} ->
        data
    end
  end

  defp pump_publish(data) do
    needed = max(0, @publish_ahead - data.publish_inflight)
    if needed > 0 and map_size(data.subscriptions) > 0 do
      Enum.reduce(1..needed, data, fn _, acc ->
        req = %PublishRequest{
          request_header:                make_request_header(acc),
          subscription_acknowledgements: []
        }
        {_handle, new_acc} = send_service(:publish_req, req, acc)
        %{new_acc | publish_inflight: new_acc.publish_inflight + 1}
      end)
    else
      data
    end
  end

  defp dispatch_notifications(sub, %Services.NotificationMessage{notification_data: data}) do
    changes = Enum.flat_map(data, fn ext_obj ->
      case Services.decode_data_change_notification(ext_obj) do
        {:ok, %Services.DataChangeNotification{monitored_items: items}} ->
          Enum.zip(sub.node_ids, Enum.map(items, & &1.value))
        _ -> []
      end
    end)
    if changes != [], do: sub.callback.(changes)
  end

  # ── Wire helpers ──────────────────────────────────────────────────────────────

  defp send_create_monitored_items(sub_id, node_ids, data) do
    items = Enum.with_index(node_ids) |> Enum.map(fn {nid, i} ->
      %MonitoredItemCreateRequest{
        item_to_monitor:      %ReadValueId{node_id: nid, attribute_id: 13},
        monitoring_mode:      2,
        requested_parameters: %MonitoringParameters{
          client_handle:     sub_id * 1000 + i,
          sampling_interval: -1.0,
          queue_size:        1,
          discard_oldest:    true
        }
      }
    end)
    req = %CreateMonitoredItemsRequest{
      request_header:       make_request_header(data),
      subscription_id:      sub_id,
      timestamps_to_return: 2,
      items_to_create:      items
    }
    send_service(:create_monitored_items_req, req, data)
  end

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

  # Decode request_handle from a response body (after TypeId has been stripped)
  defp response_handle(body) do
    case Types.decode_response_header(body) do
      {%{request_handle: handle}, _} -> handle
      _ -> -1
    end
  end

  defp make_request_header(data) do
    %Types.RequestHeader{
      auth_token:     data.auth_token || NodeId.ns0(0),
      timestamp:      DateTime.utc_now(),
      request_handle: data.request_id,
      timeout_hint:   @request_timeout
    }
  end

  defp schedule_timeout(handle) do
    Process.send_after(self(), {:request_timeout, handle}, @request_timeout)
  end

  # Helper to extract data from a handle_publish return when used mid-state
  defp extract_data({:keep_state, d}), do: d
  defp extract_data(d), do: d
end
