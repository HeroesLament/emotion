defmodule ExMove.IpStream do
  @moduledoc """
  Drives all joints of a robot in IP mode from a trajectory source.

  Each tick calls trajectory.next/2 to get a JointState, then pushes
  each position to the corresponding Exdrive axis.

  Usage:

      {:ok, pid} = ExMove.IpStream.start_link(
        chain:      chain,
        trajectory: ExMove.Trajectory.Sine,
        hz:         100,
        amplitude:  0.5,   # radians
        period:     4.0    # seconds
      )

      ExMove.IpStream.stop(pid)
  """

  use GenServer

  alias ExMove.{Chain, JointState}

  @default_hz 100

  defstruct [
    chain:      nil,
    traj_mod:   nil,
    traj_state: nil,
    hz:         @default_hz,
    tick_ms:    10,
    t:          0.0,
  ]

  # --- Public API -----------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(opts) do
    chain    = Keyword.fetch!(opts, :chain)
    traj_mod = Keyword.fetch!(opts, :trajectory)
    hz       = Keyword.get(opts, :hz, @default_hz)
    tick_ms  = round(1000 / hz)

    traj_opts = Keyword.drop(opts, [:chain, :trajectory, :hz])
    traj_opts = [{:chain, chain} | traj_opts]

    case traj_mod.init(traj_opts) do
      {:ok, traj_state} ->
        # Put all axes in IP mode
        Enum.each(chain.axis_ids, &Exdrive.set_mode(&1, :interpolated_position))

        state = %__MODULE__{
          chain:      chain,
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

  @impl true
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    t = state.t + state.tick_ms / 1000.0

    case apply(state.traj_mod, :next, [t, state.traj_state]) do
      {:ok, %JointState{positions: positions}, new_traj_state} ->
        state.chain
        |> Chain.joint_pairs()
        |> Enum.zip(positions)
        |> Enum.each(fn {{axis_id, _joint}, pos} ->
          Exdrive.Drive.set_target_position(axis_id, pos)
        end)
        Process.send_after(self(), :tick, state.tick_ms)
        {:noreply, %{state | t: t, traj_state: new_traj_state}}

      {:done, _new_traj_state} ->
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, {:trajectory_error, reason}, state}
    end
  end
end
