import Config

# /data is the writable partition on a Nerves image; the root filesystem is a
# read-only squashfs and does not survive a firmware update. Credentials must,
# so they live here beside the TLS key they are protecting.
config :exauth, ExAuth.Repo,
  database: "/data/emotion/exauth.db",
  pool_size: 5,
  journal_mode: :wal,
  busy_timeout: 5_000,
  # FULL, not the usual NORMAL companion to WAL. NORMAL can lose the last few
  # commits on power loss; on a machine whose power gets cut by an E-stop as a
  # matter of routine, losing the token that was just issued is a support call
  # nobody will diagnose correctly.
  synchronous: :full
# WAL rather than the default rollback journal. Two reasons, and only one of
# them is speed: readers never block the writer, so a dashboard polling the
# account list cannot stall a login; and a torn write leaves a recoverable log
# rather than a damaged main database, which matters on an SD card that may
# lose power mid-commit.
#
# busy_timeout exists because SQLite permits exactly one writer at a time and
# the honest response to contention is to wait, not to raise.

