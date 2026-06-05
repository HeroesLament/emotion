defmodule Exdrive.IpStream do
  @moduledoc """
  Drives one axis in IP (interpolated position) mode from a trajectory source.

  IpStream owns the cycle timer. Each tick it calls the trajectory module's
  `next/2`, gets a position, and pushes it to the drive via `Exdrive.push/2`.

  The trajectory module is resolved fresh each tick via `apply/3` — this means
  `r MyTrajectory` in iex takes effect on the next tick with no restart needed.

  Usage:

      # Start streaming a sine wave to :j1 at 100Hz
      {:ok, pid} = Exdrive.IpStream.start_link(
        axis_id:    :j1,
        trajectory: Exdrive.Trajectory.Sine,
        hz:         100,
        amplitude:  90.0,
        period:     2.0
      )

      # Stop
      Exdrive.IpStream.stop(pid)

  The drive must already be in :operation_enabled state before starting.
  IpStream will call `Exdrive.set_mode(:j1, :interpolated_position)` automatically.
  """

  use GenServer

  @default_hz 100

  defstruct [
    axis_id:       nil,
    traj_mod:      nil,
    traj_state:    nil,
    hz:            @default_hz,
    tick_ms:       10,
    t:             0.0,
    cycle:         0,
  ]

  # --- Public API ------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- GenServer callbacks ---------------------------------------------------

  def init(opts) do
    axis_id  = Keyword.fetch!(opts, :axis_id)
    traj_mod = Keyword.fetch!(opts, :trajectory)
    hz       = Keyword.get(opts, :hz, @default_hz)
    tick_ms  = round(1000 / hz)

    # Strip IpStream keys, pass remaining opts to trajectory init
    traj_opts = Keyword.drop(opts, [:axis_id, :trajectory, :hz])

    case traj_mod.init(traj_opts) do
      {:ok, traj_state} ->
        Exdrive.Drive.set_mode(axis_id, :interpolated_position)
        state = %__MODULE__{
          axis_id:    axis_id,
          traj_mod:   traj_mod,
          traj_state: traj_state,
          hz:         hz,
          tick_ms:    tick_ms,
        }
        {:ok, state, {:continue, :schedule}}

      {:error, reason} ->
        {:stop, {:trajectory_init_failed, reason}}
    end
  end

  def handle_continue(:schedule, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    dt = state.tick_ms / 1000.0
    t  = state.t + dt

    case apply(state.traj_mod, :next, [t, state.traj_state]) do
      {:ok, position, new_traj_state} ->
        Exdrive.Drive.set_target_position(state.axis_id, position)
        Process.send_after(self(), :tick, state.tick_ms)
        {:noreply, %{state | t: t, traj_state: new_traj_state, cycle: state.cycle + 1}}

      {:done, _new_traj_state} ->
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, {:trajectory_error, reason}, state}
    end
  end
end
