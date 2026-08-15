import Config

config :exauth, ExAuth.Repo,
  database: Path.expand("../.emotion/exauth_dev.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  busy_timeout: 5_000
