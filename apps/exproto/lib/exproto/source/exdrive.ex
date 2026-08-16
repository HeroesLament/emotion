defmodule ExProto.Source.Exdrive do
  @moduledoc """
  Binds the node table to the running simulated drives.

  `ExProto.Source.Static` proved the protocol without a machine behind it. This
  is the same behaviour backed by `Exdrive.Drive` processes, which is what turns
  a served node table into a served robot.

  ## One status call per axis, not one per node

  A pendant rendering an axis asks for its position, target, velocity, state and
  fault together. Reading those one at a time is five `:gen_statem.call/2`
  round trips into the same process for one snapshot that the process could
  have handed over once — and worse, five snapshots taken at five different
  instants, so the velocity a client renders need not be the velocity that went
  with the position beside it.

  So `read_many/2` groups by axis and calls `Exdrive.Drive.status/1` once each.
  Every value in a batch for one axis comes from the same observation.

  ## Writes are checked, cast, and read back

  `Exdrive.Drive.set_target_position/2` is a cast, and a setpoint sent to a
  drive that is not in `switched_on` or `operation_enabled` is discarded rather
  than queued. A source that cast and reported success would tell a client the
  arm had been commanded when nothing had happened.

  So the state is checked first and a write to a drive that cannot accept one is
  `:rejected`. After the cast, `status/1` reads the value back — a call is
  ordered behind the casts already sent to that process, so the read cannot
  overtake the write — and the value returned to the client is what the drive
  actually holds, not what was asked for.
  """

  @behaviour ExProto.Source

  require Logger

  alias ExMo.Schema.Registry
  alias ExMove.{CartesianStream, FK, Frame, IK, JointState}
  alias ExProto.Mode

  # CiA 402 states in which the drive accepts a setpoint. Everything else
  # discards it; see Exdrive.Drive.
  @accepting [:switched_on, :operation_enabled]

  # Radians or metres per second, whichever the axis is. One number for both
  # because the simulated arm is rotary throughout; a machine with a linear
  # axis needs this per axis and read from the model, not from here.
  @max_jog_velocity 0.5

  @impl ExProto.Source
  def read(node_id, arg) do
    case read_many([node_id], arg) do
      [{^node_id, result}] -> result
      _ -> {:error, :unknown_node}
    end
  end

  @impl ExProto.Source
  def read_many(node_ids, arg) do
    {state_ids, rest} = Enum.split_with(node_ids, &controller_state?/1)
    {cartesian_ids, rest} = Enum.split_with(rest, &cartesian?/1)
    {tcp_ids, axis_ids} = Enum.split_with(rest, &tcp?/1)

    read_axes(axis_ids) ++
      read_tcp(tcp_ids) ++
      read_cartesian(cartesian_ids) ++
      read_state(state_ids, arg)
  end

  # ── The controller's own state ────────────────────────────────────────────

  # `state.controller_mode` and `state.fault_present` have been in the model
  # since it was written and no source has ever answered them, so browsing found
  # them readable and reading them returned UnknownNode. A model that advertises
  # a node nothing serves is worse than one that omits it: a client cannot tell
  # "this controller does not have that" from "this controller is broken", and
  # the browse says the opposite of the read in the same session.
  defp read_state([], _arg), do: []

  defp read_state(node_ids, arg) do
    faulted? = any_faulted?()
    Enum.map(node_ids, &{&1, state_value(&1, faulted?, mode_server(arg))})
  end

  # Which mode process this controller's. Named per endpoint like the watchdog,
  # because the test suite runs several controllers in one VM and a mode shared
  # between them would let one test's keyswitch refuse another test's jog.
  defp mode_server(arg) when is_list(arg), do: Keyword.get(arg, :mode, Mode)
  defp mode_server(_arg), do: Mode

  # The selector position and the fault condition, combined into the one
  # vocabulary the model publishes.
  #
  # They are kept apart underneath — a fault is something the machine is in, not
  # somewhere an operator turned a key to, and letting a fault move the selector
  # would mean clearing the fault left the machine wherever the fault had put it.
  # Fault wins on the way out, because an operator looking at a faulted machine
  # is not helped by being told it is in manual.
  defp state_value("state.controller_mode", true, _server), do: {:ok, "fault"}

  defp state_value("state.controller_mode", false, server),
    do: {:ok, Atom.to_string(Mode.selected(server))}

  defp state_value("state.fault_present", faulted?, _server), do: {:ok, faulted?}
  defp state_value(_unknown, _faulted?, _server), do: {:error, :unknown_node}

  defp any_faulted? do
    Registry.arm_chain().axis_ids
    |> Enum.any?(fn axis_id ->
      case status(Atom.to_string(axis_id)) do
        {:ok, %{state: state}} -> state in [:fault, :fault_reaction_active]
        # A drive that cannot be read is not evidence of a fault, and reporting
        # one would send an operator looking for something that is not there.
        # It is a wiring problem, and `axes.jN.state` is where it shows.
        {:error, _reason} -> false
      end
    end)
  end

  defp controller_state?(node_id), do: String.starts_with?(node_id, "state.")

  defp read_axes(node_ids) do
    node_ids
    |> Enum.group_by(&axis_of/1)
    |> Enum.flat_map(fn
      {nil, ids} ->
        Enum.map(ids, &{&1, {:error, :unknown_node}})

      {axis, ids} ->
        case status(axis) do
          {:ok, status} -> Enum.map(ids, &{&1, project(&1, status)})
          {:error, reason} -> Enum.map(ids, &{&1, {:error, reason}})
        end
    end)
  end

  # ── Where the tool is ─────────────────────────────────────────────────────

  # One forward-kinematics solve for however many components were asked for,
  # from one observation of every joint.
  #
  # Not six solves, and more importantly not six *observations*: a pose
  # assembled from joints read at six different instants is a pose the arm was
  # never in. On a moving arm the error is small and entirely wrong — it looks
  # like a plausible position rather than like a fault, which is the worst way
  # for a number to be untrue.
  defp read_tcp([]), do: []

  defp read_tcp(node_ids) do
    chain = Registry.arm_chain()

    case joint_positions(chain) do
      {:ok, positions} ->
        frame = FK.solve(chain, %JointState{positions: positions})
        Enum.map(node_ids, &{&1, component(&1, frame)})

      {:error, reason} ->
        Enum.map(node_ids, &{&1, {:error, reason}})
    end
  end

  # Every joint in the chain's order, which is the order forward kinematics
  # expects and is not necessarily the order a client asked in.
  defp joint_positions(chain) do
    Enum.reduce_while(chain.axis_ids, {:ok, []}, fn axis_id, {:ok, acc} ->
      case status(Atom.to_string(axis_id)) do
        {:ok, status} -> {:cont, {:ok, [status.actual_position | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp component("axes.tcp.x", frame), do: {:ok, frame.x}
  defp component("axes.tcp.y", frame), do: {:ok, frame.y}
  defp component("axes.tcp.z", frame), do: {:ok, frame.z}
  defp component("axes.tcp.rx", frame), do: {:ok, frame.rx}
  defp component("axes.tcp.ry", frame), do: {:ok, frame.ry}
  defp component("axes.tcp.rz", frame), do: {:ok, frame.rz}
  defp component(_unknown, _frame), do: {:error, :unknown_node}

  defp tcp?(node_id), do: String.starts_with?(node_id, "axes.tcp.")

  # ── What the Cartesian motion is doing ────────────────────────────────────

  # The stream's own account of itself, projected onto the model.
  #
  # These are read from the stream rather than recomputed here. Recomputing would
  # give a second opinion formed a few milliseconds later from a different pose,
  # and a client comparing "the arm is limited to 12%" against an arm that is not
  # limited any more has been told two true things that contradict each other.
  #
  # No stream running is `idle` rather than an error: nothing is wrong with an
  # arm that is not being jogged, and a pendant rendering this node needs a value
  # for the case it will see most of the time.
  defp read_cartesian([]), do: []

  defp read_cartesian(node_ids) do
    status = CartesianStream.status(Registry.arm_chain().name) || :idle
    Enum.map(node_ids, &{&1, cartesian_value(&1, status)})
  end

  # Every shape the stream's status can take, and no catch-all on the way in.
  #
  # There was one missing — `{:done, :reached}`, added with `move_linear` in
  # exmove and not taught to this projection — and the way it announced itself
  # was a CaseClauseError inside a read, which closed the client's connection
  # with a 1011. A client asking a perfectly reasonable question got its session
  # dropped, which is a much worse failure than a wrong answer.
  #
  # `cartesian_status_test.exs` now walks every status the stream can produce
  # through all four of these, so the next one added has to arrive here too.
  @doc false
  # Public so the projection can be tested against every status directly rather
  # than only through whichever ones a live arm happens to reach.
  def cartesian_value("axes.cartesian.state", status) do
    case status do
      :idle -> {:ok, "idle"}
      :tracking -> {:ok, "tracking"}
      {:limited, _reason, _fraction} -> {:ok, "limited"}
      {:refused, _reason} -> {:ok, "refused"}
      {:done, _reason} -> {:ok, "done"}
    end
  end

  def cartesian_value("axes.cartesian.speed_fraction", status) do
    case status do
      {:limited, _reason, fraction} -> {:ok, fraction}
      # Refused is 0.0 and not "the fraction it would have managed". The arm has
      # been commanded to zero, and a speed node reporting anything else while
      # the arm is stopped is the node lying about the machine.
      {:refused, _reason} -> {:ok, 0.0}
      # A finished move is stopped, and stopped is not a fraction of a speed
      # nobody is commanding any more.
      {:done, _reason} -> {:ok, 0.0}
      _tracking_or_idle -> {:ok, 1.0}
    end
  end

  def cartesian_value("axes.cartesian.reason", status) do
    case status do
      {:limited, reason, _fraction} -> {:ok, reason_name(reason)}
      {:refused, reason} -> {:ok, reason_name(reason)}
      {:done, reason} -> {:ok, reason_name(reason)}
      _tracking_or_idle -> {:ok, ""}
    end
  end

  # Empty rather than absent, and empty rather than "none". A pendant binding a
  # label to this node wants a string on every read, including the reads where
  # there is nothing to say.
  def cartesian_value("axes.cartesian.joint", status) do
    case status do
      {:limited, {:joint_limit, joint}, _fraction} -> {:ok, Atom.to_string(joint)}
      {:refused, {:joint_limit, joint}} -> {:ok, Atom.to_string(joint)}
      _no_joint -> {:ok, ""}
    end
  end

  def cartesian_value("axes.cartesian.manipulability", _status) do
    chain = Registry.arm_chain()

    case joint_positions(chain) do
      {:ok, positions} ->
        # Observable whether or not a jog is being held — a viewport shading
        # reachability wants it while the arm is standing still, which is when
        # somebody is deciding where to send it.
        {:ok, IK.manipulability(chain, %JointState{positions: positions})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cartesian_value(_unknown, _status), do: {:error, :unknown_node}

  defp reason_name({:joint_limit, _joint}), do: "joint_limit"
  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp cartesian?(node_id), do: String.starts_with?(node_id, "axes.cartesian.")

  @impl ExProto.Source
  def write(node_id, value, _arg) do
    with {:ok, axis, "target_position"} <- parse(node_id),
         {:ok, target} <- as_float(value),
         {:ok, status} <- status(axis),
         :ok <- accepting?(status),
         {:ok, _mode} <- ensure_position_mode(axis, status) do
      Exdrive.Drive.set_target_position(axis, target)

      # A call is ordered behind the casts already sent, so this observes the
      # drive after the setpoint landed rather than racing it.
      case status(axis) do
        {:ok, applied} -> {:ok, applied.target_position}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, _axis, _other_field} -> {:error, :not_writable}
      :error -> {:error, :unknown_node}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Commands ──────────────────────────────────────────────────────────────

  @impl ExProto.Source
  def call("axes.jog_cartesian", args, arg), do: jog_cartesian(args, arg)
  def call("axes.move_linear", args, arg), do: move_linear(args, arg)
  def call("axes.move_arc", args, arg), do: move_arc(args, arg)

  def call(node_id, args, arg) do
    case parse(node_id) do
      {:ok, axis, command} -> command(axis, command, args, arg)
      :error -> {:error, :unknown_node}
    end
  end

  # Accepted, not completed. Every one of these is a cast into a state machine
  # that decides for itself what to do with it; the outcome is observed on the
  # axis's `state`. Checking the drive is reachable first means an axis whose
  # process is gone reports :rejected rather than silently swallowing the
  # command — a cast to a dead name would look like success.
  defp command(axis, name, args, arg) do
    with {:ok, status} <- status(axis) do
      case name do
        "enable" -> Exdrive.Drive.enable(axis) && :ok
        "disable" -> Exdrive.Drive.control_word(axis, 0x0000) && :ok
        # Quick stop: decelerate on the quick-stop ramp and hold. Not an
        # emergency stop — that is a hardware circuit and does not travel
        # through this protocol.
        "stop" -> Exdrive.Drive.quick_stop(axis) && :ok
        "reset_fault" -> Exdrive.Drive.fault_reset(axis) && :ok
        "home" -> home(axis)
        "jog" -> jog(axis, status, args, arg)
        _ -> {:error, :not_callable}
      end
    end
  end

  # A jog is only ever a velocity setpoint here. The holding, the deadline and
  # the stop when assertions lapse are `ExProto.Jog`'s, above this — a source
  # that started its own timers would be a second watchdog with a different
  # idea of when the operator let go.
  #
  # `operation_enabled` strictly, not `@accepting`. A drive in `switched_on`
  # POSTPONES a velocity cast rather than discarding it, so an axis jogged
  # before it was enabled would sit on the setpoint and take off the instant
  # somebody energised it — with no assertion outstanding by then, and nothing
  # the watchdog could recognise as a hold to stop.
  defp jog(axis, %{state: :operation_enabled} = status, args, arg) do
    with {:ok, velocity} <- as_float(args["velocity"]),
         :ok <- mode_permits(velocity == 0.0, arg),
         {:ok, _mode} <- ensure_velocity_mode(axis, status) do
      Exdrive.Drive.set_target_velocity(axis, clamp_jog(velocity))
      :ok
    end
  end

  defp jog(_axis, _status, _args, _arg), do: {:error, :rejected}

  # An interlock that can refuse a stop is not an interlock.
  #
  # Every assertion that commands zero is permitted in any mode, and it has to
  # be: turning the selector out of manual releases every hold, releasing a hold
  # commands zero, and that zero comes back through this same function. A mode
  # check in front of it would mean the interlock preventing the stop it exists
  # to cause — and the arm carrying on in AUTO because it was told not to move.
  #
  # It also removes a deadlock, which is how this was found. The mode process
  # calls the watchdog, the watchdog re-enters the source, and the source used to
  # ask the mode process a question it could not answer while it was mid-change.
  # Asking whether this is a stop before asking anything of the mode is both the
  # correct rule and the one that does not re-enter.
  defp mode_permits(true = _neutral?, _arg), do: :ok
  defp mode_permits(_not_neutral, arg), do: Mode.allows_jog?(mode_server(arg))

  # Only when it has to change. This runs at the client's assertion rate, and
  # set_mode is a call — a synchronous round trip into the drive's state
  # machine ten times a second to tell it what it already knows.
  defp ensure_velocity_mode(_axis, %{mode: :profile_velocity}), do: {:ok, :profile_velocity}
  defp ensure_velocity_mode(axis, _status), do: set_mode(axis, :profile_velocity)

  # The same for the other direction, and it is not symmetry for its own sake.
  #
  # A drive left in profile_velocity — which is where every jog leaves it —
  # ignores a position setpoint completely. Without this, writing
  # `target_position` after a jog stores the number, reads it back, and reports
  # success to a client whose arm has not moved and is not going to. That is the
  # exact failure this module's docstring describes for the PDS state, arrived at
  # through the mode instead, and it took a live session to notice because
  # everything reported fine.
  defp ensure_position_mode(_axis, %{mode: :profile_position}), do: {:ok, :profile_position}
  defp ensure_position_mode(_axis, %{mode: :homing} = _status), do: {:ok, :homing}
  defp ensure_position_mode(axis, _status), do: set_mode(axis, :profile_position)

  # ── The tool speed limit, keyed to the mode ───────────────────────────────

  # 250 mm/s in manual, per ISO 10218. Auto is a machine running a program with
  # nobody's hands near it, and the number that belongs there is a property of
  # the cell rather than of the standard — this is a placeholder for one that
  # arrives with configuration.
  #
  # Passed down rather than read up: the stream lives in `exmove`, which knows
  # nothing about modes or protocols and should not learn. The layer that knows
  # the mode is the layer that tells it the number.
  @manual_tool_velocity 0.25
  @auto_tool_velocity 1.0

  defp tool_speed_limit(arg) do
    case Mode.selected(mode_server(arg)) do
      :auto -> @auto_tool_velocity
      _manual_or_idle -> @manual_tool_velocity
    end
  end

  # Half the manual limit. A move with no feedrate given is somebody who has not
  # thought about speed, and the answer to that is not "as fast as allowed".
  @default_feedrate 0.125

  # A manual-mode speed limit, and a functional one: the constraint that
  # actually matters is the 250 mm/s ISO 10218 puts on the tool centre point,
  # which needs the whole kinematic chain to evaluate and belongs in a
  # safety-rated function rather than in a source module. This keeps a slipped
  # decimal point in a pendant from becoming a full-speed joint move; it is not
  # what stands between anyone and the arm.
  defp clamp_jog(velocity) do
    velocity |> max(-@max_jog_velocity) |> min(@max_jog_velocity)
  end

  defp home(axis) do
    with {:ok, _} <- set_mode(axis, :homing) do
      Exdrive.Drive.enable(axis)
      :ok
    end
  end

  defp set_mode(axis, mode) do
    {:ok, Exdrive.Drive.set_mode(axis, mode)}
  catch
    :exit, _reason -> {:error, :rejected}
  end

  # ── Cartesian jog ─────────────────────────────────────────────────────────

  # An assertion, not a solve.
  #
  # This used to compute six joint velocities per assertion and write them to the
  # drives, which made the client's ~10 Hz assertion rate the interpolation rate
  # of the arm. Those are unrelated numbers: one is a fact about the network and
  # the other is a fact about the machine. At the 250 mm/s ISO 10218 allows in
  # manual mode, interpolating at 10 Hz leaves the commanded line by more than a
  # centimetre.
  #
  # So what an assertion does now is refresh an intent — a frame, a direction and
  # a speed — on `ExMove.CartesianStream`, which re-solves from the arm's live
  # joint positions at its own rate. The watchdog above still guards the hold; it
  # has just stopped doubling as the interpolator.
  #
  # Velocity IK stays the method, and for the same reason as before: it is
  # differential, so the arm cannot flip elbow-up to elbow-down partway through
  # because a different solution scored better. That flip is a collision.
  defp jog_cartesian(args, arg) do
    with {:ok, frame} <- frame(args),
         {:ok, twist} <- twist(args),
         :ok <- mode_permits(stopped?(twist), arg) do
      chain = Registry.arm_chain()

      # Zero is a stop, and it is the value the watchdog asserts when the
      # operator lets go or the link drops. Releasing the stream commands zero on
      # every joint on the way out, which is what makes the button feel attached
      # to the machine. What stops the arm when nothing is sent at all is one
      # layer further down, and is not this.
      if stopped?(twist) do
        CartesianStream.release(chain)
      else
        case CartesianStream.hold(chain, twist,
               frame: frame,
               max_tool_velocity: tool_speed_limit(arg)
             ) do
          :ok -> :ok
          {:error, _reason} -> {:error, :rejected}
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp stopped?(twist), do: Enum.all?(twist, &(&1 == 0.0))

  # ── move_linear ───────────────────────────────────────────────────────────

  # A pose and a feedrate, handed to the same stream the jog uses.
  #
  # Gated on mode like a jog, and for the same reason — this moves the arm, and
  # whether the machine is in a state where it should be moving is not a question
  # the client gets to answer. Not gated on a *neutral* exception, because there
  # is no such thing here: a move has no zero, and the way to stop one is `stop`.
  defp move_linear(args, arg) do
    with :ok <- Mode.allows_jog?(mode_server(arg)),
         {:ok, target} <- target_frame(args),
         {:ok, feedrate} <- feedrate(args) do
      chain = Registry.arm_chain()

      chain
      |> CartesianStream.move_linear(target, motion_opts(args, feedrate, arg))
      |> accepted()
    end
  end

  defp move_arc(args, arg) do
    with :ok <- Mode.allows_jog?(mode_server(arg)),
         {:ok, target} <- target_frame(args),
         {:ok, via} <- via_frame(args),
         {:ok, feedrate} <- feedrate(args) do
      chain = Registry.arm_chain()

      chain
      |> CartesianStream.move_arc(via, target, motion_opts(args, feedrate, arg))
      |> accepted()
    end
  end

  # The via point is a position and nothing else. An orientation there would be
  # a promise about the middle of a move that this build does not keep — the
  # tool is driven toward the *end* orientation, paced to arrive with the
  # position, rather than slerped along the path.
  defp via_frame(args) do
    with {:ok, x} <- as_float(args["via_x"]),
         {:ok, y} <- as_float(args["via_y"]),
         {:ok, z} <- as_float(args["via_z"]) do
      {:ok, %Frame{x: x, y: y, z: z}}
    end
  end

  defp motion_opts(args, feedrate, arg) do
    opts = [feedrate: feedrate, max_tool_velocity: tool_speed_limit(arg)]

    case args["blend"] do
      nil ->
        opts

      value ->
        case as_float(value) do
          {:ok, blend} -> Keyword.put(opts, :blend, blend)
          {:error, _reason} -> opts
        end
    end
  end

  defp accepted(:ok), do: :ok
  defp accepted({:error, _reason}), do: {:error, :rejected}

  # Rotation is optional, and omitting it means "keep the orientation you have"
  # rather than "go to zero". A client asking to move somewhere without saying
  # anything about the wrist has not asked for the wrist to be levelled, and
  # reading silence as a command is how a tool ends up somewhere surprising.
  defp target_frame(args) do
    with {:ok, x} <- as_float(args["x"]),
         {:ok, y} <- as_float(args["y"]),
         {:ok, z} <- as_float(args["z"]) do
      chain = Registry.arm_chain()

      case {args["rx"], args["ry"], args["rz"]} do
        {nil, nil, nil} ->
          case joint_positions(chain) do
            {:ok, positions} ->
              here = FK.solve(chain, %JointState{positions: positions})
              {:ok, %Frame{here | x: x, y: y, z: z}}

            {:error, reason} ->
              {:error, reason}
          end

        {rx, ry, rz} ->
          with {:ok, rx} <- as_float(rx),
               {:ok, ry} <- as_float(ry),
               {:ok, rz} <- as_float(rz) do
            {:ok, %Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}}
          end
      end
    end
  end

  defp feedrate(args) do
    case args["feedrate"] do
      nil -> {:ok, @default_feedrate}
      value -> as_float(value)
    end
  end

  # Refused rather than quietly treated as base, which is the whole reason the
  # argument is worth having. An operator who selects USER on a pendant and gets
  # WORLD motion learns about it from the fixture.
  #
  # `user` is not here yet: user frames are stored on the controller as
  # configuration, and there is nowhere to store them. It is refused by the same
  # clause that refuses a typo, which is honest — this build does not have it.
  defp frame(args) do
    case Map.get(args, "frame") || "base" do
      "base" -> {:ok, :base}
      "tool" -> {:ok, :tool}
      _unknown -> {:error, :rejected}
    end
  end

  # One direction, in the slot the Jacobian expects: [vx, vy, vz, wx, wy, wz].
  defp twist(args) do
    with {:ok, velocity} <- as_float(args["velocity"]) do
      case args["axis"] do
        "x" -> {:ok, [velocity, 0.0, 0.0, 0.0, 0.0, 0.0]}
        "y" -> {:ok, [0.0, velocity, 0.0, 0.0, 0.0, 0.0]}
        "z" -> {:ok, [0.0, 0.0, velocity, 0.0, 0.0, 0.0]}
        "rx" -> {:ok, [0.0, 0.0, 0.0, velocity, 0.0, 0.0]}
        "ry" -> {:ok, [0.0, 0.0, 0.0, 0.0, velocity, 0.0]}
        "rz" -> {:ok, [0.0, 0.0, 0.0, 0.0, 0.0, velocity]}
        _unknown -> {:error, :rejected}
      end
    end
  end

  # ── Projection: drive status → model nodes ────────────────────────────────

  defp project(node_id, status) do
    case parse(node_id) do
      {:ok, _axis, field} -> field_value(field, status)
      :error -> {:error, :unknown_node}
    end
  end

  defp field_value("position", status), do: {:ok, status.actual_position}
  defp field_value("target_position", status), do: {:ok, status.target_position}
  defp field_value("velocity", status), do: {:ok, status.actual_velocity}

  # The neutral state, which every interface reports in the same vocabulary.
  # This binding drives CiA 402 hardware, so the mapping is from the PDS state
  # machine — a step/dir or PWM source maps from whatever it has instead, and
  # a client reading `state` does not have to know which it is talking to.
  defp field_value("state", status), do: {:ok, neutral_state(status)}

  # The raw PDS state, published beside the neutral one rather than instead of
  # it, so nothing is lost for a servo. Converting the atom here: JSON has no
  # atoms, and a projection relying on the encoder to guess is one refactor
  # away from emitting something a client cannot parse.
  defp field_value("pds_state", status), do: {:ok, Atom.to_string(status.state)}
  defp field_value("status_word", status), do: {:ok, status.status_word}

  # The model says uint16, "0 when healthy". The drive says nil when healthy.
  # The model wins — it is the published contract.
  defp field_value("fault_code", %{fault_code: nil}), do: {:ok, 0}
  defp field_value("fault_code", status), do: {:ok, status.fault_code}

  # Derived, which is why it is read-only in the model.
  defp field_value("direction", status) do
    cond do
      status.actual_velocity > 1.0e-6 -> {:ok, "ccw"}
      status.actual_velocity < -1.0e-6 -> {:ok, "cw"}
      true -> {:ok, "stopped"}
    end
  end

  defp field_value(_unknown, _status), do: {:error, :unknown_node}

  # CiA 402 PDS → the vocabulary in ExMo.Schema.FromAxis.states/0.
  #
  # `switched_on` is energised but not accepting motion, which is exactly what
  # `ready` means; `operation_enabled` splits into `enabled` and `moving` on
  # whether the axis is actually turning, because an operator watching a live
  # machine needs to see the difference and the PDS state machine does not
  # distinguish them.
  defp neutral_state(%{state: state} = status) do
    case state do
      :fault -> "fault"
      :fault_reaction_active -> "fault"
      :quick_stop_active -> "stopping"
      :switched_on -> "ready"
      :ready_to_switch_on -> "ready"
      :operation_enabled -> operating_state(status)
      _not_energised -> "disabled"
    end
  end

  # Homing is a *mode* in CiA 402, not a PDS state — a homing drive sits in
  # operation_enabled like any other — so it is read from the mode and takes
  # precedence over moving, which it also is.
  defp operating_state(%{mode: :homing, homing_complete: false}), do: "homing"
  defp operating_state(status), do: if(moving?(status), do: "moving", else: "enabled")

  defp moving?(%{actual_velocity: velocity}), do: abs(velocity) > 1.0e-6

  # ── Talking to the drive ──────────────────────────────────────────────────

  defp status(axis) do
    {:ok, Exdrive.Drive.status(axis)}
  catch
    :exit, {:noproc, _} ->
      # The model declares an axis no drive is running for. That is a wiring
      # error rather than a client error, so it is logged here as well as
      # reported — a client seeing :rejected should not be the only trace.
      Logger.warning("ExProto.Source.Exdrive: no drive running for axis #{inspect(axis)}")
      {:error, :rejected}

    :exit, reason ->
      Logger.warning("ExProto.Source.Exdrive: axis #{inspect(axis)} failed: #{inspect(reason)}")
      {:error, :rejected}
  end

  defp accepting?(%{state: state}) when state in @accepting, do: :ok
  defp accepting?(_status), do: {:error, :rejected}

  # ── Node ids ──────────────────────────────────────────────────────────────

  # "axes.j1.position" -> {:ok, "j1", "position"}
  defp parse(node_id) do
    case String.split(node_id, ".") do
      # The tool is not an axis, and "tcp" in the axis position would otherwise
      # be read as one — asking a drive called tcp for its status.
      ["axes", "tcp", _component] -> :error
      ["axes", axis, field] -> {:ok, axis, field}
      _ -> :error
    end
  end

  defp axis_of(node_id) do
    case parse(node_id) do
      {:ok, axis, _field} -> axis
      :error -> nil
    end
  end

  defp as_float(value) when is_float(value), do: {:ok, value}
  defp as_float(value) when is_integer(value), do: {:ok, value * 1.0}
  defp as_float(_value), do: {:error, :rejected}
end
