defmodule ExMove.CartesianStream do
  @moduledoc """
  Cartesian motion, interpolated on the controller's clock rather than the
  client's.

  One process per arm. A client asserting a Cartesian jog does not command joint
  velocities and does not command a pose — it *refreshes an intent*: a direction
  and a speed. This process re-solves that intent from the arm's live joint
  positions at its own rate and writes joint velocity setpoints.

  ## Why the two rates have to be separate

  A jog assertion arrives at roughly 10 Hz, because that is a sensible rate at
  which to tell a controller somebody is still holding a button. Solving once per
  assertion and letting the joints coast until the next one makes the *client's*
  rate the interpolation rate, and the two have nothing to do with each other:
  one is a fact about the network, the other is a fact about the arm.

  What it costs is a chord where an arc was asked for. Measured on the demo arm,
  jogging +Z for two seconds and taking the worst lateral deviation:

      rate     0.05 m/s (jog)    0.25 m/s (ISO 10218 manual max)
      10 Hz          0.346mm                           12.63mm
      100 Hz         0.035mm                            1.44mm
      200 Hz         0.017mm                            0.73mm

  First order in the tick, and roughly quadratic in speed — the sagitta of a
  chord goes as the square of its length. At jog speed 10 Hz is already inside a
  millimetre; at the speed the machine is allowed to move in manual mode it is
  twelve times outside it, and the error does not cancel. Chord error always
  falls to the inside of the curve, so two seconds of it accumulates in one
  direction.

  The accuracy is the measurable half. The structural half matters more: the
  singularity damping, the joint-limit stop and the tool speed limit all have to
  be evaluated on a clock the controller owns, and this is that clock. Without it
  there is nowhere to put them.

  ## What this is not

  It is not the watchdog. `ExProto.Jog` decides whether the operator is still
  holding the button and what happens when a link drops; this process decides
  where the arm goes while they are. Refreshing the intent does not restart the
  tick or reset its phase — it replaces one number and returns.

  It is also not a hold. Two sessions cannot both be jogging one arm, but that is
  enforced above, where sessions exist.

  ## The clock

  `:internal` self-schedules, `:external` waits for `tick/2` — the same split
  `Exdrive.Drive` makes and for the same reason. A test that steps the stream and
  the drives by the same dt is measuring the interpolation, not the scheduler.
  """

  use GenServer

  alias ExMove.{Chain, IK, JointState}

  # 5ms. Each solve costs ~37µs measured, so this is under 1% of a core per arm,
  # and it puts the worst deviation at the manual speed limit comfortably inside
  # a millimetre. Not 1kHz to match the drives: nothing above is asking for the
  # path to be that good, and the headroom is worth more than the last 0.7mm.
  @default_hz 200

  # Radians per second, per joint. The ceiling is applied by scaling the whole
  # vector, never per joint: the ratios between joints *are* the direction, so an
  # arm with one joint clipped and the rest untouched travels somewhere nobody
  # pointed, slowly and confidently.
  @default_max_joint_velocity 0.5

  defstruct [
    :chain,
    :twist,
    :hz,
    :tick_ms,
    :max_joint_velocity,
    :clock,
    :timer
  ]

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Start a stream for `chain`, or refresh the one already running for it.

  The twist is `[vx, vy, vz, wx, wy, wz]` in the base frame, m/s and rad/s.

  Start-or-refresh rather than start-then-refresh because the caller is a jog
  assertion, and an assertion should not have to know whether it is the first
  one. Refresh is a cast: at 10 Hz into a process that must not miss its tick,
  there is nothing useful for the caller to do with a reply.
  """
  def hold(%Chain{} = chain, twist, opts \\ []) when length(twist) == 6 do
    case whereis(chain.name) do
      nil ->
        opts = opts |> Keyword.put(:chain, chain) |> Keyword.put(:twist, twist)

        case DynamicSupervisor.start_child(ExMove.StreamSupervisor, {__MODULE__, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, pid}} -> refresh(pid, twist)
          {:error, reason} -> {:error, reason}
        end

      pid ->
        refresh(pid, twist)
    end
  end

  @doc """
  Stop the stream for `arm`, commanding zero on the way out.

  The explicit zero is what makes a released button feel attached to the machine.
  It is not what stops the arm if this process dies — nothing sent is what does
  that, one layer down, and the two should not be confused.
  """
  def release(%Chain{name: name}), do: release(name)

  def release(name) when is_atom(name) do
    case whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @doc "Advance an `:external`-clocked stream by `dt` seconds. Tests only."
  def tick(name, dt) when is_number(dt) and dt > 0 do
    case whereis(name) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:tick, dt})
    end
  end

  @doc "The twist currently being held for `arm`, or nil."
  def intent(name) do
    case whereis(name) do
      nil -> nil
      pid -> GenServer.call(pid, :intent)
    end
  end

  def whereis(name) do
    case Registry.lookup(ExMove.StreamRegistry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    GenServer.start_link(__MODULE__, opts, name: via(chain.name))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :chain).name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  defp via(name), do: {:via, Registry, {ExMove.StreamRegistry, name}}

  defp refresh(pid, twist) do
    GenServer.cast(pid, {:refresh, twist})
    :ok
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    chain = Keyword.fetch!(opts, :chain)
    hz = Keyword.get(opts, :hz, @default_hz)
    clock = Keyword.get(opts, :clock, :internal)

    # An arm that is not fully enabled is refused here rather than discovered a
    # joint at a time during the first tick, which would leave some joints
    # commanded and some not — a shape of motion nobody asked for.
    with :ok <- all_enabled(chain) do
      Enum.each(chain.axis_ids, &Exdrive.Drive.set_mode(&1, :profile_velocity))

      # Zeros are written on the way out, including on an ordinary supervisor
      # shutdown. A stream that is stopped without them leaves six joints holding
      # their last setpoint.
      Process.flag(:trap_exit, true)

      state = %__MODULE__{
        chain: chain,
        twist: Keyword.fetch!(opts, :twist),
        hz: hz,
        tick_ms: max(round(1000 / hz), 1),
        max_joint_velocity: Keyword.get(opts, :max_joint_velocity, @default_max_joint_velocity),
        clock: clock
      }

      {:ok, schedule(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:refresh, twist}, state) do
    # Only the intent. Not the timer, not the phase: an assertion arriving
    # between two ticks must not be able to shorten or lengthen either of them,
    # or the client's jitter becomes the arm's.
    {:noreply, %{state | twist: twist}}
  end

  @impl true
  def handle_call({:tick, dt}, _from, %{clock: :external} = state) do
    {:reply, step(state, dt), state}
  end

  def handle_call({:tick, _dt}, _from, state) do
    {:reply, {:error, :internal_clock}, state}
  end

  def handle_call(:intent, _from, state), do: {:reply, state.twist, state}

  @impl true
  def handle_info(:tick, state) do
    step(state, state.tick_ms / 1000.0)
    {:noreply, schedule(state)}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.chain.axis_ids, &Exdrive.Drive.set_target_velocity(&1, 0.0))
    :ok
  end

  # ── The tick ──────────────────────────────────────────────────────────────

  # `dt` is passed rather than read from the state because the joint-limit stop
  # in section 4 of protocol/CARTESIAN.md needs to predict `q + dq·dt`, and a
  # tick that does not know its own length cannot.
  defp step(state, _dt) do
    with {:ok, positions} <- joint_positions(state.chain),
         {:ok, %JointState{velocities: dq}} <-
           IK.solve_velocity(state.chain, %JointState{positions: positions}, state.twist) do
      dq = scale(dq, state.max_joint_velocity)

      state.chain.axis_ids
      |> Enum.zip(dq)
      |> Enum.each(fn {axis_id, velocity} ->
        Exdrive.Drive.set_target_velocity(axis_id, velocity)
      end)

      {:ok, dq}
    else
      # Nothing is written on a failed solve, so the joints hold their last
      # setpoint until the hold above lapses. That is deliberate for now and it
      # is not good enough: a singularity should damp and then refuse, and a
      # refusal should say so. Section 2 of protocol/CARTESIAN.md.
      {:error, reason} -> {:error, reason}
    end
  end

  # One observation per joint per tick, in the chain's order. A pose assembled
  # from joints read at six different instants is a pose the arm was never in,
  # and on a moving arm the error looks like a plausible position rather than
  # like a fault.
  defp joint_positions(chain) do
    Enum.reduce_while(chain.axis_ids, {:ok, []}, fn axis_id, {:ok, acc} ->
      case Exdrive.Drive.status(axis_id) do
        %{actual_position: position} -> {:cont, {:ok, [position | acc]}}
        _other -> {:halt, {:error, :unreadable}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      other -> other
    end
  catch
    :exit, _reason -> {:error, :unreadable}
  end

  defp scale(dq, ceiling) do
    peak = dq |> Enum.map(&abs/1) |> Enum.max()

    if peak > ceiling do
      Enum.map(dq, &(&1 * ceiling / peak))
    else
      dq
    end
  end

  defp all_enabled(chain) do
    Enum.reduce_while(chain.axis_ids, :ok, fn axis_id, :ok ->
      case Exdrive.Drive.status(axis_id) do
        %{state: :operation_enabled} -> {:cont, :ok}
        _not_enabled -> {:halt, {:error, :not_enabled}}
      end
    end)
  catch
    :exit, _reason -> {:error, :not_enabled}
  end

  defp schedule(%{clock: :external} = state), do: state

  defp schedule(state) do
    %{state | timer: Process.send_after(self(), :tick, state.tick_ms)}
  end
end
