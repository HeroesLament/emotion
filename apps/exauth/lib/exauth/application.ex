defmodule ExAuth.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExAuth.Repo,
      ExAuth.Throttle,
      # Ordered after the Repo because it needs it, and it blocks the
      # supervisor until migrations and provisioning are done — so nothing
      # downstream can accept a connection against a half-built schema.
      ExAuth.Bootstrap
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAuth.Supervisor)
  end
end
