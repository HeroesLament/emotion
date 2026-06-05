defmodule Exdrive do
  @moduledoc """
  Exdrive — CiA 402 motion drive library for ExMo.

  Quick start in iex:

      # Start a simulated axis
      Exdrive.start_axis(:j1)

      # Enable it (walks the CiA402 state machine)
      Exdrive.enable(:j1)

      # Move to position (profile position mode)
      Exdrive.move_to(:j1, 90.0)

      # Stream a sine wave in IP mode
      {:ok, pid} = Exdrive.stream(:j1, Exdrive.Trajectory.Sine, amplitude: 90.0, period: 2.0)
      Exdrive.stop_stream(pid)

      # Watch live position updates
      Exdrive.subscribe(:j1)
      # receives {:position_update, axis_id, pos, vel, torque}

      # Quick stop / fault recovery
      Exdrive.quick_stop(:j1)
      Exdrive.fault_reset(:j1)
      Exdrive.enable(:j1)
  """

  alias Exdrive.{Drive, Supervisor}

  @doc "Start a simulated drive axis"
  def start_axis(axis_id, opts \\ []) do
    opts = Keyword.merge([axis_id: axis_id], opts)
    Supervisor.start_drive(opts)
  end

  @doc "Enable a drive (walks shutdown → switch_on → operation_enabled)"
  defdelegate enable(axis_id),                      to: Drive

  @doc "Set mode of operation"
  defdelegate set_mode(axis_id, mode),              to: Drive

  @doc "Move to target position in profile position mode"
  defdelegate move_to(axis_id, position),           to: Drive, as: :set_target_position

  @doc """
  Push a position setpoint in IP or CSP mode. Non-blocking hot path.
  Returns :ok immediately. Overwrites any pending setpoint.
  This is the callsite for ExMove -> Exdrive in real-time operation.
  """
  defdelegate push(axis_id, position),              to: Drive, as: :set_target_position

  @doc "Set target velocity (profile velocity / CSV modes)"
  defdelegate set_target_velocity(axis_id, vel),    to: Drive

  @doc "Set target torque (profile torque / CST modes)"
  defdelegate set_target_torque(axis_id, torque),   to: Drive

  @doc "Get current drive status map (synchronous)"
  defdelegate status(axis_id),                      to: Drive

  @doc "Quick stop — decelerates to zero then disables"
  defdelegate quick_stop(axis_id),                  to: Drive

  @doc "Reset a faulted drive"
  defdelegate fault_reset(axis_id),                 to: Drive

  @doc "Subscribe this process to position/state messages from a drive"
  defdelegate subscribe(axis_id),                   to: Drive

  @doc "Send a raw CiA402 control word"
  defdelegate control_word(axis_id, cw),            to: Drive

  @doc """
  Start an IpStream for axis_id driven by a trajectory module.

      {:ok, pid} = Exdrive.stream(:j1, Exdrive.Trajectory.Sine,
                                  amplitude: 90.0, period: 2.0, hz: 100)
  """
  def stream(axis_id, trajectory, opts \\ []) do
    opts = [{:axis_id, axis_id}, {:trajectory, trajectory} | opts]
    Exdrive.IpStream.start_link(opts)
  end

  @doc "Stop a running IpStream"
  defdelegate stop_stream(pid), to: Exdrive.IpStream, as: :stop
end
