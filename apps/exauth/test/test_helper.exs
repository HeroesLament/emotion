# The Repo is already running — the application supervisor started it. Only the
# schema needs bringing up, since :auto_migrate is off under test so the suite
# owns it.
#
# A file-backed database rather than :memory: on purpose: with SQLite an
# in-memory database belongs to the connection that created it, and the sandbox
# hands connections between processes.
Ecto.Migrator.run(
  ExAuth.Repo,
  Application.app_dir(:exauth, "priv/repo/migrations"),
  :up,
  all: true,
  log: false
)

Ecto.Adapters.SQL.Sandbox.mode(ExAuth.Repo, :manual)

ExUnit.start()
