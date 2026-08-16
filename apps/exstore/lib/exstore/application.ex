defmodule ExStore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExStore.Repo,
      # Ordered after the Repo because it needs it, and it blocks the supervisor
      # until the schema is current — so nothing downstream, in this app or any
      # other, can start against a database that has not finished migrating.
      ExStore.Migrator
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExStore.Supervisor)
  end
end
