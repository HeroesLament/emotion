defmodule Exdrive.Drive do
  @moduledoc """
  CiA 402 compliant simulated drive, implemented as a :gen_statem.

  State machine (CiA 402 PDS FSA):

      not_ready_to_switch_on  (auto-transitions after init)
               ↓
      switch_on_disabled  ←─────────────────────┐
               ↓  cw=0x0006 (shutdown)           │
      ready_to_switch_on                         │ cw=0x0080 (fault reset)
               ↓  cw=0x0007 (switch on)          │
      switched_on                                │
               ↓  cw=0x000F (enable operation)   │
      operation_enabled ────────→ fault ─────────┘
               ↓  cw=0x0002 (quick stop)
      quick_stop_active → switch_on_disabled

  Control words are matched RAW per state — the same bit pattern means
  different things in different states. Never decode globally.

  Modes of operation (object 0x6060):
    :profile_position      (1)  — move to target position with ramp
    :profile_velocity      (3)  — run at target velocity with ramp
    :profile_torque        (4)  — apply target torque
    :homing                (6)  — seek home position
    :interpolated_position (7)  — follow pre-computed position table
    :cyclic_sync_position  (8)  — cyclic setpoint from master (hard RT)
    :cyclic_sync_velocity  (9)  — cyclic velocity setpoint from master
    :cyclic_sync_torque    (10) — cyclic torque setpoint from master

  ## Units

  SI throughout, and there is no unit field anywhere: positions are **radians**,
  velocities **rad/s**, accelerations **rad/s²**, torques **N·m**, inertia
  **kg·m²**, and time **seconds**. Conversion to degrees is a presentation
  concern and belongs in whatever is displaying the number, not here.

  Encoder counts and gear ratios live below this module, in whichever transport
  talks to real hardware. Nothing above the drive ever sees a count.

  ## Who advances the simulation

  `dt` is an argument, not an assumption. A drive is advanced either by its own
  timer (`clock: :internal`, the default, so IEx works with no ceremony) or by
  whoever calls `tick/2` (`clock: :external`).

  That distinction is why motion tests can run at CPU speed rather than in real
  time, why a simulated cell can be stepped frame by frame, and why the same
  drive can later be paced by a metronome's buffer-fill feedback instead of by
  a `state_timeout`. A simulator whose clock is the wall clock cannot be
  stepped, cannot be run fast, and makes every timing test flaky.
  """

  @behaviour :gen_statem
  @behaviour EMotion.Drive

  alias Exdrive.Cia402

  # Default step for the internal clock: 1 kHz, expressed in seconds
  # because every other time quantity in this module is.
  @tick_period 0.001

  # Bump this any time defstruct changes. code_change/4 uses it to select
  # the correct migration path. Format: "MAJOR.MINOR.PATCH"
  @vsn "0.3.0"
  def vsn, do: @vsn

  defstruct [
    axis_id:            nil,
    mode:               :profile_position,
    # position/velocity/torque state
    actual_position:    0.0,
    actual_velocity:    0.0,
    actual_torque:      0.0,
    target_position:    0.0,
    target_velocity:    0.0,
    target_torque:      0.0,
    # profile parameters — SI
    profile_velocity:   2.0,      # rad/s   — object 0x6081
    profile_accel:      10.0,     # rad/s²  — object 0x6083
    profile_decel:      10.0,     # rad/s²  — object 0x6084
    quick_stop_decel:   100.0,    # rad/s²  — object 0x6085, intentionally >> profile_decel
    # mastering — where joint zero is, and whether we still know where we are.
    # The drive owns the offset because on real hardware the encoder is on the
    # driver board: the offset is a property of THIS board bolted to THIS
    # motor, and a board swap legitimately invalidates it. See
    # servo4257-rs/docs/MASTERING.md for why it is not pushed from here.
    #
    # Note the unit. Everything in this module is SI, so the offset is
    # radians, not encoder counts — the counts/radians conversion belongs to
    # the CANopen adapter that talks to a real drive, not to the model of one.
    master_offset:      nil,      # rad; nil means no joint zero was declared
    mastering:          :unmastered,  # :unmastered | :unreferenced | :referenced
    mastering_drift:    nil,      # rad the axis appears to have moved while off
    # A quantisation allowance, NOT a movement allowance. It has to clear
    # sim_noise and nothing else; anything a human would call "it moved" must
    # trip it. ~0.057 degrees.
    mastering_tolerance: 1.0e-3,  # rad
    # homing
    homing_method:      1,
    homing_complete:    false,
    homing_velocity:    0.5,      # rad/s   — object 0x6099
    homing_tolerance:   0.005,    # rad     — ~0.3°, when to call it home
    # fault
    fault_code:         nil,
    # clock — see the moduledoc. :internal self-schedules, :external waits
    # for tick/2.
    clock:              :internal,
    tick_period:        @tick_period,  # seconds, internal clock only
    # sim parameters
    sim_inertia:        1.0,      # kg·m²
    sim_noise:          0.0,      # rad, uniform, peak-to-peak
    sim_fault_rate:     0.0,      # probability per tick
    # Proportional gain of the kinematic position follower, 1/s. Not a real
    # servo loop — the plant here is kinematic, not dynamic. It gets a name so
    # the number is arguable rather than magic.
    sim_position_gain:  10.0,
    # Torque reported per unit velocity, N·m·s/rad. A placeholder standing in
    # for real dynamics; replaced when the transmission model lands.
    sim_torque_gain:    0.1,
    # subscribers
    subscribers:        [],
  ]

  # --- Child spec -----------------------------------------------------------

  def child_spec(opts) do
    axis_id = Keyword.fetch!(opts, :axis_id)
    %{
      id: {__MODULE__, axis_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500,
    }
  end

  # --- Public API -----------------------------------------------------------

  def start_link(opts) do
    axis_id = Keyword.fetch!(opts, :axis_id)
    :gen_statem.start_link({:local, axis_name(axis_id)}, __MODULE__, opts, [])
  end

  @doc "Send a raw CiA 402 control word (async)"
  @impl EMotion.Drive
  def control_word(axis_id, cw) when is_integer(cw) do
    :gen_statem.cast(axis_name(axis_id), {:control_word, cw})
  end

  @doc """
  Give this axis an offset that came off a board being replaced.

  Refused unless the axis is unmastered. A board that already knows its zero is
  precisely the case where writing one is the stale-push failure, so the
  refusal is the interlock rather than a note in a manual.
  """
  @impl EMotion.Drive
  def restore_master_offset(axis_id, offset) when is_number(offset) do
    :gen_statem.call(axis_name(axis_id), {:restore_master_offset, offset * 1.0})
  end

  @doc """
  Advance the simulation by `dt` seconds.

  Only meaningful for a drive started with `clock: :external`; an internally
  clocked drive is already advancing and an extra tick simply adds to its
  motion. Asynchronous, so a caller stepping many axes does not serialise on
  each one — follow with `status/1` when you need to observe the result, since
  a call is ordered behind the casts before it.
  """
  def tick(axis_id, dt) when is_number(dt) and dt > 0 do
    :gen_statem.cast(axis_name(axis_id), {:tick, dt * 1.0})
  end

  @doc """
  Walk the drive to operation_enabled in one call.

  No sleeps between the control words. `not_ready_to_switch_on` postpones every
  event until it has initialised, and gen_statem replays postponed events on
  each state change, so the three transitions resolve in order on their own.
  """
  @impl EMotion.Drive
  def enable(axis_id) do
    control_word(axis_id, 0x0006)   # → ready_to_switch_on
    control_word(axis_id, 0x0007)   # → switched_on
    control_word(axis_id, 0x000F)   # → operation_enabled
  end

  @doc "Quick stop — decelerates to zero then disables"
  @impl EMotion.Drive
  def quick_stop(axis_id),  do: control_word(axis_id, 0x0002)

  @doc "Reset a faulted drive"
  @impl EMotion.Drive
  def fault_reset(axis_id), do: control_word(axis_id, 0x0080)

  @doc "Set mode of operation (object 0x6060)"
  @impl EMotion.Drive
  def set_mode(axis_id, mode) when is_atom(mode) do
    :gen_statem.call(axis_name(axis_id), {:set_mode, mode})
  end

  @doc "Set target position — profile position and CSP modes"
  @impl EMotion.Drive
  def set_target_position(axis_id, pos) do
    :gen_statem.cast(axis_name(axis_id), {:set_target_position, pos})
  end

  @doc "Set target velocity — profile velocity and CSV modes"
  @impl EMotion.Drive
  def set_target_velocity(axis_id, vel) do
    :gen_statem.cast(axis_name(axis_id), {:set_target_velocity, vel})
  end

  @doc "Set target torque — profile torque and CST modes"
  @impl EMotion.Drive
  def set_target_torque(axis_id, torque) do
    :gen_statem.cast(axis_name(axis_id), {:set_target_torque, torque})
  end

  @doc "Get current drive status (synchronous)"
  @impl EMotion.Drive
  def status(axis_id) do
    :gen_statem.call(axis_name(axis_id), :status)
  end

  @doc "Subscribe this process to position/state update messages"
  def subscribe(axis_id) do
    :gen_statem.call(axis_name(axis_id), {:subscribe, self()})
  end

  # --- gen_statem callbacks -------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init(opts) do
    data = %__MODULE__{
      axis_id:        Keyword.fetch!(opts, :axis_id),
      clock:          Keyword.get(opts, :clock, :internal),
      tick_period:    Keyword.get(opts, :tick_period, @tick_period),
      sim_inertia:    Keyword.get(opts, :sim_inertia, 1.0),
      sim_noise:      Keyword.get(opts, :sim_noise, 0.0),
      sim_fault_rate: Keyword.get(opts, :sim_fault_rate, 0.0),
    }

    # A simulated arm has no witness mark to drive to, so a blank page here
    # would mean every dev session started by mastering six axes by hand. This
    # is the SIMULATOR'S factory step, and it is deliberately an option rather
    # than a hardcoded convenience: a real drive ships unmastered because
    # nobody has bolted it into a joint yet, and the CANopen adapter that talks
    # to one must never pass this.
    #
    # It only fires on a blank page. Once an axis has a record, this cannot
    # touch it — so backdriving, erasing and re-mastering all still behave, and
    # the interlock still means something.
    master_on_first_boot? = Keyword.get(opts, :master_on_first_boot, true)

    unless data.clock in [:internal, :external] do
      raise ArgumentError, ":clock must be :internal or :external, got #{inspect(data.clock)}"
    end

    data = resolve_mastering(data)

    data =
      if master_on_first_boot? and data.mastering == :unmastered and
           is_nil(Exdrive.Flash.record(data.axis_id)) do
        do_master(data, 0.0)
      else
        data
      end

    {:ok, :not_ready_to_switch_on, data}
  end

  # Coming up is a boot, and a boot is a question: does this axis still know
  # where it is? Ask the flash and the rotor, not the caller.
  defp resolve_mastering(data) do
    {state, position, offset, drift} =
      Exdrive.Flash.resolve(
        Exdrive.Flash.record(data.axis_id),
        Exdrive.Flash.rotor(data.axis_id),
        data.mastering_tolerance
      )

    %{
      data
      | mastering: state,
        master_offset: offset,
        mastering_drift: drift,
        actual_position: position,
        target_position: position
    }
  end

  @doc """
  Declare that this axis is right now at `joint_zero_is` radians.

  Refused while the output stage is on, and that is not fussiness. On real
  hardware a flash write stalls instruction fetch, so committing with the coils
  energised stalls the current loop — and separately, mastering a moving axis
  records a position that was already stale when it was written. The firmware
  answers SDO abort 0x08000022 here; this answers `{:error, :output_enabled}`.
  """
  @impl EMotion.Drive
  def master(axis_id, joint_zero_is \\ 0.0) when is_number(joint_zero_is) do
    :gen_statem.call(axis_name(axis_id), {:master, joint_zero_is})
  end

  @doc """
  Write the MASTER record — the power-down save.

  Called from `terminate/2`, which runs on a graceful stop and does NOT run on
  a kill. That asymmetry is deliberate and load-bearing: it is the difference
  between a clean power-down and yanking the plug, and it is the only way a
  test can produce an axis that comes back not knowing where it is.
  """
  def save(axis_id), do: :gen_statem.call(axis_name(axis_id), :save)

  # --- State: not_ready_to_switch_on ----------------------------------------

  def not_ready_to_switch_on(:enter, _old, data) do
    broadcast(data, {:drive_state, data.axis_id, :not_ready_to_switch_on})
    {:keep_state, data, [{:state_timeout, init_delay(data), :init_done}]}
  end

  def not_ready_to_switch_on(:state_timeout, :init_done, data) do
    {:next_state, :switch_on_disabled, data}
  end

  def not_ready_to_switch_on(_type, _event, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  # --- State: switch_on_disabled --------------------------------------------
  # Valid incoming control word: 0x0006 (shutdown → ready_to_switch_on)

  def switch_on_disabled(:enter, _old, data) do
    data = %{data | actual_velocity: 0.0, actual_torque: 0.0}
    broadcast(data, {:drive_state, data.axis_id, :switch_on_disabled})
    :keep_state_and_data
  end

  def switch_on_disabled(:cast, {:control_word, 0x0006}, data) do
    {:next_state, :ready_to_switch_on, data}
  end

  def switch_on_disabled({:call, from}, {:master, at}, data) do
    data = do_master(data, at)
    {:keep_state, data, [{:reply, from, {:ok, data.master_offset}}]}
  end

  def switch_on_disabled({:call, from}, {:restore_master_offset, offset}, data) do
    do_restore(data, offset, from)
  end

  def switch_on_disabled({:call, from}, :save, data) do
    Exdrive.Flash.save(data.axis_id, data.actual_position)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def switch_on_disabled({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, status_map(:switch_on_disabled, data)}]}
  end

  def switch_on_disabled({:call, from}, {:set_mode, mode}, data) do
    {:keep_state, %{data | mode: mode}, [{:reply, from, :ok}]}
  end

  def switch_on_disabled({:call, from}, {:subscribe, pid}, data) do
    {:keep_state, add_subscriber(data, pid), [{:reply, from, :ok}]}
  end

  def switch_on_disabled(_type, _event, _data), do: :keep_state_and_data

  # --- State: ready_to_switch_on --------------------------------------------
  # Valid: 0x0007 (switch on), 0x0000 (disable voltage → switch_on_disabled)

  def ready_to_switch_on(:enter, _old, data) do
    broadcast(data, {:drive_state, data.axis_id, :ready_to_switch_on})
    :keep_state_and_data
  end

  def ready_to_switch_on(:cast, {:control_word, 0x0007}, data) do
    {:next_state, :switched_on, data}
  end

  def ready_to_switch_on(:cast, {:control_word, 0x0000}, data) do
    {:next_state, :switch_on_disabled, data}
  end

  def ready_to_switch_on({:call, from}, {:master, at}, data) do
    data = do_master(data, at)
    {:keep_state, data, [{:reply, from, {:ok, data.master_offset}}]}
  end

  def ready_to_switch_on({:call, from}, {:restore_master_offset, offset}, data) do
    do_restore(data, offset, from)
  end

  def ready_to_switch_on({:call, from}, :save, data) do
    Exdrive.Flash.save(data.axis_id, data.actual_position)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def ready_to_switch_on({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, status_map(:ready_to_switch_on, data)}]}
  end

  def ready_to_switch_on({:call, from}, {:set_mode, mode}, data) do
    {:keep_state, %{data | mode: mode}, [{:reply, from, :ok}]}
  end

  def ready_to_switch_on({:call, from}, {:subscribe, pid}, data) do
    {:keep_state, add_subscriber(data, pid), [{:reply, from, :ok}]}
  end

  def ready_to_switch_on(_type, _event, _data), do: :keep_state_and_data

  # --- State: switched_on ---------------------------------------------------
  # Valid: 0x000F (enable op), 0x0006 (shutdown), 0x0000 (disable voltage)

  def switched_on(:enter, _old, data) do
    broadcast(data, {:drive_state, data.axis_id, :switched_on})
    :keep_state_and_data
  end

  def switched_on(:cast, {:control_word, 0x000F}, data) do
    {:next_state, :operation_enabled, data}
  end

  def switched_on(:cast, {:control_word, 0x0006}, data) do
    {:next_state, :ready_to_switch_on, data}
  end

  def switched_on(:cast, {:control_word, 0x0000}, data) do
    {:next_state, :switch_on_disabled, data}
  end

  # Postpone setpoints — gen_statem replays them when we reach operation_enabled
  def switched_on(:cast, {:set_target_position, _}, _data), do: {:keep_state_and_data, [:postpone]}
  def switched_on(:cast, {:set_target_velocity, _}, _data), do: {:keep_state_and_data, [:postpone]}
  def switched_on(:cast, {:set_target_torque,   _}, _data), do: {:keep_state_and_data, [:postpone]}

  def switched_on({:call, from}, {:master, at}, data) do
    data = do_master(data, at)
    {:keep_state, data, [{:reply, from, {:ok, data.master_offset}}]}
  end

  def switched_on({:call, from}, {:restore_master_offset, offset}, data) do
    do_restore(data, offset, from)
  end

  def switched_on({:call, from}, :save, data) do
    Exdrive.Flash.save(data.axis_id, data.actual_position)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def switched_on({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, status_map(:switched_on, data)}]}
  end

  def switched_on({:call, from}, {:set_mode, mode}, data) do
    {:keep_state, %{data | mode: mode}, [{:reply, from, :ok}]}
  end

  def switched_on({:call, from}, {:subscribe, pid}, data) do
    {:keep_state, add_subscriber(data, pid), [{:reply, from, :ok}]}
  end

  def switched_on(_type, _event, _data), do: :keep_state_and_data

  # --- State: operation_enabled ---------------------------------------------
  # Valid: 0x0007 (disable op), 0x0006 (shutdown), 0x0000 (disable voltage),
  #        0x0002 (quick stop)

  def operation_enabled(:enter, _old, data) do
    broadcast(data, {:drive_state, data.axis_id, :operation_enabled})
    {:keep_state, data, schedule_tick(data)}
  end

  def operation_enabled(:state_timeout, :tick, data) do
    advance_enabled(data, data.tick_period, schedule_tick(data))
  end

  def operation_enabled(:cast, {:tick, dt}, data) do
    advance_enabled(data, dt, [])
  end

  def operation_enabled(:cast, {:control_word, 0x0007}, data) do
    {:next_state, :switched_on, data}
  end

  def operation_enabled(:cast, {:control_word, 0x0006}, data) do
    {:next_state, :ready_to_switch_on, data}
  end

  def operation_enabled(:cast, {:control_word, 0x0000}, data) do
    {:next_state, :switch_on_disabled, data}
  end

  def operation_enabled(:cast, {:control_word, 0x0002}, data) do
    {:next_state, :quick_stop_active, data}
  end

  def operation_enabled(:cast, {:set_target_position, pos}, data) do
    {:keep_state, %{data | target_position: pos}}
  end

  def operation_enabled(:cast, {:set_target_velocity, vel}, data) do
    {:keep_state, %{data | target_velocity: vel}}
  end

  def operation_enabled(:cast, {:set_target_torque, torque}, data) do
    {:keep_state, %{data | target_torque: torque}}
  end

  # Refused with the output stage on. A flash write stalls instruction fetch on
  # real hardware, so committing here stalls the current loop with energised
  # coils — and a moving axis records a position that is stale by the time it
  # lands. The firmware answers SDO abort 0x08000022 to the same request.
  def operation_enabled({:call, from}, {:master, _at}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :output_enabled}}]}
  end

  def operation_enabled({:call, from}, {:restore_master_offset, _offset}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :output_enabled}}]}
  end

  def operation_enabled({:call, from}, :save, data) do
    Exdrive.Flash.save(data.axis_id, data.actual_position)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def operation_enabled({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, status_map(:operation_enabled, data)}]}
  end

  def operation_enabled({:call, from}, {:set_mode, mode}, data) do
    {:keep_state, %{data | mode: mode}, [{:reply, from, :ok}]}
  end

  def operation_enabled({:call, from}, {:subscribe, pid}, data) do
    {:keep_state, add_subscriber(data, pid), [{:reply, from, :ok}]}
  end

  def operation_enabled(_type, _event, _data), do: :keep_state_and_data

  # --- State: quick_stop_active ---------------------------------------------

  def quick_stop_active(:enter, _old, data) do
    broadcast(data, {:drive_state, data.axis_id, :quick_stop_active})
    {:keep_state, data, schedule_tick(data)}
  end

  def quick_stop_active(:cast, {:tick, dt}, data) do
    advance_stopping(data, dt, [])
  end

  def quick_stop_active(:state_timeout, :tick, data) do
    advance_stopping(data, data.tick_period, schedule_tick(data))
  end

  # Refused with the output stage on. A flash write stalls instruction fetch on
  # real hardware, so committing here stalls the current loop with energised
  # coils — and a moving axis records a position that is stale by the time it
  # lands. The firmware answers SDO abort 0x08000022 to the same request.
  def quick_stop_active({:call, from}, {:master, _at}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :output_enabled}}]}
  end

  def quick_stop_active({:call, from}, {:restore_master_offset, _offset}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :output_enabled}}]}
  end

  def quick_stop_active({:call, from}, :save, data) do
    Exdrive.Flash.save(data.axis_id, data.actual_position)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def quick_stop_active({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, status_map(:quick_stop_active, data)}]}
  end

  def quick_stop_active(_type, _event, _data), do: :keep_state_and_data

  # --- State: fault ---------------------------------------------------------
  # Valid: 0x0080 (fault reset → switch_on_disabled)

  def fault(:enter, _old, data) do
    data = %{data | actual_velocity: 0.0, actual_torque: 0.0}
    broadcast(data, {:drive_fault, data.axis_id, data.fault_code})
    :keep_state_and_data
  end

  def fault(:cast, {:control_word, 0x0080}, data) do
    {:next_state, :switch_on_disabled, %{data | fault_code: nil}}
  end

  def fault({:call, from}, {:master, at}, data) do
    data = do_master(data, at)
    {:keep_state, data, [{:reply, from, {:ok, data.master_offset}}]}
  end

  def fault({:call, from}, :save, data) do
    Exdrive.Flash.save(data.axis_id, data.actual_position)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def fault({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, status_map(:fault, data)}]}
  end

  def fault({:call, from}, {:subscribe, pid}, data) do
    {:keep_state, add_subscriber(data, pid), [{:reply, from, :ok}]}
  end

  def fault(_type, _event, _data), do: :keep_state_and_data

  # --- Advancing ------------------------------------------------------------

  # Both clock paths land here, so an externally stepped drive and an
  # internally ticked one run identical physics and emit identical events.
  defp advance_enabled(data, dt, actions) do
    data = sim_tick(data, dt)
    Exdrive.Flash.set_rotor(data.axis_id, data.actual_position)

    broadcast(data, {:position_update, data.axis_id,
                     data.actual_position, data.actual_velocity, data.actual_torque})

    if data.sim_fault_rate > 0 and :rand.uniform() < data.sim_fault_rate do
      {:next_state, :fault, %{data | fault_code: :simulated_fault}}
    else
      {:keep_state, data, actions}
    end
  end

  defp advance_stopping(data, dt, actions) do
    data = sim_decelerate(data, dt)
    Exdrive.Flash.set_rotor(data.axis_id, data.actual_position)
    broadcast(data, {:position_update, data.axis_id,
                     data.actual_position, data.actual_velocity, data.actual_torque})
    # rad/s. Below this the axis is stopped for any purpose that matters.
    if abs(data.actual_velocity) < 0.01 do
      {:next_state, :switch_on_disabled, %{data | actual_velocity: 0.0}}
    else
      {:keep_state, data, actions}
    end
  end

  # Real drives take a moment to come up and callers should not assume
  # otherwise, so the internal clock keeps the delay. An externally clocked
  # drive is being stepped by a test or a scheduler that owns time already, and
  # making it wait 50ms of wall clock would defeat the point.
  defp init_delay(%{clock: :external}), do: 0
  defp init_delay(_data), do: 50

  defp schedule_tick(%{clock: :external}), do: []

  defp schedule_tick(%{tick_period: period}) do
    [{:state_timeout, max(round(period * 1000), 1), :tick}]
  end

  # --- Simulation tick — mode-dependent physics -----------------------------
  #
  # `dt` is in seconds and arrives from the caller. Every clause is a pure
  # function of (data, dt) apart from noise and the homing broadcast.

  defp sim_tick(%{mode: :profile_position} = data, dt) do
    # P-controller driving toward target_position
    error = data.target_position - data.actual_position
    raw_vel = error * (data.sim_position_gain / data.sim_inertia)
    vel = clamp(raw_vel, -data.profile_velocity, data.profile_velocity)
    noise = rand_noise(data.sim_noise)
    %{data | actual_position: data.actual_position + vel * dt + noise,
             actual_velocity: vel,
             actual_torque: vel * data.sim_torque_gain}
  end

  defp sim_tick(%{mode: :profile_velocity} = data, dt) do
    # Ramp toward target_velocity, integrate position
    vel_error = data.target_velocity - data.actual_velocity
    vel_delta = clamp(vel_error, -data.profile_accel * dt, data.profile_accel * dt)
    new_vel = data.actual_velocity + vel_delta
    noise = rand_noise(data.sim_noise)
    %{data | actual_velocity: new_vel,
             actual_position: data.actual_position + new_vel * dt + noise,
             actual_torque: new_vel * data.sim_torque_gain}
  end

  defp sim_tick(%{mode: :profile_torque} = data, dt) do
    # Torque → acceleration → velocity → position
    accel = data.target_torque / data.sim_inertia
    new_vel = data.actual_velocity + accel * dt
    noise = rand_noise(data.sim_noise)
    %{data | actual_torque: data.target_torque,
             actual_velocity: new_vel,
             actual_position: data.actual_position + new_vel * dt + noise}
  end

  defp sim_tick(%{mode: :homing} = data, dt) do
    # Seek zero at homing_velocity, set homing_complete when arrived
    if data.homing_complete do
      data
    else
      dir = if data.actual_position > 0, do: -1.0, else: 1.0
      vel = dir * data.homing_velocity
      new_pos = data.actual_position + vel * dt
      complete = abs(new_pos) < data.homing_tolerance
      new_pos = if complete, do: 0.0, else: new_pos
      if complete, do: broadcast(data, {:homing_complete, data.axis_id})
      %{data | actual_position: new_pos, actual_velocity: vel, homing_complete: complete}
    end
  end

  defp sim_tick(%{mode: :interpolated_position} = data, dt) do
    # IP mode: master owns the trajectory, drive snaps directly to setpoint.
    # Velocity via EMA — raw finite difference is spiky because the master
    # push rate is lower than the drive tick. Alpha=0.1 smooths this into a
    # readable cosine shape matching the sine position wave.
    noise   = rand_noise(data.sim_noise)
    raw_vel = (data.target_position - data.actual_position) / dt
    alpha   = 0.1
    vel     = alpha * raw_vel + (1 - alpha) * data.actual_velocity
    %{data | actual_position: data.target_position + noise,
             actual_velocity: vel,
             actual_torque:   abs(vel) * data.sim_torque_gain * 0.5}
  end

  defp sim_tick(%{mode: :cyclic_sync_position} = data, dt) do
    # Master sends position setpoints each cycle — sim treats like PP.
    # On real hardware the cycle comes from a metronome or the fieldbus SYNC;
    # here it comes from dt, which is the same thing said honestly.
    sim_tick(%{data | mode: :profile_position}, dt)
  end

  defp sim_tick(%{mode: :cyclic_sync_velocity} = data, dt) do
    # Master sends velocity setpoints each cycle
    sim_tick(%{data | mode: :profile_velocity}, dt)
  end

  defp sim_tick(%{mode: :cyclic_sync_torque} = data, dt) do
    # Master sends torque setpoints each cycle
    sim_tick(%{data | mode: :profile_torque}, dt)
  end

  defp sim_decelerate(data, dt) do
    step = data.quick_stop_decel * dt
    new_vel =
      cond do
        data.actual_velocity >  step ->  data.actual_velocity - step
        data.actual_velocity < -step ->  data.actual_velocity + step
        true -> 0.0
      end
    %{data | actual_velocity: new_vel,
             actual_torque:   new_vel * data.sim_torque_gain,
             actual_position: data.actual_position + new_vel * dt}
  end

  # --- Private helpers ------------------------------------------------------

  defp axis_name(axis_id), do: :"exdrive_axis_#{axis_id}"

  defp status_map(state, data) do
    %{
      state:            state,
      status_word:      Cia402.encode_status_word(state),
      axis_id:          data.axis_id,
      mode:             data.mode,
      mode_code:        Cia402.encode_mode(data.mode),
      actual_position:  Float.round(data.actual_position, 4),
      actual_velocity:  Float.round(data.actual_velocity, 4),
      actual_torque:    Float.round(data.actual_torque, 4),
      target_position:  data.target_position,
      target_velocity:  data.target_velocity,
      target_torque:    data.target_torque,
      homing_complete:  data.homing_complete,
      # Two different positions, and conflating them is the bug this whole
      # subsystem exists to prevent. `actual_position` is the drive's own
      # accumulator — always a number, never meaningful on its own.
      # `joint_position` is that number related to a declared zero, and it is
      # nil exactly when nobody may act on it.
      mastering:        data.mastering,
      master_offset:    data.master_offset,
      mastering_drift:  data.mastering_drift,
      joint_position:   joint_position(data),
      fault_code:       data.fault_code,
    }
  end

  defp joint_position(%{mastering: :referenced, master_offset: off} = data) when is_number(off) do
    Float.round(data.actual_position - off, 4)
  end

  defp joint_position(_data), do: nil

  # Declaring a zero and persisting it are one act, not two: a master that is
  # not committed is a number that disappears at the next power cut, and the
  # operator who set it has already walked away.
  # Only onto an axis that does not already know its zero. See
  # `EMotion.Drive.restore_master_offset/2` for why that is the whole interlock.
  defp do_restore(%{mastering: :unmastered} = data, offset, from) do
    Exdrive.Flash.restore(data.axis_id, offset)
    data = resolve_mastering(data)
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  defp do_restore(_data, _offset, from) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_mastered}}]}
  end

  defp do_master(data, joint_zero_is) do
    Exdrive.Flash.master(data.axis_id, data.actual_position, joint_zero_is)
    resolve_mastering(data)
  end

  # The power-down save. Runs on a graceful stop; does not run on a kill.
  # That is the model of a bulk-capacitor save versus yanking the plug, and it
  # is what lets a test produce an axis that comes back not knowing where it is.
  #
  # Deliberately NOT paired with `trap_exit`. Trapping would make terminate run
  # on a parent's exit too, which would mean every abrupt death saved cleanly —
  # and then no test could ever produce an axis that comes back not knowing
  # where it is, which is the failure this whole subsystem exists to handle.
  # It also changes what a linked caller exiting normally does to the drive,
  # which the existing suite relies on.
  @impl :gen_statem
  def terminate(_reason, _state, data) do
    Exdrive.Flash.save(data.axis_id, data.actual_position)
    :ok
  end

  defp add_subscriber(data, pid) do
    %{data | subscribers: Enum.uniq([pid | data.subscribers])}
  end

  defp broadcast(%{subscribers: []}, _msg), do: :ok
  defp broadcast(%{subscribers: subs}, msg) do
    Enum.each(subs, &send(&1, msg))
  end

  defp clamp(val, min, _max) when val < min, do: min
  defp clamp(val, _min, max) when val > max, do: max
  defp clamp(val, _min, _max), do: val

  defp rand_noise(n) when n == 0.0, do: 0.0
  defp rand_noise(n), do: (:rand.uniform() - 0.5) * n

  # --- Hot code upgrade -----------------------------------------------------
  #
  # Called by the release_handler when upgrading a RUNNING Drive process.
  # The process is suspended, the module swapped, then this is called with
  # the old state data. Return {:ok, state, new_data} to resume.
  #
  # Strategy: treat old_data as a plain map (Map.get with defaults) so we
  # never need the old struct definition loaded at upgrade time.
  #
  # Discipline: any time defstruct changes, add a clause here and bump @vsn.
  # Think of each clause as a database migration for live process state.

  @impl :gen_statem
  def code_change(old_vsn, state, old_data, _extra) do
    new_data = migrate(old_vsn, old_data)
    {:ok, state, new_data}
  end

  # Current migration — reconstructs the current struct from whatever map
  # shape the old process was carrying. All fields have safe defaults so
  # new fields added in future versions get their default value when
  # upgrading from a version that didn't have them.
  #
  # When you add a field to defstruct:
  #   1. Bump @vsn
  #   2. Add a specific migrate("old_vsn", old) clause above this one
  #   3. Add the new field to this catch-all with its default
  #
  # Example next migration (when you add :following_error_window):
  #
  #   defp migrate("0.2.0", old) do
  #     migrate(:current, Map.put(old, :following_error_window, 100.0))
  #   end

  # 0.1.0 → 0.2.0: added quick_stop_decel
  defp migrate("0.1.0", old) do
    migrate(:current, Map.put_new(old, :quick_stop_decel, 100.0))
  end

  # 0.2.0 → 0.3.0: units became SI, and the clock became configurable.
  #
  # The numeric fields cannot be migrated honestly. A 0.2.0 process was
  # carrying values in whatever unit its caller assumed — the profile defaults
  # read as degrees, but nothing enforced it — so there is no conversion factor
  # that is right for every process. Positions and profile parameters are
  # therefore reset to SI defaults rather than reinterpreted, and an upgraded
  # axis must be re-homed and re-parameterised. Silently multiplying by pi/180
  # would be a guess wearing the costume of a migration.
  defp migrate("0.2.0", old) do
    reset = [
      :actual_position, :actual_velocity, :actual_torque,
      :target_position, :target_velocity, :target_torque,
      :profile_velocity, :profile_accel, :profile_decel, :quick_stop_decel
    ]

    migrate(:current, Map.drop(old, reset) |> Map.put(:homing_complete, false))
  end

  defp migrate(_vsn, old) do
    %__MODULE__{
      axis_id:          Map.get(old, :axis_id),
      mode:             Map.get(old, :mode,             :profile_position),
      actual_position:  Map.get(old, :actual_position,  0.0),
      actual_velocity:  Map.get(old, :actual_velocity,  0.0),
      actual_torque:    Map.get(old, :actual_torque,    0.0),
      target_position:  Map.get(old, :target_position,  0.0),
      target_velocity:  Map.get(old, :target_velocity,  0.0),
      target_torque:    Map.get(old, :target_torque,    0.0),
      profile_velocity: Map.get(old, :profile_velocity, 2.0),
      profile_accel:    Map.get(old, :profile_accel,    10.0),
      profile_decel:    Map.get(old, :profile_decel,    10.0),
      quick_stop_decel: Map.get(old, :quick_stop_decel, 100.0),
      homing_method:    Map.get(old, :homing_method,    1),
      homing_complete:  Map.get(old, :homing_complete,  false),
      homing_velocity:  Map.get(old, :homing_velocity,  0.5),
      homing_tolerance: Map.get(old, :homing_tolerance, 0.005),
      clock:            Map.get(old, :clock,            :internal),
      tick_period:      Map.get(old, :tick_period,      @tick_period),
      fault_code:       Map.get(old, :fault_code),
      sim_inertia:      Map.get(old, :sim_inertia,      1.0),
      sim_noise:        Map.get(old, :sim_noise,         0.0),
      sim_fault_rate:   Map.get(old, :sim_fault_rate,   0.0),
      sim_position_gain: Map.get(old, :sim_position_gain, 10.0),
      sim_torque_gain:  Map.get(old, :sim_torque_gain,  0.1),
      subscribers:      Map.get(old, :subscribers,      []),
    }
  end
end
