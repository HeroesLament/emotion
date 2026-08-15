defmodule ExProto.Socket do
  @moduledoc """
  The WebSock handler: one process per connection, holding one session.

  Everything interesting already happened before this module was written.
  Dispatch is pure, delivery is pure with a clock beside it, and this is the
  layer that moves bytes and owns the two processes involved. It should stay
  boring, and the amount of protocol logic here — none — is the measure of
  whether the earlier layers were factored right.

  ## Subscriptions are reconciled, not commanded

  `ExProto.Dispatch` records a subscription in the session and does not call
  anything, because it is pure. So after each request this handler diffs the
  session's subscriptions against what the publisher already knows and applies
  the difference.

  That keeps the effect at the edge, where it can be seen, rather than hiding a
  process call inside a function that claims to be a fold over a request.

  ## Keepalive

  The listener closes a connection that has been silent for 60 seconds, and a
  conflating subscription is silent by design: only changed values are sent, so
  a parked arm produces no traffic at all. The two together dropped the link
  after a minute of stillness — which is most of the time, since watching a
  stationary machine is the normal state of a studio.

  So the server pings every 20 seconds. RFC 6455 ping/pong rather than a
  JSON-RPC heartbeat, because the timeout being defended against is a property
  of the socket rather than of the protocol, and because a heartbeat
  notification would put a lie in the subscription stream — a frame that says
  nothing changed, on a channel whose contract is that it only speaks when
  something did.

  Twenty seconds gives three chances to answer before the timeout, which
  matters on a link slow enough to be worth keeping alive in the first place.

  ## Backpressure

  Notifications arrive as messages and are pushed straight out. The socket does
  no work between receives, so the only place values can accumulate is this
  process's mailbox, and they cannot accumulate for long because the publisher
  reads at send time rather than queueing — a slow client loses resolution, not
  memory.
  """

  @behaviour WebSock

  require Logger

  alias ExProto.{Dispatch, Session}
  alias ExProto.Publisher.Server, as: Publisher

  # Comfortably under the listener's 60s idle timeout — see ExProto.Router.
  @keepalive_ms 20_000

  @impl WebSock
  def init(opts) do
    {:ok, publisher} =
      Publisher.start_link(owner: self(), source: opts.source, clock: :internal)

    keepalive_ms = Map.get(opts, :keepalive_ms) || @keepalive_ms
    schedule_keepalive(keepalive_ms)

    {:ok,
     %{
       session:
         Session.new(table: opts.table, source: opts.source, principal: opts.principal),
       publisher: publisher,
       known: MapSet.new(),
       keepalive_ms: keepalive_ms
     }}
  end

  @impl WebSock
  def handle_in({payload, opcode: :text}, state) do
    case Dispatch.handle_payload(payload, state.session) do
      {:reply, response, session} ->
        state = state |> put_session(session) |> reconcile()
        {:push, {:text, encode(response)}, state}

      {:noreply, session} ->
        {:ok, state |> put_session(session) |> reconcile()}
    end
  end

  # Binary frames are not part of this protocol. Closing rather than ignoring,
  # because a client sending them has misunderstood something and silence would
  # let it keep doing so.
  def handle_in({_payload, opcode: opcode}, state) do
    Logger.warning("ExProto.Socket: unexpected #{opcode} frame, closing")
    {:stop, :normal, {1003, "only text frames are supported"}, state}
  end

  @impl WebSock
  def handle_info(:keepalive, state) do
    schedule_keepalive(state.keepalive_ms)
    {:push, {:ping, ""}, state}
  end

  def handle_info({:notify, notification}, state) do
    {:push, {:text, encode(notification)}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    # The publisher is linked, so it would go anyway; stopping it explicitly
    # means its timer is cancelled now rather than whenever the exit lands.
    if Process.alive?(state.publisher), do: GenServer.stop(state.publisher, :normal)
    :ok
  end

  # A pong resets the listener's idle timer, because that timer measures time
  # since data was *received*. Our own ping does not reset it; the client's
  # answer does. Which is why the client half of this matters as much as this
  # half — see ExLink.stream/2.
  @impl WebSock
  def handle_control({_payload, opcode: :pong}, state), do: {:ok, state}
  def handle_control({_payload, opcode: :ping}, state), do: {:ok, state}
  def handle_control(_frame, state), do: {:ok, state}

  # ── Internals ─────────────────────────────────────────────────────────────

  defp schedule_keepalive(interval), do: Process.send_after(self(), :keepalive, interval)

  defp put_session(state, session), do: %{state | session: session}

  defp reconcile(state) do
    current = state.session.subscriptions |> Map.keys() |> MapSet.new()

    for id <- MapSet.difference(current, state.known) do
      subscription = Map.fetch!(state.session.subscriptions, id)
      Publisher.add(state.publisher, id, subscription.node_ids, subscription.rate_hz)
    end

    for id <- MapSet.difference(state.known, current) do
      Publisher.remove(state.publisher, id)
    end

    %{state | known: current}
  end

  defp encode(term) do
    term |> :json.encode() |> IO.iodata_to_binary()
  end
end
