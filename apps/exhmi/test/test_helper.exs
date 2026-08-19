# This app stores nothing, but EMotion.Cell reads what exstore stores, so the
# suite needs the schema up and the sandbox in a known mode. Same shape as
# exauth's helper and for the same reason: the mode is set both sides of the
# migration so that a single-app run and an umbrella run both work, whichever
# other helper has already been here.
Ecto.Adapters.SQL.Sandbox.mode(ExStore.Repo, :auto)

Ecto.Migrator.run(ExStore.Repo, ExStore.Migrator.migrations_path(), :up, all: true, log: false)

Ecto.Adapters.SQL.Sandbox.mode(ExStore.Repo, :manual)

ExUnit.start()
