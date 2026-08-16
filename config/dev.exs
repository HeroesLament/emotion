import Config

config :exstore, ExStore.Repo,
  database: Path.expand("../.emotion/emotion_dev.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  busy_timeout: 5_000
