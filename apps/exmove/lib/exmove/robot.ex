defmodule ExMove.Robot do
  @moduledoc """
  GenServer owning a live robot instance.

  Loads a kinematic chain, starts one Exdrive axis per joint, and
  provides the interface for moving the robot in joint space.

  Usage:

      {:ok, pid} = ExMove.Robot.start_link(chain: :arctos)

      # Move all joints (blocks until drives accept setpoints)
      ExMove.Robot.move_to(pid, %ExMove.JointState{
        positions: [0.0, -0.5, 1.2, 0.0, 0.5, 0.0]
      })

      # Current joint state
      ExMove.Robot.state(pid)

      # Stream a trajectory
      {:ok, stream} = ExMove.Robot.stream(pid, MyTraj, opts)
      ExMove.Robot.stop_stream(pid)

      # E-stop all axes
      ExMove.Robot.quick_stop(pid)
  """

  use GenServer

  alias ExMove.{Chain, JointState, URDF}

  defstruct [
    chain:      nil,   # %Chain{}
    stream_pid: nil,   # %ExMove.IpStream{} pid | nil
  ]

  # --- Public API -----------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Current joint state — polls all drives"
  def state(pid) do
    GenServer.call(pid, :state)
  end

  @doc "Move all joints to a JointState (profile position mode)"
  def move_to(pid, %JointState{} = js) do
    GenServer.call(pid, {:move_to, js})
  end

  @doc "Start streaming a trajectory across all joints"
  def stream(pid, trajectory, opts \\ []) do
    GenServer.call(pid, {:stream, trajectory, opts})
  end

  @doc "Stop any running trajectory stream"
  def stop_stream(pid) do
    GenServer.call(pid, :stop_stream)
  end

  @doc "Quick stop all axes"
  def quick_stop(pid) do
    GenServer.call(pid, :quick_stop)
  end

  @doc "The loaded chain"
  def chain(pid) do
    GenServer.call(pid, :chain)
  end

  @doc """
  Execute a `%ExMove.Frame{}` stream as a Cartesian path at servo rate.

  Starts a `PathExecutor` under this robot's drives. Returns `{:ok, executor_pid}`.
  The caller receives `{:path_done, pid}` or `{:path_error, pid, reason}` on
  completion.

      stream = ExMove.Path.linear(frame_a, frame_b, 50.0)
      {:ok, exec} = ExMove.Robot.execute_path(robot, stream, notify: self())
  """
  def execute_path(pid, stream, opts \\ []) do
    GenServer.call(pid, {:execute_path, stream, opts})
  end

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(opts) do
    chain = case Keyword.fetch!(opts, :chain) do
      name when is_atom(name) ->
        {:ok, c} = URDF.load(name)
        # The loader no longer invents axis ids, so the caller says what the
        # wiring is. This one has always assumed :j1..:jn in chain order, and
        # saying so here is the difference between an assumption and a default
        # buried in a parser.
        Chain.wire(c, for(i <- 1..length(c.joints), do: :"j#{i}"))
      %Chain{} = c ->
        c
    end

    # Start one Exdrive axis per joint
    Enum.each(Chain.joint_pairs(chain), fn {axis_id, _joint} ->
      {:ok, _} = Exdrive.start_axis(axis_id)
      Exdrive.enable(axis_id)
    end)

    # Give drives time to walk to operation_enabled
    Process.sleep(150)

    {:ok, %__MODULE__{chain: chain}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    js = read_joint_state(state.chain)
    {:reply, js, state}
  end

  def handle_call({:move_to, %JointState{positions: positions} = js}, _from, state) do
    case validate(state.chain, js) do
      :ok ->
        Exdrive.set_mode(axis_id(state.chain, 0), :profile_position)
        state.chain
        |> Chain.joint_pairs()
        |> Enum.zip(positions)
        |> Enum.each(fn {{axis_id, _joint}, pos} ->
          Exdrive.move_to(axis_id, pos)
        end)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:stream, trajectory, opts}, _from, state) do
    # Stop existing stream if any
    state = do_stop_stream(state)

    opts = [{:chain, state.chain}, {:trajectory, trajectory} | opts]
    case ExMove.IpStream.start_link(opts) do
      {:ok, pid} ->
        {:reply, {:ok, pid}, %{state | stream_pid: pid}}
      err ->
        {:reply, err, state}
    end
  end

  def handle_call(:stop_stream, _from, state) do
    state = do_stop_stream(state)
    {:reply, :ok, state}
  end

  def handle_call(:quick_stop, _from, state) do
    state = do_stop_stream(state)
    Enum.each(state.chain.axis_ids, &Exdrive.quick_stop/1)
    {:reply, :ok, state}
  end

  def handle_call(:chain, _from, state) do
    {:reply, state.chain, state}
  end

  def handle_call({:execute_path, stream, opts}, _from, state) do
    push   = fn axis_id, vel -> EMotion.Axis.set_target_velocity(axis_id, vel) end
    notify = Keyword.get(opts, :notify, nil)
    result = ExMove.PathExecutor.start_link(
      chain:  state.chain,
      seed:   read_joint_state(state.chain),
      stream: stream,
      push:   push,
      notify: notify
    )
    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if state.stream_pid == pid do
      {:noreply, %{state | stream_pid: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private helpers ------------------------------------------------------

  defp read_joint_state(chain) do
    positions = chain.axis_ids
      |> Enum.map(fn id ->
        Exdrive.status(id)[:actual_position]
      end)
    JointState.from_positions(positions)
  end

  defp validate(chain, %JointState{positions: positions}) do
    expected = Chain.dof(chain)
    actual   = length(positions)
    if actual == expected do
      :ok
    else
      {:error, {:wrong_dof, expected: expected, got: actual}}
    end
  end

  defp do_stop_stream(%{stream_pid: nil} = state), do: state
  defp do_stop_stream(%{stream_pid: pid} = state) do
    ExMove.IpStream.stop(pid)
    %{state | stream_pid: nil}
  end

  defp axis_id(chain, index), do: Enum.at(chain.axis_ids, index)
end
