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
      EMotion.Cell.Server
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EMotion.Supervisor)
  end
end
