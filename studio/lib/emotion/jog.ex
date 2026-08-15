defmodule EMotion.Jog do
  @moduledoc """
  Holds a jog for as long as the operator is holding the button.

  The controller stops an axis as soon as assertions stop arriving — that is
  what makes a dropped link, a crashed Studio or a suspended laptop stop the
  machine rather than leave it moving. The other side of that bargain is that
  something here has to keep asserting, at a rate comfortably inside the
  deadline the controller granted, for exactly as long as the button is down.

  ## Why this is a process and not part of the scene

  A Cedar scene is a pure function of its model and has no clock. This has a
  clock and nothing else: a timer per held axis, a velocity, and the connection
  to assert through. Putting it in the scene would mean the arm keeps moving or
  stops depending on how the interface happens to be re-rendering.

  It also has to survive the interface. If the pendant pane is closed, or the
  window is dragged, or the scene crashes and is restarted by its supervisor,
  the axis must stop — and it does, because the assertions stop with the
  process that was making them, and the controller notices within its deadline
  without being told.

  ## Release does not wait for the deadline

  Letting go sends one zero-velocity assertion and then stops asserting. The
  deadline alone would stop the axis anyway, a third of a second later, which
  is both correct and far too slow to feel like a button. The explicit zero is
  what makes the control feel attached to the machine; the deadline is what
  makes it safe when the explicit zero never arrives.

  ## One axis at a time

  Pressing a second jog button releases the first. Two joints moving because
  two buttons are down is a combined motion nobody planned, and on a pendant
  with a mouse there is only one pointer anyway — a second button going down
  while the first is still held means the first was never released, which is
  precisely the stuck-key case this should be defending against.
  """

  use GenServer

  require Logger

  alias EMotion.Link

  # Comfortably inside the 300ms a controller grants by default, and not so
  # fast that a slow link spends all its time on jog traffic. Three assertions
  # per deadline means two can be lost before the axis stops, which is the
  # right tradeoff for a link that is only ever a workstation talking to a cell
  # on the same segment.
  @assert_ms 100

  @type direction :: -1 | 1

  defstruct [:axis, :velocity, :timer, :deadline, :owner, speed: 0.25, status: :idle]

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts holding `axis` in `direction`, at the current speed.

  Returns `:ok` even when the controller refuses: what went wrong is reported
  to subscribers as a status, because the caller is a button being pressed and
  has nowhere useful to put an error.
  """
  @spec press(String.t(), direction(), keyword()) :: :ok
  def press(axis, direction, opts \\ []) do
    GenServer.cast(server(opts), {:press, axis, direction, self()})
  end

  @doc "Stops holding. Sends one zero assertion rather than waiting for the deadline."
  @spec release(keyword()) :: :ok
  def release(opts \\ []), do: GenServer.cast(server(opts), :release)

  @doc """
  Sets the jog speed as a fraction of the controller's manual-mode maximum.

  Takes effect on the next assertion, so it can be changed mid-hold — which is
  what an operator reaching for the override slider while jogging expects.
  """
  @spec set_speed(float(), keyword()) :: :ok
  def set_speed(fraction, opts \\ []), do: GenServer.cast(server(opts), {:speed, fraction})

  @doc "What is being held, if anything, and what the controller last said."
  @spec state(keyword()) :: map()
  def state(opts \\ []), do: GenServer.call(server(opts), :state)

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{speed: Keyword.get(opts, :speed, 0.25)}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply,
     %{
       axis: state.axis,
       velocity: state.velocity,
       deadline: state.deadline,
       speed: state.speed,
       status: state.status
     }, state}
  end

  @impl true
  def handle_cast({:press, axis, direction, owner}, state) do
    # Whatever was held is released first, and released properly — the axis
    # being abandoned gets its zero rather than being left to time out.
    state = stop_holding(state)

    state = %{state | axis: axis, velocity: direction * state.speed, owner: owner}

    {:noreply, assert_now(state)}
  end

  def handle_cast(:release, state), do: {:noreply, stop_holding(state)}

  def handle_cast({:speed, fraction}, state) do
    speed = fraction |> max(0.01) |> min(1.0)

    velocity =
      case state.velocity do
        nil -> nil
        v -> if(v < 0, do: -1, else: 1) * speed
      end

    {:noreply, %{state | speed: speed, velocity: velocity}}
  end

  @impl true
  def handle_info(:assert, %{axis: nil} = state), do: {:noreply, state}

  def handle_info(:assert, state), do: {:noreply, assert_now(state)}

  # ── Asserting ─────────────────────────────────────────────────────────────

  defp assert_now(state) do
    case Link.hold(state.axis, state.velocity) do
      {:ok, deadline} ->
        state = %{state | deadline: deadline, status: :holding}
        notify(state)
        %{state | timer: Process.send_after(self(), :assert, interval(deadline))}

      {:error, reason} ->
        # Stop asserting. A refused jog that kept retrying at 10 Hz would be a
        # pendant hammering a controller that has already said no — and if the
        # refusal is another session holding the axis, the operator needs to be
        # told that rather than watching a button do nothing.
        Logger.warning("EMotion.Jog: #{state.axis} refused: #{inspect(reason)}")
        notify(%{state | status: {:refused, reason}})
        %{state | axis: nil, velocity: nil, timer: nil, status: {:refused, reason}}
    end
  end

  # Three assertions inside whatever the controller granted, never slower than
  # the default rate. Derived from the grant rather than assumed, because a
  # controller that grants less than we asked for is telling us to talk faster.
  defp interval(deadline), do: min(@assert_ms, div(deadline, 3))

  defp stop_holding(%{axis: nil} = state), do: state

  defp stop_holding(state) do
    cancel(state.timer)

    # One zero, then silence. The zero is what makes the button feel attached
    # to the machine; the silence is what stops it if the zero never lands.
    case Link.hold(state.axis, 0.0) do
      {:ok, _deadline} -> :ok
      {:error, reason} -> Logger.warning("EMotion.Jog: stop unacknowledged: #{inspect(reason)}")
    end

    state = %{state | axis: nil, velocity: nil, timer: nil, deadline: nil, status: :idle}
    notify(state)
    state
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp notify(%{owner: nil}), do: :ok

  defp notify(state) do
    send(state.owner, {:jog, %{axis: state.axis, velocity: state.velocity, status: state.status}})
  end
end
