defmodule ExAuth.Repo.Migrations.CreateTokens do
  use Ecto.Migration

  def change do
    create table(:tokens) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :label, :string, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Verification is a lookup on this index. Without it, every authenticated
    # request would scan the table.
    create unique_index(:tokens, [:token_hash])
    create index(:tokens, [:account_id])
  end
end
