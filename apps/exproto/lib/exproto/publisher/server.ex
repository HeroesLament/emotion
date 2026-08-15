defmodule ExProto.Publisher.Server do
  @moduledoc """
  The thin process that gives `ExProto.Publisher` a clock and a destination.

  One per connection. It holds the pure publisher state, schedules a single
  timer for the nearest deadline, and sends notifications to the socket process
  that owns the connection.

  ## Time is an input here too

  `clock: :internal` self-schedules and is what the transport uses.
  `clock: :external` waits for `tick/2`, which is how the tests advance a
  subscription by exactly one interval with no wall clock involved — the same
  arrangement as `Exdrive.Drive`, for the same reason.

  ## Why one timer rather than one per subscription

  A pendant can hold a dozen subscriptions at different rates. Twelve timers
  firing independently produce twelve wakeups and twelve separate frames where
  one wakeup would have produced one; the publisher knows the nearest deadline,
  so the process asks for exactly that.

  ## Backpressure

  Notifications are sent to the owner as ordinary messages. If the owner cannot
  keep up, the mailbox grows — which is the one place this design can still
  accumulate, and why the owner must drain promptly rather than doing work
  between receives. The values themselves cannot pile up, because they are read
  at send time rather than queued.
  """

  use GenServer

  alias ExProto.Publisher

  @doc """
  Starts a publisher.

    * `:owner` — process to send notifications to, defaults to the caller
    * `:source` — `{module, arg}` for reading values
    * `:clock` — `:internal` (default) or `:external`
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Registers a subscription."
  def add(server, id, node_ids, rate_hz) do
    GenServer.call(server, {:add, id, node_ids, rate_hz})
  end

  @doc "Removes a subscription. Idempotent."
  def remove(server, id), do: GenServer.call(server, {:remove, id})

  @doc """
  Advances an externally clocked publisher by `elapsed_ms`.

  Synchronous so a test can assert on what arrived immediately afterwards
  without racing the send.
  """
  def tick(server, elapsed_ms \\ 0), do: GenServer.call(server, {:tick, elapsed_ms})

  @doc "The publisher's current pure state, for inspection and tests."
  def state(server), do: GenServer.call(server, :state)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, :internal)

    unless clock in [:internal, :external] do
      raise ArgumentError, ":clock must be :internal or :external, got #{inspect(clock)}"
    end

    {:ok,
     %{
       publisher: Publisher.new(),
       owner: Keyword.get(opts, :owner, self()),
       source: Keyword.fetch!(opts, :source),
       clock: clock,
       # Virtual under an external clock so a test controls time exactly;
       # monotonic under an internal one so it is immune to the wall clock
       # being stepped by NTP mid-motion.
       now: 0,
       timer: nil
     }}
  end

  @impl true
  def handle_call({:add, id, node_ids, rate_hz}, _from, state) do
    publisher = Publisher.add(state.publisher, id, node_ids, rate_hz, now(state))

    {:reply, :ok, schedule(%{state | publisher: publisher})}
  end

  def handle_call({:remove, id}, _from, state) do
    publisher = Publisher.remove(state.publisher, id)

    {:reply, :ok, schedule(%{state | publisher: publisher})}
  end

  def handle_call({:tick, elapsed_ms}, _from, state) do
    state = %{state | now: state.now + elapsed_ms}
    {:reply, :ok, publish(state)}
  end

  def handle_call(:state, _from, state), do: {:reply, state.publisher, state}

  @impl true
  def handle_info(:tick, state) do
    {:noreply, state |> Map.put(:timer, nil) |> publish()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Internals ─────────────────────────────────────────────────────────────

  defp publish(state) do
    {notifications, publisher} = Publisher.tick(state.publisher, now(state), state.source)

    Enum.each(notifications, &send(state.owner, {:notify, &1}))

    schedule(%{state | publisher: publisher})
  end

  defp schedule(%{clock: :external} = state), do: state

  defp schedule(state) do
    state = cancel(state)

    case Publisher.next_due_in(state.publisher, now(state)) do
      nil -> state
      delay -> %{state | timer: Process.send_after(self(), :tick, delay)}
    end
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    # A :tick that already made it into the mailbox before the cancel is
    # harmless — it publishes nothing that is not due — so there is nothing to
    # flush.
    %{state | timer: nil}
  end

  defp now(%{clock: :external, now: now}), do: now
  defp now(_state), do: System.monotonic_time(:millisecond)
end
