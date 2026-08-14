defmodule EMotion.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Discovery walks every loaded application's module list, so it happens
    # once here rather than on demand — `view/1` reads the registry on every
    # model change, and a code path scan at frame rate is its own stall.
    EMotion.Workbench.Registry.refresh()

    children = [
      EMotion.Job,
      # Opened onto a demo arm rather than an empty void: a blank 3D viewport
      # gives a new user no way to tell "working, nothing loaded" from
      # "broken". Goes away when there is a start page and a file format.
      {EMotion.Cell.Server, cell: EMotion.Startup.demo_cell()},
      {EMotion.Boot, steps: EMotion.Startup.steps()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EMotion.Supervisor)
  end
end
