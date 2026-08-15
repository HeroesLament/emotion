defmodule ExProto.Jog do
  @moduledoc """
  The dead-man's handle for held commands.

  A jog is not a command, it is an *assertion* that someone is still holding a
  button. That distinction is the whole reason this module exists. Every other
  method in the model is a request to change state once: enable, home, stop.
  Jog is a request to keep moving for as long as the operator keeps asking, and
  a protocol that models it as a normal method has built a machine that carries
  on moving when the operator lets go.

  ## What actually goes wrong without this

  Wire a jog button to a velocity setpoint and the axis moves while the button
  is down. It also moves when Studio's window manager swallows the key-up
  event, when the laptop suspends mid-jog, when the Wi-Fi drops, when the BEAM
  running Studio is SIGKILLed, and when someone trips over the cable. In each
  of those the last thing the controller heard was "move", so it moves, and
  there is nobody left to tell it otherwise. This is the software half of a
  hold-to-run enabling device, and it fails in exactly the direction hardware
  three-position switches were invented to prevent.

  So the client re-asserts, typically at 10 Hz, and the controller commands
  zero the moment the assertions stop arriving. A dropped link becomes a
  stopped axis by default rather than by anyone remembering to send a stop.

  ## Not a protective measure

  This is a functional stop, not a safety-rated one. It runs on the same BEAM
  as the thing it is guarding, so it cannot be trusted against a controller
  that has hung — a watchdog whose failure mode is shared with what it watches
  is a convenience, not a protection. The E-stop is a hardware circuit and does
  not come through this protocol. See `protocol/DESIGN.md` on the
  functional/protective split.

  ## Zero velocity, not disable

  When assertions lapse the axis is commanded to zero and left enabled, which
  is what releasing a jog key on a real pendant does. Dropping drive power
  instead would let a loaded axis fall, and would make every brief network stall
  a fault an operator has to clear.

  ## One holder at a time, and the hold covers everything underneath it

  An axis being jogged is held by the session doing it, and a second session
  asking for the same axis is refused rather than queued or blended. Two
  pendants alternating setpoints on one joint is not a feature — the axis would
  do something neither operator asked for, and each would see the other's
  motion as their own command misbehaving. The hold is released when the holder
  releases it, when the holder's connection dies, when the assertions lapse, or
  when any other command is issued on that node: a `stop` outranks a jog, and
  it comes from someone who can see the machine.

  A hold on one node covers every node under it, and is covered by every node
  above it. Node ids are dotted paths, so `arm` contains `arm.axes.j1` and two
  keys overlap when one is a path prefix of the other — `arm.axes.j1` and
  `arm.axes.j2` do not.

  This is not tidiness. A Cartesian jog is one held command on the robot that
  moves six joints, and a per-axis hold would let a second session take
  `arm.axes.j4` while the first was already turning it through the arm: two
  sessions commanding one joint through two different objects, each of them
  correctly told they held what they asked for. The check has to be on the tree,
  not on the name.

  It cuts the other way too, and that is the half worth spelling out. When a
  hold is superseded by an ordinary command on the *same* node, the hold is
  simply dropped — whoever sent `stop` gets to say what happens next. When it
  is superseded from somewhere else in the tree, the hold is *zeroed* first,
  because a `stop` on one joint stops that joint and says nothing about the
  other five a Cartesian hold is still moving.

  ## Generic, not axis-specific

  Nothing here knows what an axis is. A method is watchdogged because the model
  says so — `meta: %{watchdog: true}` — and the contract of such a method is
  that it takes a `velocity` argument with a neutral value of zero. That is
  what gets asserted on expiry. A future held command with the same shape needs
  no changes here.
  """

  use GenServer

  require Logger

  alias ExMo.Schema.Method
  alias ExProto.Source

  # The bounds come from the model rather than from here. They are published in
  # the OpenRPC document beside the argument they clamp, and a client reading
  # what it may ask for out of one file while the controller enforces something
  # written in another is how those two quietly stop agreeing.
  @deadline Method.watchdog_deadline_ms()

  @type key :: String.t()
  @type reason :: :held | :unavailable | Source.reason()

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Asserts a held command, and restarts the deadline.

  `key` is what the hold is taken on — the object the method belongs to, so
  that two methods on one axis cannot be held by two different sessions.
  `node_id` is the method actually invoked and re-invoked on expiry.

  Returns the deadline that was *granted*, which is clamped and need not be the
  one requested. A client that assumes it got what it asked for will re-assert
  too slowly and be stopped for it.
  """
  @spec assert(key(), String.t(), map(), {module(), term()}, pid(), term()) ::
          {:ok, pos_integer()} | {:error, reason()}
  def assert(key, node_id, args, source, owner \\ self(), server \\ __MODULE__) do
    call(server, {:assert, key, node_id, args, source, owner})
  end

  @doc """
  Releases a hold without commanding anything.

  For the case where something else is about to command the axis — a stop, a
  disable — and issuing a zero setpoint first would be a second command racing
  the real one. Releasing a hold held by another session is allowed and
  deliberate: see the moduledoc.
  """
  @spec release(key(), term()) :: :ok
  def release(key, server \\ __MODULE__) do
    case call(server, {:release, key}) do
      :ok -> :ok
      # Nothing to release, and no hold can exist if the watchdog is not
      # running, so a missing server is not an error on this path.
      {:error, :unavailable} -> :ok
    end
  end

  @doc "Who holds `key`, if anyone. For tests and diagnostics."
  @spec holder(key(), term()) :: {:ok, pid()} | :none
  def holder(key, server \\ __MODULE__) do
    case call(server, {:holder, key}) do
      {:error, :unavailable} -> :none
      other -> other
    end
  end

  # A watchdog that is not running must not read as permission to move. Every
  # path that would command motion turns a missing server into a refusal; only
  # release/2, which commands nothing, treats it as a no-op.
  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, {:normal, _} -> {:error, :unavailable}
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Trapping exits so a shutdown runs terminate/2 and zeroes anything still
    # held. A supervisor bringing the endpoint down should not leave an axis
    # moving because the process that would have stopped it was killed first.
    Process.flag(:trap_exit, true)
    {:ok, %{holds: %{}}}
  end

  @impl GenServer
  def handle_call({:assert, key, node_id, args, source, owner}, _from, state) do
    overlapping = overlapping(state, key)

    if Enum.any?(overlapping, fn {_key, hold} -> hold.owner != owner end) do
      {:reply, {:error, :held}, state}
    else
      # The holder's own overlapping holds elsewhere in the tree are given up,
      # and given up properly: a session moving from jogging one joint to
      # jogging the whole arm must not leave the joint running on a hold nobody
      # is asserting against any more.
      state =
        Enum.reduce(overlapping, state, fn
          {^key, _hold}, state -> state
          {other, hold}, state -> neutralise(state, other, hold)
        end)

      existing = Map.get(state.holds, key)
      deadline = deadline(args)

      case apply_setpoint(source, node_id, args) do
        :ok ->
          {:reply, {:ok, deadline},
           hold(state, key, node_id, args, source, owner, existing, deadline)}

        {:error, reason} ->
          # A refused setpoint must not leave a hold behind. Otherwise an axis
          # that never started moving is locked against every other session
          # until a deadline nobody is watching expires.
          {:reply, {:error, reason}, drop(state, key, existing)}
      end
    end
  end

  # Exact match is dropped; anything else overlapping is zeroed first. The
  # command that caused this covers the node it names and nothing else, so a
  # hold reaching further than that has to be stopped rather than abandoned.
  def handle_call({:release, key}, _from, state) do
    state =
      state
      |> overlapping(key)
      |> Enum.reduce(state, fn
        {^key, hold}, state -> drop(state, key, hold)
        {other, hold}, state -> neutralise(state, other, hold)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:holder, key}, _from, state) do
    case Map.get(state.holds, key) do
      %{owner: owner} -> {:reply, {:ok, owner}, state}
      nil -> {:reply, :none, state}
    end
  end

  @impl GenServer
  def handle_info({:expired, key}, state) do
    case Map.get(state.holds, key) do
      nil ->
        # A timer that fired while its hold was being released. Ignoring it is
        # correct: the hold is gone and whoever released it decided what the
        # axis does next.
        {:noreply, state}

      hold ->
        Logger.warning(
          "jog watchdog: no assertion for #{hold.node_id} in #{hold.deadline}ms — commanding zero"
        )

        {:noreply, neutralise(state, key, hold)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    state =
      state.holds
      |> Enum.filter(fn {_key, hold} -> hold.owner == pid end)
      |> Enum.reduce(state, fn {key, hold}, state ->
        Logger.warning(
          "jog watchdog: holder of #{hold.node_id} exited (#{inspect(reason)}) — commanding zero"
        )

        neutralise(state, key, hold)
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.holds, fn {_key, hold} ->
      Logger.warning("jog watchdog stopping — commanding #{hold.node_id} to zero")
      apply_setpoint(hold.source, hold.node_id, neutral(hold.args))
    end)
  end

  # Every hold whose key overlaps this one: the same node, an ancestor of it, or
  # a descendant. Node ids are dotted paths, so containment is a prefix test on
  # whole segments — `axes.j1` is inside `axes`, and `axes.j10` is not inside
  # `axes.j1`, which a bare `String.starts_with?/2` would cheerfully claim.
  defp overlapping(state, key) do
    Enum.filter(state.holds, fn {held, _hold} -> overlaps?(held, key) end)
  end

  defp overlaps?(a, b), do: a == b or contains?(a, b) or contains?(b, a)

  defp contains?(outer, inner), do: String.starts_with?(inner, outer <> ".")

  # ── Holds ─────────────────────────────────────────────────────────────────

  defp hold(state, key, node_id, args, source, owner, existing, deadline) do
    cancel(existing)

    monitor =
      case existing do
        %{monitor: monitor} -> monitor
        nil -> Process.monitor(owner)
      end

    entry = %{
      node_id: node_id,
      args: args,
      source: source,
      owner: owner,
      monitor: monitor,
      deadline: deadline,
      timer: Process.send_after(self(), {:expired, key}, deadline)
    }

    %{state | holds: Map.put(state.holds, key, entry)}
  end

  # Commands zero and forgets the hold. The order matters: the setpoint goes out
  # first, so a source that blocks cannot leave a window where the hold is gone
  # and the axis is still moving.
  defp neutralise(state, key, hold) do
    apply_setpoint(hold.source, hold.node_id, neutral(hold.args))
    drop(state, key, hold)
  end

  defp drop(state, _key, nil), do: state

  defp drop(state, key, hold) do
    cancel(hold)
    Process.demonitor(hold.monitor, [:flush])
    %{state | holds: Map.delete(state.holds, key)}
  end

  defp cancel(nil), do: :ok

  defp cancel(%{timer: timer}) do
    Process.cancel_timer(timer)
    :ok
  end

  # A source that has died must not take the watchdog with it. This runs on the
  # path that stops a machine, and on shutdown it runs when half the tree is
  # already gone — a watchdog that crashes here is a watchdog that stopped
  # watching everything else it was holding.
  defp apply_setpoint({module, arg}, node_id, args) do
    Source.call(module, node_id, args, arg)
  catch
    :exit, reason ->
      Logger.error("jog watchdog: could not command #{node_id}: #{inspect(reason)}")
      {:error, :rejected}
  end

  # The neutral assertion for a watchdogged method. Everything else the caller
  # sent is kept, so a source that reads more than the velocity sees the same
  # command it saw a moment ago with the motion taken out of it.
  defp neutral(args), do: Map.put(args, "velocity", 0.0)

  # Clamped rather than refused. A client asking for an out-of-range deadline
  # has still asked to be watched, and refusing the assertion would leave it
  # unwatched — the one outcome this module exists to prevent. What it gets is
  # returned to it.
  defp deadline(args) do
    case Map.get(args, "deadlineMs") do
      value when is_integer(value) -> value |> max(@deadline.min) |> min(@deadline.max)
      _absent_or_nonsense -> @deadline.default
    end
  end
end
