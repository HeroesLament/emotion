defmodule EMotion.Axis do
  @moduledoc """
  How everything above the drive layer talks to an axis.

  This is the module the rest of the controller calls. It resolves the axis to
  its configured implementation and delegates, so no layer above `exdrive` ever
  names a concrete drive again.

  Before this existed, `Exdrive.Drive` — the *simulator* — was called directly
  from eleven modules across five apps. There was no behaviour, no adapter and
  no indirection, which meant a CANopen implementation could not be added,
  because there was nowhere to add it. `protocol/MVP-PLAN.md` called that
  Task 0 and it was right to: doing it after a bus exists means doing it twice,
  once against a simulator and once against hardware that is misbehaving for
  unrelated reasons.

  The contract itself is `EMotion.Drive`. This module is only the front door.

  ## Why the dispatch is per-axis and dynamic

  A cell genuinely mixes drive types — six CANopen joints, a PWM gripper, a
  simulated external axis nobody has built yet — so the mapping cannot be
  global. And it is read at call time rather than captured at boot so that a
  drive can be swapped in a running IEx session, which is most of the value of
  running on the BEAM at all.

  The cost is an ETS read per call: `Application.get_env/3` is not a message to
  anybody. Six axes at 500 Hz is 3000 lookups a second, against a budget where
  a single CAN frame is 255 µs. It does not register.

  ## What this module deliberately does not do

  It does not retry, log, translate errors, or hold state. A façade that
  started making decisions would be a second control layer in the worst
  possible place — invisible, in the hot path, and below everything that
  reasons about motion. Every function here resolves and delegates. That is
  all.
  """

  alias EMotion.Drive

  # The eight fixed-arity required callbacks. Generated rather than typed out
  # so that a callback added to the contract and forgotten here is a compile
  # error in exactly one place instead of a silent gap.
  delegated = [
    {:status, 1},
    {:set_target_position, 2},
    {:set_target_velocity, 2},
    {:set_mode, 2},
    {:enable, 1},
    {:control_word, 2},
    {:quick_stop, 1},
    {:fault_reset, 1}
  ]

  for {fun, arity} <- delegated do
    args = Macro.generate_arguments(arity, __MODULE__)
    [axis_id | _] = args

    @doc """
    Delegates `#{fun}/#{arity}` to the drive configured for this axis.

    See `EMotion.Drive` for the contract, including which calls are
    asynchronous and why.
    """
    def unquote(fun)(unquote_splicing(args)) do
      Drive.for(unquote(axis_id)).unquote(fun)(unquote_splicing(args))
    end
  end

  @doc """
  Declare that the axis is physically at `joint_zero_is` right now.

  Separate from the generated delegations because it has a default argument.
  """
  def master(axis_id, joint_zero_is \\ 0.0) do
    Drive.for(axis_id).master(axis_id, joint_zero_is)
  end

  @doc """
  Give this axis an offset that came off a board being replaced.

  Raises for a drive that has no encoder zero to restore, rather than doing
  nothing quietly — the same reasoning as torque below. Silence here would mean
  a maintainer believing a replacement board had been given its number.
  """
  def restore_master_offset(axis_id, offset) do
    if Drive.supports?(axis_id, {:restore_master_offset, 2}) do
      Drive.for(axis_id).restore_master_offset(axis_id, offset)
    else
      raise ArgumentError,
            "axis #{inspect(axis_id)} is backed by #{inspect(Drive.for(axis_id))}, " <>
              "which has no encoder zero to restore"
    end
  end

  @doc """
  Command a torque — PT and CST modes.

  Optional in the contract, so this raises rather than silently doing nothing
  when the axis cannot do it. A gripper that quietly ignores a torque command
  is a gripper that crushes something once and is never suspected.
  """
  def set_target_torque(axis_id, torque) do
    if Drive.supports?(axis_id, {:set_target_torque, 2}) do
      Drive.for(axis_id).set_target_torque(axis_id, torque)
    else
      raise ArgumentError,
            "axis #{inspect(axis_id)} is backed by #{inspect(Drive.for(axis_id))}, " <>
              "which does not implement torque control"
    end
  end
end
