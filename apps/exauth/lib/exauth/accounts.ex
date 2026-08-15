defmodule ExAuth.Accounts do
  @moduledoc """
  Creating, finding and authenticating accounts.
  """

  import Ecto.Query

  alias ExAuth.Accounts.Account
  alias ExAuth.Repo

  @doc "Creates an account. `attrs` needs `:username`, `:password` and `:role`."
  @spec create(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Account{}
    |> Account.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches by username. Usernames are stored normalised, so this normalises too."
  @spec get_by_username(String.t()) :: Account.t() | nil
  def get_by_username(username) when is_binary(username) do
    Repo.get_by(Account, username: username |> String.trim() |> String.downcase())
  end

  @spec get(integer()) :: Account.t() | nil
  def get(id), do: Repo.get(Account, id)

  @spec list() :: [Account.t()]
  def list, do: Repo.all(from a in Account, order_by: a.username)

  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(Account, :count)

  @doc """
  Verifies a username and password.

  ## Constant work on the unknown-user path

  When the username does not exist, this still runs a hash verification against
  a dummy value (`Argon2.no_user_verify/0`). Skipping it would make "no such
  user" return in microseconds while "wrong password" takes ~100 ms, which is a
  username oracle any client can read off a stopwatch. Costing ourselves the
  work is the price of not confirming which accounts exist.

  Note this deliberately does not throttle — `ExAuth.login/3` owns that, so the
  counter can cover the peer address as well as the username.
  """
  @spec verify_password(String.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :bad_credentials | :disabled}
  def verify_password(username, password) when is_binary(username) and is_binary(password) do
    case get_by_username(username) do
      nil ->
        Argon2.no_user_verify()
        {:error, :bad_credentials}

      account ->
        cond do
          not Argon2.verify_pass(password, account.password_hash) ->
            {:error, :bad_credentials}

          account.disabled_at != nil ->
            # Checked after the password on purpose: answering "that account is
            # disabled" to an unauthenticated guess confirms the username.
            {:error, :disabled}

          true ->
            {:ok, account}
        end
    end
  end

  def verify_password(_username, _password) do
    Argon2.no_user_verify()
    {:error, :bad_credentials}
  end

  @doc "Records a successful login. Best-effort: a failure here must not fail the login."
  @spec touch_login(Account.t()) :: Account.t()
  def touch_login(%Account{} = account) do
    now = DateTime.utc_now()

    case Repo.update(Ecto.Changeset.change(account, %{last_login_at: now})) do
      {:ok, updated} -> updated
      {:error, _changeset} -> account
    end
  end

  @spec change_password(Account.t(), String.t()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def change_password(%Account{} = account, new_password) do
    account
    |> Account.password_changeset(%{password: new_password})
    |> Repo.update()
  end

  @spec change_role(Account.t(), atom()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def change_role(%Account{} = account, role) do
    account
    |> Account.role_changeset(role)
    |> Repo.update()
  end

  @doc """
  Disables an account and revokes every token it holds.

  The token revocation is the point. Disabling an account whose tokens stay
  valid disables nothing — the client that mattered was never going to present
  a password again.
  """
  @spec disable(Account.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def disable(%Account{} = account) do
    Repo.transaction(fn ->
      {:ok, updated} =
        account
        |> Account.disabled_changeset(true)
        |> Repo.update()

      ExAuth.Tokens.revoke_all_for_account(account.id)
      updated
    end)
    |> case do
      {:ok, account} -> {:ok, account}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec enable(Account.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def enable(%Account{} = account) do
    account
    |> Account.disabled_changeset(false)
    |> Repo.update()
  end
end
