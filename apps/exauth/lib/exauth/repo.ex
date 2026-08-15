defmodule ExAuth.Repo do
  use Ecto.Repo,
    otp_app: :exauth,
    adapter: Ecto.Adapters.SQLite3
end
