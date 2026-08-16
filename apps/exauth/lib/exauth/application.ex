defmodule ExAuth.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExAuth.Throttle,
      # Blocks the supervisor until provisioning is done, so nothing
      # downstream can accept a connection before there is an account to
      # accept it as. The schema is already current: ExStore.Migrator ran in
      # exstore's application, which starts first because exauth depends on it.
      ExAuth.Bootstrap
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAuth.Supervisor)
  end
end
