defmodule ExAuth.Accounts.Account do
  @moduledoc """
  A named human (or service) principal.

  Passwords are stored as Argon2id hashes and are never held in the struct in
  any other form: `:password` is `virtual` and is cleared by the changeset the
  moment it has been hashed, so a struct that escapes into a log or an error
  report cannot carry one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ExAuth.Role

  @min_password_length 12

  schema "accounts" do
    field :username, :string
    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :role, Ecto.Enum, values: [:observer, :operator, :programmer, :maintainer, :administrator, :safety_officer]
    field :disabled_at, :utc_datetime_usec
    field :must_change_password, :boolean, default: false
    field :last_login_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Minimum password length this build accepts."
  def min_password_length, do: @min_password_length

  @doc """
  Changeset for creating an account.
  """
  def create_changeset(account, attrs) do
    account
    |> cast(attrs, [:username, :password, :role, :must_change_password])
    |> validate_required([:username, :password, :role])
    |> normalize_username()
    |> validate_username()
    |> validate_password()
    |> hash_password()
    |> unique_constraint(:username)
  end

  @doc """
  Changeset for replacing a password.

  Clears `must_change_password`, because the only way to reach here is to have
  changed it.
  """
  def password_changeset(account, attrs) do
    account
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password()
    |> hash_password()
    |> put_change(:must_change_password, false)
  end

  @doc "Changeset for changing an account's role."
  def role_changeset(account, role) do
    account
    |> change(%{role: role})
    |> validate_required([:role])
    |> validate_inclusion(:role, Role.all())
  end

  @doc "Changeset for disabling or re-enabling an account."
  def disabled_changeset(account, disabled?) do
    change(account, %{disabled_at: if(disabled?, do: DateTime.utc_now(), else: nil)})
  end

  defp normalize_username(changeset) do
    update_change(changeset, :username, fn username ->
      username |> String.trim() |> String.downcase()
    end)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: 2, max: 64)
    # Deliberately narrow. A username ends up in log lines, audit records and
    # an OPC UA identity token; permitting whitespace, colons or control
    # characters buys nothing and creates parsing ambiguity in all three.
    |> validate_format(:username, ~r/\A[a-z0-9][a-z0-9._-]*\z/,
      message: "must start alphanumeric and contain only a-z, 0-9, dot, underscore or hyphen"
    )
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: @min_password_length, max: 1024)
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset
end
