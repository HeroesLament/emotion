defmodule EMotion.Drive do
  @moduledoc """
  The contract every axis implements — simulated, CANopen, EtherCAT, PWM.

  `protocol/DESIGN.md` has always said the layer boundary is here: everything
  above this module is byte-identical whether the arm is metal or arithmetic.
  What that document did not get right was the *shape* of the contract. It
  proposed three callbacks in object-dictionary terms:

      read(drive, index, sub) / write(drive, index, sub, value) / state(drive)

  That shape fits CANopen natively, fits EtherCAT awkwardly (the dictionary is
  real but reached over CoE), and does not fit a PWM actuator at all. A PWM
  axis has no object dictionary. Satisfying `read(drive, 0x6041, 0)` would mean
  synthesising a status word out of nothing — a lie in the shape of an
  abstraction, and worse than no abstraction because it type-checks.

  So the required contract is the one that was *measured* rather than imagined:
  the nine functions the layers above actually call, taken from the call sites
  in `exmove`, `exproto`, `exhmi` and `exdash`. Drives that do have an object
  dictionary expose it through `EMotion.Drive.ObjectDictionary`, which is a
  separate, optional behaviour. Nothing is lost and nothing has to pretend.

  ## The vocabulary stays CiA 402

  DESIGN.md's real worry was drift: that a robot-shaped abstraction would let
  controller code forget what a drive requires. That worry is answered by
  keeping the *words* rather than the *encoding*. `control_word/2`,
  `quick_stop/1`, `fault_reset/1` and `set_mode/2` are all still here, the
  state names are the PDS FSA state names, and a caller still has to walk the
  state machine. What is gone is only the requirement to spell every operation
  as a numbered object.

  A PWM axis implements `control_word/2` by interpreting the standard patterns
  it can honour and ignoring the rest, and reports the states it can actually
  be in. That is an honest partial implementation. `read(0x6040)` would not be.

  ## Synchrony is part of the contract, not an implementation detail

  Setpoints (`set_target_position/2`, `set_target_velocity/2`,
  `set_target_torque/2`) and `control_word/2` are **asynchronous** and return
  `:ok` without confirming anything. This is not laziness — it is what a
  fieldbus is. An RPDO is a frame on a wire; there is no acknowledgement, and a
  contract that promised one would have to invent it. A caller that needs to
  know the drive moved reads `status/1`.

  `status/1`, `set_mode/2` and `master/2` are **synchronous** and return a
  value.

  ## `status/1` is a read of last-known state, never a bus round trip

  The most important sentence in this module. A CANopen implementation answers
  `status/1` from its most recent TPDO, not by asking the drive. An SDO round
  trip was measured at ~1 ms on the bench; a 500 Hz loop over six axes cannot
  afford one, let alone six.

  So `status/1` is cheap, always succeeds, and may be stale by up to one bus
  cycle. Callers must not treat it as a synchronisation point. Anything that
  needs to know the data is fresh reads the timestamp an implementation is free
  to add, or waits a cycle.

  ## Axis ids

  `ExProto.Controller` derives axis ids from node ids and hands over binaries;
  chains carry atoms. `Exdrive.Flash` normalised this at its own boundary in
  commit `2d52f08`, after the ambiguity caused a live bug that no test could
  see — every test started drives the same way it looked them up, so the two
  spellings never disagreed.

  The contract settles it rather than leaving each implementation to guess:
  **both spellings are accepted at the boundary and normalised immediately**,
  by `normalize_id/1`, before an implementation does anything with the value.
  An implementation that keys a map on a raw axis id has a bug waiting.
  """

  @typedoc """
  An axis identity as callers spell it. Normalise with `normalize_id/1` before
  using it as a key.
  """
  @type axis_id :: atom() | String.t()

  @typedoc "CiA 402 PDS FSA states. A drive is always in exactly one."
  @type state ::
          :not_ready_to_switch_on
          | :switch_on_disabled
          | :ready_to_switch_on
          | :switched_on
          | :operation_enabled
          | :quick_stop_active
          | :fault
          | :fault_reaction_active

  @typedoc "Mode of operation, object 0x6060."
  @type mode ::
          :profile_position
          | :profile_velocity
          | :profile_torque
          | :homing
          | :interpolated_position
          | :cyclic_sync_position
          | :cyclic_sync_velocity
          | :cyclic_sync_torque

  @typedoc """
  What `status/1` returns.

  SI throughout, and there is no unit field: positions are radians, velocities
  rad/s, torques N·m. Encoder counts and gear ratios live *below* this
  contract, inside whichever implementation talks to hardware. Nothing above a
  drive ever sees a count.

  `actual_position` and `joint_position` are two different numbers and
  conflating them is the bug the mastering subsystem exists to prevent.
  `actual_position` is the drive's own accumulator — always a number, never
  meaningful on its own. `joint_position` is that number related to a declared
  zero, and it is `nil` exactly when nobody may act on it.
  """
  @type status :: %{
          required(:state) => state(),
          required(:axis_id) => axis_id(),
          required(:mode) => mode(),
          required(:actual_position) => float(),
          required(:actual_velocity) => float(),
          required(:joint_position) => float() | nil,
          required(:mastering) => :unmastered | :unreferenced | :referenced,
          optional(atom()) => term()
        }

  # --- Required callbacks ---------------------------------------------------

  @doc """
  Last-known state of the axis. Cheap, total, and possibly one cycle stale.
  """
  @callback status(axis_id()) :: status()

  @doc "Command a position. Asynchronous — PP, IP and CSP modes."
  @callback set_target_position(axis_id(), float()) :: :ok

  @doc "Command a velocity. Asynchronous — PV and CSV modes."
  @callback set_target_velocity(axis_id(), float()) :: :ok

  @doc """
  Select the mode of operation. Synchronous, because a setpoint sent against
  the wrong mode is not a slow bug, it is a moving one.
  """
  @callback set_mode(axis_id(), mode()) :: :ok | {:error, term()}

  @doc """
  Walk the axis to `:operation_enabled`.

  Convenience over `control_word/2`, and deliberately part of the contract:
  the sequence of control words is identical on every drive, but *how* an
  implementation gets there is not. A PWM axis may have nothing to send.
  """
  @callback enable(axis_id()) :: :ok

  @doc """
  Send a raw CiA 402 control word.

  Raw on purpose. The same bit pattern means different things in different
  states, so it is decoded per state and never globally. An implementation that
  cannot honour a pattern ignores it rather than approximating it.
  """
  @callback control_word(axis_id(), 0..0xFFFF) :: :ok

  @doc "Category 2 stop: decelerate under control, then disable. Asynchronous."
  @callback quick_stop(axis_id()) :: :ok

  @doc "Clear a latched fault. Asynchronous. Does not clear the cause."
  @callback fault_reset(axis_id()) :: :ok

  @doc """
  Declare that the axis is physically at `joint_zero_is` right now.

  Mastering, not homing: it relates the encoder to the joint, which is a fact
  about the hardware, not a motion. The drive owns the zero because the encoder
  is on the drive — the controller asks, shadows and notices, but never applies.

  Refused while output is enabled. An axis that could be moving cannot be
  truthfully said to be anywhere.
  """
  @callback master(axis_id(), float()) :: :ok | {:error, term()}

  # --- Optional ------------------------------------------------------------

  @doc """
  Command a torque. Asynchronous — PT and CST modes.

  Optional because torque control is not universal: a step/direction axis
  cannot do it at all. Callers must check `supports?/2` first.
  """
  @callback set_target_torque(axis_id(), float()) :: :ok

  @optional_callbacks set_target_torque: 2

  # --- Resolution -----------------------------------------------------------

  @doc """
  The implementation module for `axis_id`.

  Per-axis rather than global, because a cell may genuinely mix them: six
  CANopen joints, a PWM gripper, and a simulated external axis that has not
  been built yet. Configured as

      config :exdrive, drives: %{j1: ExDrive.CANopen, gripper: ExDrive.PWM}

  and defaulting to the simulator, which is the right default: a controller
  with no configuration should come up simulated rather than reach for a bus
  that is not there.
  """
  @spec for(axis_id()) :: module()
  def for(axis_id) do
    :exdrive
    |> Application.get_env(:drives, %{})
    |> Map.get(normalize_id(axis_id), default_impl())
  end

  @doc "The module used for any axis without an explicit mapping."
  @spec default_impl() :: module()
  def default_impl do
    Application.get_env(:exdrive, :default_drive, Exdrive.Drive)
  end

  @doc """
  Canonical form of an axis id: an atom.

  Atoms, not binaries, because axis ids are a closed set fixed at
  configuration time — there is no path by which a remote peer can mint a new
  one, which is the only reason `String.to_atom/1` is safe here. Unknown
  binaries still raise rather than grow the atom table: an axis id that names
  no axis is a bug, and it should surface at the boundary rather than three
  layers down as a missing map key.
  """
  @spec normalize_id(axis_id()) :: atom()
  def normalize_id(id) when is_atom(id), do: id
  def normalize_id(id) when is_binary(id), do: String.to_existing_atom(id)

  @doc """
  Whether the drive backing `axis_id` implements an optional callback.

      EMotion.Drive.supports?(:j1, {:set_target_torque, 2})
  """
  @spec supports?(axis_id(), {atom(), arity()}) :: boolean()
  def supports?(axis_id, {fun, arity}) do
    module = __MODULE__.for(axis_id)
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  @doc """
  Whether this drive exposes an object dictionary.

  False for a PWM axis and true for a CANopen one, and callers that tune,
  configure, or tunnel SDOs must branch on it rather than assume.
  """
  @spec object_dictionary?(axis_id()) :: boolean()
  def object_dictionary?(axis_id) do
    axis_id |> __MODULE__.for() |> implements?(EMotion.Drive.ObjectDictionary)
  end

  @doc """
  Whether `module` declares `behaviour`.

  Written out rather than inlined because the obvious version is wrong:

      module.module_info(:attributes)[:behaviour]

  `module_info(:attributes)` is a keyword list, and each `@behaviour` produces
  its own `:behaviour` entry rather than extending one. Keyword access returns
  the *first* match, so the obvious version silently reports `false` for every
  behaviour after the first one a module declares. `Exdrive.Drive` declares
  `:gen_statem` and then `EMotion.Drive`, which is exactly the case that fails.

  `Keyword.get_values/2` collects all of them.
  """
  @spec implements?(module(), module()) :: boolean()
  def implements?(module, behaviour) do
    Code.ensure_loaded?(module) and
      behaviour in (module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten())
  end
end
