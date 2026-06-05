defmodule ExHMI.AddressSpace do
  @moduledoc """
  Canonical in-memory state of the arm, updated by ExMove telemetry and
  read by the OPC UA transport on each server iteration.

  Joint positions are stored in radians (6-element list).
  TCP pose is stored as {x, y, z} in metres and {rx, ry, rz} in radians.
  Motion state is one of: :idle | :running | :paused | :error.

  Clients (e.g. RoboDK) read these via OPC UA subscriptions.
  Write commands arrive via `handle_command/1` called from the OPC UA
  transport's `handle_write/2` callback.
  """

  use GenServer
  require Logger

  @joint_count 6

  defstruct [
    joint_positions: List.duplicate(0.0, @joint_count),
    tcp_xyz: {0.0, 0.0, 0.0},
    tcp_rpy: {0.0, 0.0, 0.0},
    motion_state: :idle,
    # pending target set by OPC UA client write (MoveJ command)
    pending_target: nil
  ]

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Returns current joint positions in radians as a 6-element list."
  def joint_positions, do: GenServer.call(__MODULE__, :joint_positions)

  @doc "Returns current TCP pose as {{x,y,z}, {rx,ry,rz}} in metres/radians."
  def tcp_pose, do: GenServer.call(__MODULE__, :tcp_pose)

  @doc "Returns current motion state atom."
  def motion_state, do: GenServer.call(__MODULE__, :motion_state)

  @doc "Returns a snapshot map of the full address space state."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Push a joint-state update from ExMove telemetry into the address space.
  Called periodically by the OPC UA transport's tick timer, or directly from
  an ExMove.Robot subscription.
  """
  def update_joint_state(joint_positions, tcp_xyz, tcp_rpy) do
    GenServer.cast(__MODULE__, {:update_joint_state, joint_positions, tcp_xyz, tcp_rpy})
  end

  @doc "Update motion state (called when PathExecutor sends :path_done / :path_error)."
  def update_motion_state(state) when state in [:idle, :running, :paused, :error] do
    GenServer.cast(__MODULE__, {:update_motion_state, state})
  end

  @doc """
  Handle a command written to the OPC UA `Command` node by a client (e.g. RoboDK).
  Supported command strings:
    \"stop\"             – halt PathExecutor
    \"home\"             – move to home joint state
    \"movej:<j1>,…,<j6>\" – move to joint target (radians, comma-separated)
  """
  def handle_command(command_string) do
    GenServer.cast(__MODULE__, {:command, command_string})
  end

  @doc "Return and clear the pending target (consumed by OPC UA transport)."
  def pop_pending_target do
    GenServer.call(__MODULE__, :pop_pending_target)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    Logger.info("[ExHMI.AddressSpace] started")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:joint_positions, _from, state) do
    {:reply, state.joint_positions, state}
  end

  def handle_call(:tcp_pose, _from, state) do
    {:reply, {state.tcp_xyz, state.tcp_rpy}, state}
  end

  def handle_call(:motion_state, _from, state) do
    {:reply, state.motion_state, state}
  end

  def handle_call(:snapshot, _from, state) do
    snap = %{
      joint_positions: state.joint_positions,
      tcp_xyz: state.tcp_xyz,
      tcp_rpy: state.tcp_rpy,
      motion_state: state.motion_state
    }
    {:reply, snap, state}
  end

  def handle_call(:pop_pending_target, _from, state) do
    {:reply, state.pending_target, %{state | pending_target: nil}}
  end

  @impl true
  def handle_cast({:update_joint_state, positions, xyz, rpy}, state) do
    {:noreply, %{state | joint_positions: positions, tcp_xyz: xyz, tcp_rpy: rpy}}
  end

  def handle_cast({:update_motion_state, ms}, state) do
    {:noreply, %{state | motion_state: ms}}
  end

  def handle_cast({:command, cmd_str}, state) do
    state = parse_command(cmd_str, state)
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp parse_command("stop", state) do
    Logger.info("[ExHMI] command: stop")
    # TODO: send stop signal to PathExecutor when wired up
    %{state | motion_state: :idle}
  end

  defp parse_command("home", state) do
    Logger.info("[ExHMI] command: home")
    home = List.duplicate(0.0, @joint_count)
    %{state | pending_target: {:movej, home}}
  end

  defp parse_command("movej:" <> rest, state) do
    angles =
      rest
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_float/1)

    if length(angles) == @joint_count and Enum.all?(angles, &is_float/1) do
      Logger.info("[ExHMI] command: movej #{inspect(angles)}")
      %{state | pending_target: {:movej, angles}}
    else
      Logger.warning("[ExHMI] malformed movej command: #{rest}")
      state
    end
  end

  defp parse_command(unknown, state) do
    Logger.warning("[ExHMI] unknown command: #{unknown}")
    state
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, ""} -> f
      _ -> :error
    end
  end
end
