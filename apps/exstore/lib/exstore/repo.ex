defmodule ExStore.Repo do
  @moduledoc """
  The controller's database. One of them.

  This was `ExAuth.Repo` until frames and tools needed somewhere to live.
  Credentials were simply the first table to arrive, not the reason there is a
  database, and a cell's geometry stored in a module named for authentication
  would have been a name nobody could defend at the second call site.

  One database rather than one per app: a controller is backed up, restored and
  migrated as a unit, `backup` is already a declared grant, and a Nerves image
  with four database files has four ways to be half-restored.
  """

  use Ecto.Repo,
    otp_app: :exstore,
    adapter: Ecto.Adapters.SQLite3
end
