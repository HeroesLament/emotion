defmodule ExAuth.Bootstrap do
  @moduledoc """
  Runs migrations and first-boot provisioning, synchronously, at startup.

  A Nerves controller has no operator at a shell to run `mix ecto.migrate`, so
  the schema has to bring itself up. Doing it in `init/1` rather than in a
  `Task` is deliberate: it blocks the supervisor, which means nothing further
  down the tree can start serving against a database that has not finished
  migrating. A `Task` would be a race with a nondeterministic outcome, which is
  the worst kind to have in the credential store.

  Returns `:ignore`, so this leaves no process behind once it has run.
  """

  use GenServer, restart: :transient

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    if Application.get_env(:exauth, :auto_migrate, true), do: migrate()
    if Application.get_env(:exauth, :auto_provision, true), do: provision()
    :ignore
  end

  @doc """
  Brings the schema up to date.

  Exposed so a release task or a test can call it without starting the app.
  """
  def migrate do
    path = Application.app_dir(:exauth, "priv/repo/migrations")
    Ecto.Migrator.run(ExAuth.Repo, path, :up, all: true, log: :info)
  end

  defp provision do
    case ExAuth.Provision.ensure_administrator() do
      {:created, _username, _password} -> :ok
      :exists -> :ok
      {:error, reason} -> Logger.error("could not provision administrator: #{inspect(reason)}")
    end
  end
end
