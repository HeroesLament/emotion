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

  # Radians per second, per joint. Whatever is over is brought under by scaling
  # the whole vector.
  #
  # Scaling the vector, never clamping per joint, and never damping the solve:
  # the ratios between joints *are* the direction. Clamping one joint and not the
  # others breaks those ratios outright; damping bends them more politely and
  # just as surely. Scaling meets the ceiling with the direction untouched and
  # the speed reduced, which is the cheaper thing to lose and the one an operator
  # can see happening.
  @default_max_joint_velocity 0.5

  # The fraction of the commanded twist the joints may fail to deliver before the
  # jog is refused rather than approximated.
  #
  # With no damping in the solve this is zero wherever the command is achievable
  # at all, so the floor is not a tuning knob with a gradient under it — it
  # separates "the arm can do this" from "the arm cannot".
  #
  # A quarter, measured. At an exact wrist singularity on the demo chain, a
  # single-axis rotation still comes back with a residual of at most 0.098: the
  # five remaining joints supply nine tenths of it between them. So single-axis
  # jog commands essentially never trip this, and on this arm it is the speed
  # floor below that does the stopping. It is here for the commands that can
  # genuinely have no achievable component — diagonal twists, other chains, other
  # tools — rather than as the guard that fires every day.
  @default_residual_floor 0.25

  # The fraction of the commanded tool speed below which the jog is refused
  # rather than reported as slow.
  #
  # Approaching a boundary singularity the achievable tool speed goes to zero
  # smoothly — which is physically correct and, on a pendant, indistinguishable
  # from a hang. Below a fiftieth of what was asked the arm has stopped in every
  # sense an operator cares about, and saying so is more use than creeping.
  @default_speed_floor 0.02

  defstruct [
    :chain,
    :twist,
    :hz,
    :tick_ms,
    :max_joint_velocity,
    :residual_floor,
    :speed_floor,
    :clock,
    :timer,
    status: :idle
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
          {:ok, _pid} ->
            :ok

          # The other side of the race in `whereis/1`: the name is still held by
          # a process that has died but not yet been reaped. Refreshing it would
          # cast into a grave, so the assertion is refused and the next one — 100
          # ms later, from a client that is still holding the button — starts
          # cleanly.
          {:error, {:already_started, pid}} ->
            if Process.alive?(pid), do: refresh(pid, twist), else: {:error, :restarting}

          {:error, reason} ->
            {:error, reason}
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

  @doc """
  What the arm is doing with the intent it was given.

    * `:idle` — no tick has run yet.
    * `:tracking` — the commanded twist is being delivered.
    * `{:limited, :rate, fraction}` — a joint would have had to turn faster than
      its ceiling, so the whole motion is scaled to `fraction` of the commanded
      tool speed. The tool is still exactly on the commanded line. This is what
      approaching a singularity looks like from the inside, and the number is the
      point: "moving at 12% of commanded" is a machine explaining itself.
    * `{:limited, {:joint_limit, axis_id}, fraction}` — that joint is about to
      reach the end of its travel, and the whole motion is slowed so the arm
      lands on the boundary rather than a tick past it.
    * `{:refused, :singular}` — either the command is not achievable in the
      direction asked, or the achievable fraction of it has collapsed to nothing.
      Zero is written and the arm stops. Use joint jog, which is the only way out
      of a singularity.
    * `{:refused, {:joint_limit, axis_id}}` — that joint is *at* the end of its
      travel and the command asks to go further. Not a fault and not latched:
      jog the other way and the next tick tracks.
    * `{:refused, :unreadable}` — a joint could not be read.

  A pendant that says "limited: near singularity" is a machine explaining
  itself. One that silently slows down is a machine that feels broken, and this
  is what stands between the two.
  """
  def status(name) do
    case whereis(name) do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "The twist currently being held for `arm`, or nil."
  def intent(name) do
    case whereis(name) do
      nil -> nil
      pid -> GenServer.call(pid, :intent)
    end
  end

  @doc """
  The stream running for `arm`, or nil.

  The liveness check is not belt and braces. `Registry` drops a key when it
  processes the `:DOWN` for the owning process, which happens in the Registry's
  own process and therefore *after* `GenServer.stop/1` has returned to whoever
  called it. Without this, a caller that stops a stream and immediately asks
  whether one is running is told yes, by a name whose process is already gone.
  """
  def whereis(name) do
    case Registry.lookup(ExMove.StreamRegistry, name) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
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
        residual_floor: Keyword.get(opts, :residual_floor, @default_residual_floor),
        speed_floor: Keyword.get(opts, :speed_floor, @default_speed_floor),
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
    {state, result} = step(state, dt)
    {:reply, result, state}
  end

  def handle_call({:tick, _dt}, _from, state) do
    {:reply, {:error, :internal_clock}, state}
  end

  def handle_call(:intent, _from, state), do: {:reply, state.twist, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:tick, state) do
    {state, _result} = step(state, state.tick_ms / 1000.0)
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
  defp step(state, dt) do
    with {:ok, positions} <- joint_positions(state.chain),
         {:ok, %JointState{velocities: dq}, report} <-
           IK.solve_velocity(state.chain, %JointState{positions: positions}, state.twist) do
      apply_solution(state, positions, dq, report, dt)
    else
      {:error, reason} -> refuse(state, reason)
    end
  end

  # Refuse first, then scale, then write.
  #
  # The order matters, and so does what a refusal does: it writes zero rather
  # than writing nothing. Leaving the joints on their last setpoint until the
  # hold above lapses would mean an arm that could not do what was asked carries
  # on doing the last thing it could, for up to a deadline. An arm that stops
  # because it has run out of arm should stop.
  defp apply_solution(state, positions, dq, report, dt) do
    rate = rate_factor(dq, state.max_joint_velocity)
    {limit, joint} = limit_factor(state.chain, positions, dq, dt)

    # Both are uniform scales of the same raw vector, so the binding one is
    # simply the smaller, and comparing them is comparing like with like. This
    # is also why the limit factor is computed from the unscaled dq rather than
    # from the rate-scaled one: two fractions of the same thing compose by
    # taking a minimum, two fractions of each other compose by multiplying, and
    # only one of those is what "stop on the boundary" means.
    {fraction, reason} = if limit < rate, do: {limit, {:joint_limit, joint}}, else: {rate, :rate}

    cond do
      # Not the direction asked for. Almost always exactly zero, so this fires
      # at a real singularity rather than on a gradient.
      report.residual > state.residual_floor ->
        refuse(state, :singular)

      # Going nowhere. Which of the two reasons put it there is carried through
      # rather than collapsed: "the arm stopped" is a support call, and "J5 is at
      # its limit" is something an operator can act on without one.
      fraction < state.speed_floor ->
        refuse(state, refusal_reason(reason))

      true ->
        velocities = Enum.map(dq, &(&1 * fraction))
        write(state.chain, velocities)

        status = if fraction < 1.0, do: {:limited, reason, fraction}, else: :tracking
        {%{state | status: status}, {:ok, velocities}}
    end
  end

  # A rate ceiling that has scaled the motion to nothing is a singularity by
  # another name — it is what approaching one looks like from the rate side. A
  # joint limit is not, and keeps its own name.
  defp refusal_reason({:joint_limit, joint}), do: {:joint_limit, joint}
  defp refusal_reason(:rate), do: :singular

  defp refuse(state, reason) do
    write(state.chain, List.duplicate(0.0, length(state.chain.axis_ids)))
    {%{state | status: {:refused, reason}}, {:error, reason}}
  end

  # The fraction of the commanded motion that fits under the rate ceiling. One
  # number for the whole vector, which is what keeps the direction intact.
  defp rate_factor(dq, ceiling) do
    peak = dq |> Enum.map(&abs/1) |> Enum.max()

    if peak > ceiling, do: ceiling / peak, else: 1.0
  end

  # The fraction of this tick's motion that fits inside every joint's travel,
  # and the joint that decided it.
  #
  # This is where `dt` finally earns the ride it has been getting since the
  # stream landed. A limit is a position and a tick commands a velocity, and the
  # only thing that converts between them is the length of the tick. Scaled by
  # this factor the arm lands exactly on the boundary at the end of the tick
  # rather than a controller-cycle past it.
  #
  # The whole vector again, not the offending joint: stopping one joint of six
  # and letting the others run is a change of direction, and the operator asked
  # for a direction.
  # The joint is named by its `axis_id` and not by `joint.id`. Those are two
  # different mappings on a `Chain` — one is what the chain calls a joint, the
  # other is the drive it is bound to — and they coincide on the demo arm, which
  # is exactly the sort of coincidence that hides a wrong name until a machine
  # with renamed axes reports a joint the client has never heard of. The client
  # only knows axis ids; every other node id in the model is built from them.
  defp limit_factor(chain, positions, dq, dt) do
    chain.axis_ids
    |> Enum.zip(chain.joints)
    |> Enum.zip(Enum.zip(positions, dq))
    |> Enum.reduce({1.0, nil}, fn {{axis_id, joint}, {q, rate}}, {best, chosen} ->
      case travel_fraction(joint.limit, q, rate * dt) do
        nil -> {best, chosen}
        f when f < best -> {f, axis_id}
        _ -> {best, chosen}
      end
    end)
  end

  # nil means continuous — a joint that can turn forever, and a great many can.
  defp travel_fraction(nil, _q, _step), do: nil

  # lo >= hi is the other way a chain says continuous, and it is the one the NIF
  # boundary uses. Accepted here so that one description of a joint does not mean
  # two things depending on which side of the language boundary is reading it.
  defp travel_fraction({lo, hi}, _q, _step) when lo >= hi, do: nil

  defp travel_fraction(_limit, _q, step) when step == 0.0, do: nil

  defp travel_fraction({lo, hi}, q, step) do
    room = if step > 0.0, do: hi - q, else: lo - q

    cond do
      # Already outside, and still heading out. Nothing about this tick is
      # allowed. It should not happen, and a limit check that assumes it cannot
      # is a limit check that fails open the one time it matters.
      room / step <= 0.0 -> 0.0
      room / step < 1.0 -> room / step
      true -> nil
    end
  end

  defp write(chain, velocities) do
    chain.axis_ids
    |> Enum.zip(velocities)
    |> Enum.each(fn {axis_id, velocity} ->
      Exdrive.Drive.set_target_velocity(axis_id, velocity)
    end)
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
