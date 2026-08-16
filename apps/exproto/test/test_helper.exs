# Mode first, migrations second. In an umbrella run exauth's helper has already
# put this Repo in :manual, and a migration is an ordinary query — running one
# in :manual from a process that owns no connection raises
# DBConnection.OwnershipError before a single test has started.
#
# :auto rather than the sandbox because the connections under test are made by
# Bandit-owned processes that are not descendants of the test process, and
# shared mode is refused while this app's async tests are running — which most
# of them are, and should stay.
Ecto.Adapters.SQL.Sandbox.mode(ExStore.Repo, :auto)

Ecto.Migrator.run(
  ExStore.Repo,
  ExStore.Migrator.migrations_path(),
  :up,
  all: true,
  log: false
)

ExUnit.start()
