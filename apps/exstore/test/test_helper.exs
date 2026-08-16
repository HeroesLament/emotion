# Mode first, migrations second, mode again.
#
# In an umbrella run some other app's helper has already put this Repo in
# :manual, and a migration is an ordinary query — running one in :manual from a
# process that owns no connection raises DBConnection.OwnershipError before a
# single test has started. Running each app's suite alone has to work too, so
# the mode is set both sides of the migration rather than assumed either way.
#
# A file-backed database rather than :memory: on purpose: with SQLite an
# in-memory database belongs to the connection that created it, and the sandbox
# hands connections between processes.
Ecto.Adapters.SQL.Sandbox.mode(ExStore.Repo, :auto)

Ecto.Migrator.run(ExStore.Repo, ExStore.Migrator.migrations_path(), :up, all: true, log: false)

Ecto.Adapters.SQL.Sandbox.mode(ExStore.Repo, :manual)

ExUnit.start()
