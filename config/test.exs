import Config

config :exauth, ExAuth.Repo,
  database: Path.join(System.tmp_dir!(), "exauth_test.db"),
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
config :exauth, auto_migrate: false, auto_provision: false
