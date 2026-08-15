defmodule ExAuth.Tokens.Token do
  @moduledoc """
  A bearer credential issued to one client.

  ## Why the hash here is SHA-256 and not Argon2

  A password is low-entropy and chosen by a human, so it needs a slow KDF to
  make an offline guessing attack expensive. A token is 256 bits from
  `:crypto.strong_rand_bytes/1`; there is no dictionary to run against it and
  no amount of hardware that makes guessing it feasible. A slow hash would add
  nothing but latency — and unlike a login, this one would be paid on the
  connection path.

  What SHA-256 does buy, and the reason the raw token is not stored, is that a
  leaked database backup does not hand over working credentials.

  Lookup is by hash and the hash column is uniquely indexed, so verification is
  an index hit rather than a scan over rows compared one at a time.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ExAuth.Accounts.Account

  schema "tokens" do
    field :token_hash, :string, redact: true
    field :label, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :label, :expires_at, :account_id])
    |> validate_required([:token_hash, :label, :account_id])
    |> validate_length(:label, min: 1, max: 128)
    |> assoc_constraint(:account)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Whether this token may still be presented.

  Revocation and expiry are separate columns because they are separate facts:
  an expired token was fine and ran out, a revoked one was withdrawn. Collapsing
  them loses the distinction exactly when an audit needs it.
  """
  def usable?(%__MODULE__{revoked_at: revoked}, _now) when not is_nil(revoked), do: false
  def usable?(%__MODULE__{expires_at: nil}, _now), do: true

  def usable?(%__MODULE__{expires_at: expires_at}, now) do
    DateTime.compare(expires_at, now) == :gt
  end
end
