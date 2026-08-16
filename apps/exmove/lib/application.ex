defmodule ExMove.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Cartesian streams are found by arm name, because the thing that refreshes
      # one is a jog assertion carrying a node id and no pid.
      {Registry, keys: :unique, name: ExMove.StreamRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: ExMove.StreamSupervisor}
    ]

    opts = [strategy: :one_for_one, name: ExMove.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
