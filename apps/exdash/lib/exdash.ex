defmodule Exdash do
  @moduledoc """
  Exdash — mode-aware terminal dashboard for ExDrive axes.

  Basic usage:

      Exdrive.start_axis(:j1)
      Exdrive.enable(:j1)
      Exdash.watch([:j1, :j2])

  With per-axis config:

      Exdash.watch([:j1, :j2],
        j1: [pos_min: -180.0, pos_max: 180.0, vel_max: 200.0, trq_max: 50.0],
        j2: [pos_min:    0.0, pos_max: 360.0, vel_max: 500.0, trq_max: 100.0]
      )

  Press q to quit and return to iex.
  """

  def watch(axis_ids, cfg \\ []) when is_list(axis_ids) do
    opts = [{:axes, axis_ids} | cfg]
    {:ok, pid} = Exdash.Dashboard.start_link(opts)
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
