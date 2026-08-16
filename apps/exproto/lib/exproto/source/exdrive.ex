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
  alias ExMove.{FK, IK, JointState}

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
  def read_many(node_ids, _arg) do
    {tcp_ids, axis_ids} = Enum.split_with(node_ids, &tcp?/1)

    read_axes(axis_ids) ++ read_tcp(tcp_ids)
  end

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

  @impl ExProto.Source
  def write(node_id, value, _arg) do
    with {:ok, axis, "target_position"} <- parse(node_id),
         {:ok, target} <- as_float(value),
         {:ok, status} <- status(axis),
         :ok <- accepting?(status) do
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
  def call("axes.jog_cartesian", args, _arg), do: jog_cartesian(args)

  def call(node_id, args, _arg) do
    case parse(node_id) do
      {:ok, axis, command} -> command(axis, command, args)
      :error -> {:error, :unknown_node}
    end
  end

  # Accepted, not completed. Every one of these is a cast into a state machine
  # that decides for itself what to do with it; the outcome is observed on the
  # axis's `state`. Checking the drive is reachable first means an axis whose
  # process is gone reports :rejected rather than silently swallowing the
  # command — a cast to a dead name would look like success.
  defp command(axis, name, args) do
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
        "jog" -> jog(axis, status, args)
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
  defp jog(axis, %{state: :operation_enabled} = status, args) do
    with {:ok, velocity} <- as_float(args["velocity"]),
         {:ok, _mode} <- ensure_velocity_mode(axis, status) do
      Exdrive.Drive.set_target_velocity(axis, clamp_jog(velocity))
      :ok
    end
  end

  defp jog(_axis, _status, _args), do: {:error, :rejected}

  # Only when it has to change. This runs at the client's assertion rate, and
  # set_mode is a call — a synchronous round trip into the drive's state
  # machine ten times a second to tell it what it already knows.
  defp ensure_velocity_mode(_axis, %{mode: :profile_velocity}), do: {:ok, :profile_velocity}
  defp ensure_velocity_mode(axis, _status), do: set_mode(axis, :profile_velocity)

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

  # Six joint velocities from one tool velocity, per assertion.
  #
  # Seeded with where the arm is right now and nowhere else. Velocity IK is
  # differential — it answers "how should the joints move from here" — which is
  # exactly the property a jog needs: the arm stays on the configuration it is
  # already in, and cannot flip elbow-up to elbow-down halfway through a move
  # because a different solution scored better. That flip is a collision, and
  # it is the reason a Cartesian jog is not "solve for a pose and go there".
  defp jog_cartesian(args) do
    with {:ok, "base"} <- frame(args),
         {:ok, twist} <- twist(args),
         chain = Registry.arm_chain(),
         {:ok, positions} <- joint_positions(chain),
         :ok <- all_enabled(chain),
         {:ok, %JointState{velocities: dq}} <-
           IK.solve_velocity(chain, %JointState{positions: positions}, twist) do
      apply_joint_velocities(chain, scale(dq))
      :ok
    else
      # Not obeyed, and not silently approximated either. Near a singularity the
      # joint rates that would hold a constant tool speed go to infinity, and
      # the damped solve that avoids dividing by zero produces rates nobody
      # asked for. Refusing puts the operator back on joint jog, which is the
      # only way out of a singularity anyway.
      {:error, :singular} -> {:error, :rejected}
      {:error, reason} -> {:error, reason}
      {:ok, _other_frame} -> {:error, :rejected}
    end
  end

  defp frame(args) do
    case Map.get(args, "frame") || "base" do
      "base" -> {:ok, "base"}
      other -> {:ok, other}
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

  # Every joint scaled by the same factor, not each clamped to the limit.
  #
  # Clamping per joint changes the ratios between them, and the ratios are the
  # direction: an arm whose fastest joint is clipped and whose others are not
  # travels somewhere other than where the operator pointed, slowly and
  # confidently. Scaling the whole vector keeps the tool on the commanded line
  # and just makes it slower, which is what "too fast" should mean.
  defp scale(dq) do
    peak = dq |> Enum.map(&abs/1) |> Enum.max()

    if peak > @max_jog_velocity do
      factor = @max_jog_velocity / peak
      Enum.map(dq, &(&1 * factor))
    else
      dq
    end
  end

  defp all_enabled(chain) do
    Enum.reduce_while(chain.axis_ids, :ok, fn axis_id, :ok ->
      case status(Atom.to_string(axis_id)) do
        {:ok, %{state: :operation_enabled}} -> {:cont, :ok}
        {:ok, _not_enabled} -> {:halt, {:error, :rejected}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_joint_velocities(chain, velocities) do
    chain.axis_ids
    |> Enum.zip(velocities)
    |> Enum.each(fn {axis_id, velocity} ->
      axis = Atom.to_string(axis_id)

      with {:ok, status} <- status(axis),
           {:ok, _mode} <- ensure_velocity_mode(axis, status) do
        Exdrive.Drive.set_target_velocity(axis, velocity)
      end
    end)
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
