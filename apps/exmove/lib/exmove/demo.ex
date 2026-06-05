defmodule ExMove.Demo do
  @moduledoc """
  Quick demo — starts Arctos, streams a sine wave across all 6 joints,
  launches Exdash to watch. Press q to quit the dashboard; stream keeps
  running. Call ExMove.Demo.stop/1 to clean up.
  """

  def run(opts \\ []) do
    amplitude  = Keyword.get(opts, :amplitude,  0.4)   # radians ~23°
    period     = Keyword.get(opts, :period,      6.0)   # seconds per cycle
    hz         = Keyword.get(opts, :hz,          100)

    IO.puts("Starting Arctos robot...")
    {:ok, robot} = ExMove.Robot.start_link(chain: :arctos)
    Process.sleep(200)

    IO.puts("Starting sine trajectory — amplitude=#{amplitude}rad period=#{period}s hz=#{hz}")
    {:ok, _stream} = ExMove.Robot.stream(robot, ExMove.Trajectory.Sine,
      amplitude:  amplitude,
      period:     period,
      hz:         hz
    )

    IO.puts("Launching dashboard — press q to exit dashboard (stream continues)")
    Exdash.watch([:j1, :j2, :j3, :j4, :j5, :j6],
      j1: [pos_min: -1.0, pos_max: 1.0],
      j2: [pos_min: -1.0, pos_max: 1.0],
      j3: [pos_min: -1.0, pos_max: 1.0],
      j4: [pos_min: -1.0, pos_max: 1.0],
      j5: [pos_min: -1.0, pos_max: 1.0],
      j6: [pos_min: -1.0, pos_max: 1.0]
    )

    IO.puts("Dashboard closed. Robot still running. Call ExMove.Demo.stop(robot) to shut down.")
    robot
  end

  def stop(robot) do
    ExMove.Robot.quick_stop(robot)
    GenServer.stop(robot)
    IO.puts("Robot stopped.")
  end
end
