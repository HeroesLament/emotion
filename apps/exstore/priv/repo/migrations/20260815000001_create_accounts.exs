defmodule ExStore.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :role, :string, null: false
      add :disabled_at, :utc_datetime_usec
      add :must_change_password, :boolean, null: false, default: false
      add :last_login_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Usernames are normalised to lowercase before insert, so a plain unique
    # index is genuinely case-insensitive here. SQLite's COLLATE NOCASE would
    # also work but only for ASCII, and silently not for anything else.
    create unique_index(:accounts, [:username])
  end
end
