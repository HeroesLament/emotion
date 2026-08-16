import Config

config :exstore, ExStore.Repo,
  database: Path.join(System.tmp_dir!(), "emotion_test.db"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  journal_mode: :wal,
  busy_timeout: 5_000

# Argon2 at production cost turns a test suite into a coffee break. These are
# the library's documented minimums and are used ONLY here.
config :argon2_elixir, t_cost: 1, m_cost: 8, parallelism: 1

config :logger, level: :warning

# The test suite owns schema and fixtures; the app must not migrate or invent
# an administrator underneath it.
config :exstore, auto_migrate: false
config :exauth, auto_provision: false

# Port 0 — the OS picks an ephemeral one. The OPC UA server binds at
# application start, so a fixed 4840 meant the whole suite refused to run
# whenever a controller was up on the same machine. A test run should not
# depend on what else the developer happens to have running.
config :exhmi, port: 0
