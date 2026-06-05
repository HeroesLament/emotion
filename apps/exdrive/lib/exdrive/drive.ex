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
  """

  @behaviour :gen_statem

  alias Exdrive.Cia402

  @tick_ms 1  # 1kHz servo tick

  # Bump this any time defstruct changes. code_change/4 uses it to select
  # the correct migration path. Format: "MAJOR.MINOR.PATCH"
  @vsn "0.2.0"
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
    # profile parameters
    profile_velocity:   500.0,    # units/s
    profile_accel:      1000.0,   # units/s²
    profile_decel:      1000.0,   # units/s²
    quick_stop_decel:   10_000.0, # units/s² — object 0x6085, intentionally >> profile_decel
    # homing
    homing_method:      1,
    homing_complete:    false,
    # fault
    fault_code:         nil,
    # sim parameters
    sim_inertia:        1.0,
    sim_noise:          0.0,
    sim_fault_rate:     0.0,
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
  def control_word(axis_id, cw) when is_integer(cw) do
    :gen_statem.cast(axis_name(axis_id), {:control_word, cw})
  end

  @doc "Walk the drive to operation_enabled in one call"
  def enable(axis_id) do
    control_word(axis_id, 0x0006)   # → ready_to_switch_on
    Process.sleep(10)
    control_word(axis_id, 0x0007)   # → switched_on
    Process.sleep(10)
    control_word(axis_id, 0x000F)   # → operation_enabled
  end

  @doc "Quick stop — decelerates to zero then disables"
  def quick_stop(axis_id),  do: control_word(axis_id, 0x0002)

  @doc "Reset a faulted drive"
  def fault_reset(axis_id), do: control_word(axis_id, 0x0080)

  @doc "Set mode of operation (object 0x6060)"
  def set_mode(axis_id, mode) when is_atom(mode) do
    :gen_statem.call(axis_name(axis_id), {:set_mode, mode})
  end

  @doc "Set target position — profile position and CSP modes"
  def set_target_position(axis_id, pos) do
    :gen_statem.cast(axis_name(axis_id), {:set_target_position, pos})
  end

  @doc "Set target velocity — profile velocity and CSV modes"
  def set_target_velocity(axis_id, vel) do
    :gen_statem.cast(axis_name(axis_id), {:set_target_velocity, vel})
  end

  @doc "Set target torque — profile torque and CST modes"
  def set_target_torque(axis_id, torque) do
    :gen_statem.cast(axis_name(axis_id), {:set_target_torque, torque})
  end

  @doc "Get current drive status (synchronous)"
  def status(axis_id) do
    :gen_statem.call(axis_name(axis_id), :status)
  end

  @doc "Subscribe this process to position/state update messages"
  def subscribe(axis_id) do
    :gen_statem.call(axis_name(axis_id), {:subscribe, self()})
  end

  # --- gen_statem callbacks -------------------------------------------------

  def callback_mode, do: [:state_functions, :state_enter]

  def init(opts) do
    data = %__MODULE__{
      axis_id:        Keyword.fetch!(opts, :axis_id),
      sim_inertia:    Keyword.get(opts, :sim_inertia, 1.0),
      sim_noise:      Keyword.get(opts, :sim_noise, 0.0),
      sim_fault_rate: Keyword.get(opts, :sim_fault_rate, 0.0),
    }
    {:ok, :not_ready_to_switch_on, data}
  end

  # --- State: not_ready_to_switch_on ----------------------------------------

  def not_ready_to_switch_on(:enter, _old, data) do
    broadcast(data, {:drive_state, data.axis_id, :not_ready_to_switch_on})
    {:keep_state, data, [{:state_timeout, 50, :init_done}]}
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
    {:keep_state, data, [{:state_timeout, @tick_ms, :tick}]}
  end

  def operation_enabled(:state_timeout, :tick, data) do
    data = sim_tick(data)
    broadcast(data, {:position_update, data.axis_id,
                     data.actual_position, data.actual_velocity, data.actual_torque})

    if data.sim_fault_rate > 0 and :rand.uniform() < data.sim_fault_rate do
      {:next_state, :fault, %{data | fault_code: :simulated_fault}}
    else
      {:keep_state, data, [{:state_timeout, @tick_ms, :tick}]}
    end
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
    {:keep_state, data, [{:state_timeout, @tick_ms, :tick}]}
  end

  def quick_stop_active(:state_timeout, :tick, data) do
    data = sim_decelerate(data)
    broadcast(data, {:position_update, data.axis_id,
                     data.actual_position, data.actual_velocity, data.actual_torque})
    if abs(data.actual_velocity) < 0.01 do
      {:next_state, :switch_on_disabled, %{data | actual_velocity: 0.0}}
    else
      {:keep_state, data, [{:state_timeout, @tick_ms, :tick}]}
    end
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

  def fault({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, status_map(:fault, data)}]}
  end

  def fault({:call, from}, {:subscribe, pid}, data) do
    {:keep_state, add_subscriber(data, pid), [{:reply, from, :ok}]}
  end

  def fault(_type, _event, _data), do: :keep_state_and_data

  # --- Simulation tick — mode-dependent physics -----------------------------

  defp sim_tick(%{mode: :profile_position} = data) do
    # P-controller driving toward target_position
    dt = @tick_ms / 1000.0
    error = data.target_position - data.actual_position
    raw_vel = error * (10.0 / data.sim_inertia)
    vel = clamp(raw_vel, -data.profile_velocity, data.profile_velocity)
    noise = rand_noise(data.sim_noise)
    %{data | actual_position: data.actual_position + vel * dt + noise,
             actual_velocity: vel,
             actual_torque: vel * 0.1}
  end

  defp sim_tick(%{mode: :profile_velocity} = data) do
    # Ramp toward target_velocity, integrate position
    dt = @tick_ms / 1000.0
    vel_error = data.target_velocity - data.actual_velocity
    vel_delta = clamp(vel_error, -data.profile_accel * dt, data.profile_accel * dt)
    new_vel = data.actual_velocity + vel_delta
    noise = rand_noise(data.sim_noise)
    %{data | actual_velocity: new_vel,
             actual_position: data.actual_position + new_vel * dt + noise,
             actual_torque: new_vel * 0.1}
  end

  defp sim_tick(%{mode: :profile_torque} = data) do
    # Torque → acceleration → velocity → position
    dt = @tick_ms / 1000.0
    accel = data.target_torque / data.sim_inertia
    new_vel = data.actual_velocity + accel * dt
    noise = rand_noise(data.sim_noise)
    %{data | actual_torque: data.target_torque,
             actual_velocity: new_vel,
             actual_position: data.actual_position + new_vel * dt + noise}
  end

  defp sim_tick(%{mode: :homing} = data) do
    # Seek zero at homing_speed, set homing_complete when arrived
    dt = @tick_ms / 1000.0
    if data.homing_complete do
      data
    else
      dir = if data.actual_position > 0, do: -1.0, else: 1.0
      vel = dir * 50.0
      new_pos = data.actual_position + vel * dt
      complete = abs(new_pos) < 0.5
      new_pos = if complete, do: 0.0, else: new_pos
      if complete, do: broadcast(data, {:homing_complete, data.axis_id})
      %{data | actual_position: new_pos, actual_velocity: vel, homing_complete: complete}
    end
  end

  defp sim_tick(%{mode: :interpolated_position} = data) do
    # IP mode: master owns the trajectory, drive snaps directly to setpoint.
    # Velocity via EMA — raw finite difference is spiky because the master
    # push rate is lower than the 1kHz drive tick. Alpha=0.1 smooths this
    # into a readable cosine shape matching the sine position wave.
    dt      = @tick_ms / 1000.0
    noise   = rand_noise(data.sim_noise)
    raw_vel = (data.target_position - data.actual_position) / dt
    alpha   = 0.1
    vel     = alpha * raw_vel + (1 - alpha) * data.actual_velocity
    %{data | actual_position: data.target_position + noise,
             actual_velocity: vel,
             actual_torque:   abs(vel) * 0.05}
  end

  defp sim_tick(%{mode: :cyclic_sync_position} = data) do
    # Master sends position setpoints each cycle — sim treats like PP
    # In real hardware this is the hard-RT loop driven by EtherCAT SYNC0
    sim_tick(%{data | mode: :profile_position})
  end

  defp sim_tick(%{mode: :cyclic_sync_velocity} = data) do
    # Master sends velocity setpoints each cycle
    sim_tick(%{data | mode: :profile_velocity})
  end

  defp sim_tick(%{mode: :cyclic_sync_torque} = data) do
    # Master sends torque setpoints each cycle
    sim_tick(%{data | mode: :profile_torque})
  end

  defp sim_decelerate(data) do
    dt = @tick_ms / 1000.0
    step = data.quick_stop_decel * dt
    new_vel =
      cond do
        data.actual_velocity >  step ->  data.actual_velocity - step
        data.actual_velocity < -step ->  data.actual_velocity + step
        true -> 0.0
      end
    %{data | actual_velocity: new_vel,
             actual_torque:   new_vel * 0.1,
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
      fault_code:       data.fault_code,
    }
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
    migrate(:current, Map.put_new(old, :quick_stop_decel, 10_000.0))
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
      profile_velocity: Map.get(old, :profile_velocity, 500.0),
      profile_accel:    Map.get(old, :profile_accel,    1000.0),
      profile_decel:    Map.get(old, :profile_decel,    1000.0),
      quick_stop_decel: Map.get(old, :quick_stop_decel, 10_000.0),
      homing_method:    Map.get(old, :homing_method,    1),
      homing_complete:  Map.get(old, :homing_complete,  false),
      fault_code:       Map.get(old, :fault_code),
      sim_inertia:      Map.get(old, :sim_inertia,      1.0),
      sim_noise:        Map.get(old, :sim_noise,         0.0),
      sim_fault_rate:   Map.get(old, :sim_fault_rate,   0.0),
      subscribers:      Map.get(old, :subscribers,      []),
    }
  end
end
