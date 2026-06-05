defmodule Exdrive.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Exdrive.Supervisor]
    opts = [strategy: :one_for_one, name: Exdrive.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
