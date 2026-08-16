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

  alias ExMove.{Chain, FK, Frame, IK, JointState, Math}

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

  # Metres per second at the tool centre point. ISO 10218 puts manual-mode
  # motion at 250 mm/s, and this is the only place in the system that can
  # enforce it: it is the only place that knows the tool speed being commanded.
  #
  # Functional, not protective. It runs on the same BEAM as the thing it guards,
  # so it is a convenience against a slipped decimal point in a pendant and not
  # a safety-rated speed limiter. The E-stop is a hardware circuit; see
  # protocol/DESIGN.md on the split.
  #
  # Always on, because manual is the only mode this controller has. When mode
  # becomes real — `state.controller_mode` is declared in the model and nothing
  # serves it — this becomes the manual-mode value and auto gets its own.
  #
  # It caps translation only. A rotation about the tool centre point moves the
  # TCP at zero by definition, so this never binds on one, while points out on
  # the tool body are moving at ω×r. That gap is real and is not closed here.
  @default_max_tool_velocity 0.25

  # rad/s for the rotational half of a linear move. Slower than it could be: a
  # wrist that whips round while the tool crawls along a line is doing what was
  # asked and not what was meant.
  @default_angular_feedrate 0.5

  # How close counts as arrived. 0.1mm is an order below what the simulated
  # drives report, and a hair under a tenth of a degree is finer than any tool
  # this is likely to be holding.
  @default_position_tolerance 1.0e-4
  @default_orientation_tolerance 1.0e-3

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
    :frame,
    :twist,
    :motion,
    :hz,
    :tick_ms,
    :max_joint_velocity,
    :max_tool_velocity,
    :residual_floor,
    :speed_floor,
    :clock,
    :timer,
    queue: [],
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
    frame = Keyword.get(opts, :frame, :base)

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
            if Process.alive?(pid), do: refresh(pid, frame, twist), else: {:error, :restarting}

          {:error, reason} ->
            {:error, reason}
        end

      pid ->
        refresh(pid, frame, twist)
    end
  end

  @doc """
  Move the tool centre point to `target` in a straight line, and stop there.

  Not held. A jog is an assertion that someone is still pressing a button; this
  is a command with an end in it, and the end is the arrival rather than a
  deadline. Nothing has to keep talking to the controller for it to finish, which
  is the whole difference — and also the thing to be careful about, because a
  client that disappears mid-move does not stop the arm. `release/1` does, and so
  does any other command on the same object.

  Same machinery as the jog underneath: same tick, same rate ceiling, same
  joint-limit stop, same tool speed cap, same reporting. What changes is where
  the twist comes from — an error to a target rather than a direction from a
  client.

  ## Options

    * `:feedrate` — m/s at the tool. Required in spirit; defaults to the manual
      speed limit.
    * `:angular_feedrate` — rad/s. Translation and rotation are synchronised, so
      whichever of the two needs longer sets the pace and they arrive together.
      A move that got there and then turned would not be one move.
    * everything `hold/3` takes.
  """
  def move_linear(%Chain{} = chain, %Frame{} = target, opts \\ []) do
    enqueue(chain, motion(:linear, target, opts), opts)
  end

  @doc """
  Move the tool centre point through `via` to `target` along a circular arc.

  Three points define a circle: where the arm is now, the via point, and the end.
  That is the form every teach pendant uses, and it is the one that can be taught
  by driving the arm to three places rather than by working out a centre.

  Three points that do not define a circle — collinear, or two of them the same —
  are refused rather than approximated. An arc command that quietly becomes a
  straight line is a program that does something different from what it says.

  Orientation is driven toward the end orientation and synchronised with the
  remaining arc length, so it arrives with the position. It is not slerped along
  the path: the tool ends up right and gets there smoothly, but a specific
  orientation partway round is not something this promises.
  """
  def move_arc(%Chain{} = chain, %Frame{} = via, %Frame{} = target, opts \\ []) do
    motion =
      :arc
      |> motion(target, opts)
      |> Map.put(:via, {via.x, via.y, via.z})

    enqueue(chain, motion, opts)
  end

  defp motion(kind, %Frame{} = target, opts) do
    %{
      kind: kind,
      via: nil,
      arc: nil,
      transform: FK.frame_transform(target),
      feedrate: Keyword.get(opts, :feedrate, @default_max_tool_velocity),
      angular_feedrate: Keyword.get(opts, :angular_feedrate, @default_angular_feedrate),
      position_tolerance: Keyword.get(opts, :position_tolerance, @default_position_tolerance),
      orientation_tolerance:
        Keyword.get(opts, :orientation_tolerance, @default_orientation_tolerance),
      # `nil` is FINE: settle on the point. A number is the radius within which
      # this move gives way to the next one, which rounds the corner instead of
      # stopping in it. Every teach pendant calls these FINE and CNT.
      blend: Keyword.get(opts, :blend)
    }
  end

  # Appended, not substituted. A controller that dropped the move it was running
  # whenever a new one arrived would make a two-line program depend on how fast
  # the client sent it.
  defp enqueue(chain, motion, opts) do
    case whereis(chain.name) do
      nil ->
        opts =
          opts
          |> Keyword.put(:chain, chain)
          |> Keyword.put(:twist, List.duplicate(0.0, 6))
          |> Keyword.put(:motion, motion)

        case DynamicSupervisor.start_child(ExMove.StreamSupervisor, {__MODULE__, opts}) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end

      pid ->
        GenServer.call(pid, {:enqueue, motion})
    end
  end

  @doc "How many motions are waiting behind the one running, or nil if no stream."
  def queued(name) do
    case whereis(name) do
      nil -> nil
      pid -> GenServer.call(pid, :queued)
    end
  end

  @doc """
  Stop the stream for `arm`, commanding zero on the way out.  @doc \"""
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
    * `{:limited, :tool_speed, fraction}` — more tool speed was asked for than
      manual mode allows. Unlike the other two this is policy rather than the
      arm's own limit, and it never causes a refusal: a cap doing its job must
      not look like a machine that has failed.
    * `{:refused, :singular}` — either the command is not achievable in the
      direction asked, or the achievable fraction of it has collapsed to nothing.
      Zero is written and the arm stops. Use joint jog, which is the only way out
      of a singularity.
    * `{:refused, {:joint_limit, axis_id}}` — that joint is *at* the end of its
      travel and the command asks to go further. Not a fault and not latched:
      jog the other way and the next tick tracks.
    * `{:refused, :unreadable}` — a joint could not be read.
    * `{:done, :reached}` — a `move_linear/3` arrived. The stream stops ticking
      and stays put, so that "finished" and "was never asked" are different
      answers to a client rather than both being silence.

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

  defp refresh(pid, frame, twist) do
    GenServer.cast(pid, {:refresh, frame, twist})
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
        frame: Keyword.get(opts, :frame, :base),
        twist: Keyword.fetch!(opts, :twist),
        motion: Keyword.get(opts, :motion),
        queue: Keyword.get(opts, :queue, []),
        hz: hz,
        tick_ms: max(round(1000 / hz), 1),
        max_joint_velocity: Keyword.get(opts, :max_joint_velocity, @default_max_joint_velocity),
        max_tool_velocity: Keyword.get(opts, :max_tool_velocity, @default_max_tool_velocity),
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
  def handle_cast({:refresh, frame, twist}, state) do
    # Only the intent. Not the timer, not the phase: an assertion arriving
    # between two ticks must not be able to shorten or lengthen either of them,
    # or the client's jitter becomes the arm's.
    # A refresh un-finishes the stream. Whoever is asserting now is asking for
    # motion, and leaving `{:done, :reached}` in place would leave the guard
    # above swallowing every tick of it.
    # A jog clears the queue as well as the current motion. An operator taking
    # hold of the arm has taken hold of it; queued moves firing afterwards
    # because nobody thought to cancel them is how a machine surprises somebody.
    {:noreply,
     %{
       state
       | frame: frame,
         twist: twist,
         motion: nil,
         queue: [],
         status: status_after_refresh(state)
     }}
  end

  defp status_after_refresh(%{status: {:done, _reason}}), do: :idle
  defp status_after_refresh(%{status: status}), do: status

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

  def handle_call(:queued, _from, state), do: {:reply, length(state.queue), state}

  def handle_call({:enqueue, motion}, _from, state) do
    state =
      case state.motion do
        nil -> %{state | motion: motion, status: :idle}
        _running -> %{state | queue: state.queue ++ [motion]}
      end

    # A finished stream that is handed another move starts ticking again. It
    # stopped its timer on arrival, so without this the queue would fill up and
    # nothing would ever look at it.
    {:reply, :ok, restart_if_idle(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    {state, _result} = step(state, state.tick_ms / 1000.0)

    # A finished move stops ticking. Solving repeatedly for a twist that is zero
    # by construction is work with a known answer, and leaving the timer running
    # would make an arrived arm indistinguishable from a moving one to anything
    # watching the process rather than the status.
    case state.status do
      {:done, _reason} -> {:noreply, state}
      _still_going -> {:noreply, schedule(state)}
    end
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
  # A finished move stays finished. Without this the next tick finds no goal,
  # falls through to the held-jog path, solves for a twist of zeros and reports
  # `:tracking` — an arm standing still, described as one that is following a
  # command. The internal clock stops ticking on arrival so it never sees this;
  # an external one keeps being told to tick, which is how the tests found it and
  # is also what a fieldbus does.
  defp step(%{status: {:done, _reason}} = state, _dt), do: {state, {:ok, :reached}}

  defp step(state, dt) do
    with {:ok, positions} <- joint_positions(state.chain),
         js = %JointState{positions: positions},
         {:ok, state} <- adopt(state, js),
         {:ok, twist} <- commanded_twist(state, js, dt) do
      case twist do
        :arrived ->
          advance(state, js, dt)

        twist ->
          case IK.solve_velocity(state.chain, js, twist) do
            {:ok, %JointState{velocities: dq}, report} ->
              apply_solution(state, positions, dq, twist, report, dt)

            {:error, reason} ->
              refuse(state, reason)
          end
      end
    else
      {:error, reason} -> refuse(state, reason)
    end
  end

  # One motion is finished. Either the next one starts on this same tick, or
  # there is no next one and the arm stops.
  #
  # Starting the next one *here* rather than on the following tick is what makes
  # a blend a blend: the arm never spends a tick with nothing to do, so it never
  # decelerates into the corner it is meant to round.
  defp advance(%{queue: []} = state, _js, _dt) do
    write(state.chain, List.duplicate(0.0, length(state.chain.axis_ids)))
    {%{state | motion: nil, status: {:done, :reached}}, {:ok, :reached}}
  end

  defp advance(%{queue: [next | rest]} = state, _js, dt) do
    step(%{state | motion: next, queue: rest}, dt)
  end

  # Where the twist comes from. A held jog has one handed to it; a move works one
  # out from how far it still has to go.
  defp commanded_twist(%{motion: nil} = state, js, _dt) do
    in_base(state.frame, state.chain, js, state.twist)
  end

  defp commanded_twist(%{motion: motion} = state, js, dt) do
    current = FK.solve_transform(state.chain, js)

    target = waypoint(motion, current, dt)

    {ex, ey, ez} = position_error(current, target)
    {ax, ay, az} = orientation_error(current, motion.transform)

    distance = norm(ex, ey, ez)
    angle = norm(ax, ay, az)
    remaining = remaining_distance(motion, current)
    to_target = norm_of(position_error(current, motion.transform))

    if finished?(motion, remaining, to_target, angle, state.queue) do
      {:ok, :arrived}
    else
      # Translation and rotation are synchronised: whichever needs longer sets
      # the pace and both arrive together. A move that got there and then
      # turned would be two moves wearing one command's name.
      #
      # `dt` is the floor, and it is what stops the arm overshooting: within
      # one tick of the target the remaining error is covered in exactly that
      # tick rather than at a feedrate that would carry it past. No separate
      # deceleration ramp, and none wanted — a ramp is a fact about the drives,
      # which have one.
      #
      # The angular term is paced by the *remaining path*, not by the distance
      # to this tick's waypoint, which on an arc is one tick long and would
      # spin the wrist at the rate needed to finish inside it.
      seconds =
        [
          distance / motion.feedrate,
          remaining / motion.feedrate,
          angle / motion.angular_feedrate,
          dt
        ]
        |> Enum.max()

      linear = max(distance / motion.feedrate, dt)

      {:ok, [ex / linear, ey / linear, ez / linear, ax / seconds, ay / seconds, az / seconds]}
    end
  end

  # A move is over when it has arrived. A move with a blend radius is over
  # earlier — when it is within that radius and there is something to blend into.
  #
  # Two different distances, and they are different on purpose. Blending is about
  # how much *path* is left, because that is what the corner is made of. Arrival
  # is about how far the tool is from the *point*, because that is what arriving
  # means. On a straight move they are the same number; on an arc they are not,
  # and using the path length for arrival makes the tolerance depend on the
  # radius — a small arc reaching it comfortably and a large one never quite
  # getting there.
  #
  # No next motion means no blend, whatever was asked for: rounding a corner into
  # nothing is just stopping short, and the operator asked to end up on the point.
  defp finished?(motion, remaining, to_target, angle, queue) do
    cond do
      motion.blend != nil and queue != [] and remaining <= motion.blend -> true
      to_target < motion.position_tolerance and angle < motion.orientation_tolerance -> true
      true -> false
    end
  end

  # ── Where the arm is being asked to be, this tick ─────────────────────────

  # A straight move aims at its endpoint the whole way. An arc aims one tick
  # ahead along the circle, measured from where the arm actually is — so an arm
  # that has been slowed by a rate ceiling falls behind along the path rather
  # than cutting across it. The waypoint follows the arm; the arm does not chase
  # a clock.
  defp waypoint(%{kind: :linear} = motion, _current, _dt), do: motion.transform

  defp waypoint(%{kind: :arc, arc: arc} = motion, current, dt) do
    theta = arc_angle(arc, Math.translation_of(current))
    step = motion.feedrate * dt / arc.radius

    ahead =
      if arc.sweep >= 0.0 do
        min(theta + step, arc.sweep)
      else
        max(theta - step, arc.sweep)
      end

    arc_point(arc, ahead)
  end

  defp remaining_distance(%{kind: :linear} = motion, current) do
    {ex, ey, ez} = position_error(current, motion.transform)
    norm(ex, ey, ez)
  end

  defp remaining_distance(%{kind: :arc, arc: arc}, current) do
    theta = arc_angle(arc, Math.translation_of(current))
    abs(arc.sweep - theta) * arc.radius
  end

  # ── Circles through three points ──────────────────────────────────────────

  # The arc's geometry is worked out **once**, when the motion becomes the
  # current one, and kept.
  #
  # Once, because the first of its three points is where the arm is — and if that
  # is re-read every tick the circle changes under the arm as it moves along it.
  # Which is not a subtle failure: the arm runs to the via point, the three
  # points become degenerate there, and it stops dead in the middle of the arc
  # and jitters. Written down because "recompute from the live pose every tick"
  # is the right instinct everywhere else in this module and is wrong here. Live
  # feedback belongs in the error term, not in the definition of the path.
  #
  # And when the motion becomes current rather than when it was queued: where the
  # arm is when a queued move finally starts is not where it was when somebody
  # sent it.
  defp adopt(%{motion: %{kind: :arc, arc: nil} = motion} = state, js) do
    current = FK.solve_transform(state.chain, js)
    start = Math.translation_of(current)
    finish = Math.translation_of(motion.transform)

    case circle(start, motion.via, finish) do
      {:ok, arc} -> {:ok, %{state | motion: %{motion | arc: arc}}}
      :degenerate -> {:error, :not_an_arc}
    end
  end

  defp adopt(state, _js), do: {:ok, state}

  # Centre, normal and sweep from three points, by the standard construction:
  # the centre is where the perpendicular bisectors of two chords meet, solved in
  # the plane the three points span.
  defp circle({ax, ay, az} = a, {bx, by, bz} = b, {cx, cy, cz} = c) do
    u = {bx - ax, by - ay, bz - az}
    v = {cx - ax, cy - ay, cz - az}

    w = cross(u, v)
    w_len = norm_of(w)

    # Collinear, or two points on top of each other. Both mean there is no circle
    # through them, and inventing one would be worse than refusing.
    if w_len < 1.0e-9 do
      :degenerate
    else
      normal = scale_vector(w, 1.0 / w_len)

      uu = dot(u, u)
      vv = dot(v, v)

      # centre = a + (uu·(v×w) + vv·(w×u)) / (2|w|²)
      numerator = add(scale_vector(cross(v, w), uu), scale_vector(cross(w, u), vv))
      centre = add(a, scale_vector(numerator, 1.0 / (2.0 * dot(w, w))))

      radius = norm_of(subtract(a, centre))

      x_axis = scale_vector(subtract(a, centre), 1.0 / radius)
      y_axis = cross(normal, x_axis)

      arc = %{centre: centre, normal: normal, radius: radius, x_axis: x_axis, y_axis: y_axis}

      # The sweep is the angle to the end point, taken the way round that passes
      # through the via point. That is the whole reason a via point is given
      # rather than just a centre: it says which way round.
      via_angle = raw_angle(arc, b)
      end_angle = raw_angle(arc, c)

      sweep =
        if via_angle <= end_angle do
          end_angle
        else
          end_angle - 2.0 * :math.pi()
        end

      {:ok, Map.put(arc, :sweep, sweep)}
    end
  end

  # Angle of a point about the arc's centre, in the arc's own plane, measured
  # from the start point and always in [0, 2π).
  defp raw_angle(arc, point) do
    d = subtract(point, arc.centre)
    angle = :math.atan2(dot(d, arc.y_axis), dot(d, arc.x_axis))

    if angle < 0.0, do: angle + 2.0 * :math.pi(), else: angle
  end

  # The same, but continuous across the start rather than wrapping — an arm
  # sitting a hair before the start point should read as "not yet begun", not as
  # "nearly all the way round".
  defp arc_angle(arc, point) do
    angle = raw_angle(arc, point)

    cond do
      arc.sweep >= 0.0 and angle > arc.sweep + :math.pi() -> angle - 2.0 * :math.pi()
      arc.sweep < 0.0 and angle > 0.0 -> angle - 2.0 * :math.pi()
      true -> angle
    end
  end

  # A point on the arc, as a transform carrying the end orientation. Only the
  # translation is used — the rotation is driven separately, toward the end pose
  # and paced by the remaining arc length.
  defp arc_point(arc, theta) do
    {x, y, z} =
      arc.centre
      |> add(scale_vector(arc.x_axis, arc.radius * :math.cos(theta)))
      |> add(scale_vector(arc.y_axis, arc.radius * :math.sin(theta)))

    Math.translation(x, y, z)
  end

  defp dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz
  defp subtract({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp scale_vector({x, y, z}, k), do: {x * k, y * k, z * k}
  defp norm_of({x, y, z}), do: norm(x, y, z)

  defp position_error(current, target) do
    {cx, cy, cz} = Math.translation_of(current)
    {tx, ty, tz} = Math.translation_of(target)
    {tx - cx, ty - cy, tz - cz}
  end

  # The same form the Rust position solver uses — half the sum of the cross
  # products of the corresponding axis pairs. It is an approximation to the
  # rotation vector that is exact in direction and shrinks as sin of the angle,
  # which is everything a resolved-rate loop needs and is the same arithmetic on
  # both sides of the NIF boundary. Two ways of measuring the same error that
  # disagree slightly is a thing to avoid on principle.
  defp orientation_error(current, target) do
    [{c, t} | rest] = Enum.zip(columns(current), columns(target))

    {x, y, z} =
      Enum.reduce(rest, cross(c, t), fn {c, t}, acc -> add(acc, cross(c, t)) end)

    {0.5 * x, 0.5 * y, 0.5 * z}
  end

  defp columns({m0, m1, m2, _, m4, m5, m6, _, m8, m9, m10, _, _, _, _, _}) do
    [{m0, m4, m8}, {m1, m5, m9}, {m2, m6, m10}]
  end

  defp cross({ax, ay, az}, {bx, by, bz}) do
    {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}
  end

  defp add({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  defp norm(x, y, z), do: :math.sqrt(x * x + y * y + z * z)

  # Refuse first, then scale, then write.
  #
  # The order matters, and so does what a refusal does: it writes zero rather
  # than writing nothing. Leaving the joints on their last setpoint until the
  # hold above lapses would mean an arm that could not do what was asked carries
  # on doing the last thing it could, for up to a deadline. An arm that stops
  # because it has run out of arm should stop.
  defp apply_solution(state, positions, dq, twist, report, dt) do
    rate = rate_factor(dq, state.max_joint_velocity)
    {limit, joint} = limit_factor(state.chain, positions, dq, dt)
    speed = tool_speed_factor(twist, state.max_tool_velocity)

    # All three are uniform scales of the same raw motion, so the binding one is
    # simply the smallest, and comparing them is comparing like with like. This
    # is also why the limit factor is computed from the unscaled dq rather than
    # from the rate-scaled one: fractions of the same thing compose by taking a
    # minimum, fractions of each other compose by multiplying, and only one of
    # those is what "stop on the boundary" means.
    #
    # But only two of the three describe the arm. Rate and joint limits are the
    # machine saying what it cannot do; the tool speed cap is policy saying what
    # it may not. That distinction decides the refusal below, so the two are kept
    # apart rather than minimised together and sorted out afterwards.
    {reachable, reachable_reason} =
      if limit < rate, do: {limit, {:joint_limit, joint}}, else: {rate, :rate}

    {fraction, reason} =
      if speed < reachable, do: {speed, :tool_speed}, else: {reachable, reachable_reason}

    cond do
      # Not the direction asked for. Almost always exactly zero, so this fires
      # at a real singularity rather than on a gradient.
      report.residual > state.residual_floor ->
        refuse(state, :singular)

      # Going nowhere, and going nowhere *because the arm cannot*. The speed cap
      # is deliberately not part of this test: commanding 10 m/s scales to a
      # fortieth of what was asked, which is the cap working exactly as intended
      # and would otherwise read as an arm that has run out of travel. A limit
      # doing its job must never look like a failure.
      reachable < state.speed_floor ->
        refuse(state, refusal_reason(reachable_reason))

      true ->
        velocities = Enum.map(dq, &(&1 * fraction))
        write(state.chain, velocities)

        status = if fraction < 1.0, do: {:limited, reason, fraction}, else: :tracking
        {%{state | status: status}, {:ok, velocities}}
    end
  end

  # The fraction of the commanded translation that fits under the tool speed
  # ceiling.
  #
  # Only the linear half. The angular half is rad/s about the tool centre point
  # and has no business being compared against a limit in m/s — adding them under
  # one norm would make a fast spin look like a fast translation and slow both.
  defp tool_speed_factor([vx, vy, vz, _wx, _wy, _wz], ceiling) do
    speed = :math.sqrt(vx * vx + vy * vy + vz * vz)

    if speed > ceiling, do: ceiling / speed, else: 1.0
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

  # The commanded twist, rotated into the base frame the Jacobian works in.
  #
  # Resolved every tick and not once at the press, because the tool frame moves
  # with the tool. For a translation that makes no difference — translating does
  # not change orientation — but a rotation about a tool axis is a rotation about
  # an axis that is itself turning, and freezing it at the press would trace a
  # cone where the operator asked for a spin.
  #
  # Both halves are rotated. A twist is two vectors in one frame, and rotating
  # the linear part while leaving the angular part in base would produce motion
  # in a frame that does not exist.
  defp in_base(:base, _chain, _js, twist), do: {:ok, twist}

  defp in_base(:tool, chain, js, twist) do
    r = FK.solve_transform(chain, js)
    [vx, vy, vz, wx, wy, wz] = twist

    {lx, ly, lz} = rotate(r, {vx, vy, vz})
    {ax, ay, az} = rotate(r, {wx, wy, wz})

    {:ok, [lx, ly, lz, ax, ay, az]}
  end

  # A user frame is fixed in the base, so unlike the tool frame its rotation
  # does not change as the arm moves — but it is still resolved here rather
  # than at the press, because that keeps one code path for all three and the
  # cost is a matrix multiply against a 5 ms tick.
  #
  # The frame arrives already resolved, as six numbers relative to the base.
  # Composing it with its parents is storage's problem and is done by whoever
  # read the row; this module knows kinematics and nothing about a database.
  defp in_base({:user, %Frame{} = frame}, _chain, _js, twist) do
    r = FK.frame_transform(frame)
    [vx, vy, vz, wx, wy, wz] = twist

    {lx, ly, lz} = rotate(r, {vx, vy, vz})
    {ax, ay, az} = rotate(r, {wx, wy, wz})

    {:ok, [lx, ly, lz, ax, ay, az]}
  end

  # An unknown frame is refused rather than quietly treated as base. A pendant
  # showing USER and moving the arm in WORLD is the kind of wrong that gets
  # noticed by a fixture.
  defp in_base(_unknown, _chain, _js, _twist), do: {:error, :unknown_frame}

  defp rotate({m0, m1, m2, _, m4, m5, m6, _, m8, m9, m10, _, _, _, _, _}, {x, y, z}) do
    {m0 * x + m1 * y + m2 * z, m4 * x + m5 * y + m6 * z, m8 * x + m9 * y + m10 * z}
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
        %{actual_position: position} = status ->
          ensure_velocity_mode(axis_id, status)
          {:cont, {:ok, [position | acc]}}

        _other ->
          {:halt, {:error, :unreadable}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      other -> other
    end
  catch
    :exit, _reason -> {:error, :unreadable}
  end

  # Checked every tick, and set only when it is wrong.
  #
  # The mode used to be set once, when the stream started, which is fine until
  # something else changes it — and something else does: writing a position
  # setpoint puts that drive into profile_position, deliberately, because
  # otherwise the write would be silently discarded. A stream that outlives such
  # a write then spends its whole life commanding velocities into drives that
  # ignore them, and the arm simply does not move while every status reads
  # healthy. Found on a live controller after a `move_arc` that sat perfectly
  # still and reported nothing wrong.
  #
  # It is free: the status was already read this tick for the joint position, so
  # this costs a comparison, and the `set_mode` call only happens on the tick
  # where the mode is actually wrong.
  defp ensure_velocity_mode(_axis_id, %{mode: :profile_velocity}), do: :ok
  defp ensure_velocity_mode(axis_id, _status), do: Exdrive.Drive.set_mode(axis_id, :profile_velocity)

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

  # A stream that stopped its timer on arrival needs it back when work arrives.
  # Only ever from `{:done, _}`: restarting a timer that is already running would
  # double the tick rate, which is the sort of bug that reads as "the arm is
  # twice as fast now" and takes an afternoon.
  defp restart_if_idle(%{status: {:done, _reason}} = state) do
    schedule(%{state | status: :idle})
  end

  defp restart_if_idle(state), do: state

  defp schedule(%{clock: :external} = state), do: state

  defp schedule(state) do
    %{state | timer: Process.send_after(self(), :tick, state.tick_ms)}
  end
end
