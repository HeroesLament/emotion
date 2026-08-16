defmodule ExStore.Migrator do
  @moduledoc """
  Brings the schema up, synchronously, at startup.

  This was `ExAuth.Bootstrap`'s first job and the argument is unchanged: a
  Nerves controller has no operator at a shell to run `mix ecto.migrate`, so the
  schema has to bring itself up, and doing it in `init/1` blocks the supervisor
  so nothing further down the tree can serve against a half-migrated database.

  It now runs one step earlier than the account provisioning it used to share a
  process with, because provisioning is a fact about `exauth` and migrating is a
  fact about every app that stores anything.

  Returns `:ignore`, so this leaves no process behind once it has run.
  """

  use GenServer, restart: :transient

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    if Application.get_env(:exstore, :auto_migrate, true), do: migrate()
    :ignore
  end

  @doc """
  Brings the schema up to date.

  Exposed so a release task or a test can call it without starting the app.
  """
  def migrate do
    Ecto.Migrator.run(ExStore.Repo, migrations_path(), :up, all: true, log: :info)
  end

  @doc "Where the migrations live. One path, for the whole controller."
  def migrations_path, do: Application.app_dir(:exstore, "priv/repo/migrations")
end
