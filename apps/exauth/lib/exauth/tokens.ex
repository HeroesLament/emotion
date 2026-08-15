defmodule ExAuth.Tokens do
  @moduledoc """
  Issuing and verifying opaque bearer tokens.

  ## Shape

  `emo_` followed by 32 random bytes in unpadded URL-safe base64. The prefix is
  not decoration: it lets a secret scanner, a log filter or a human reading a
  paste recognise the string as a credential, which is the difference between
  a leak that gets caught and one that does not.

  The raw token is returned exactly once, at issue. Only its SHA-256 is stored.
  There is no "show me the token again" — that operation cannot exist without
  storing the token, and a credential store that can display credentials is a
  credential store that can lose them.
  """

  import Ecto.Query

  alias ExAuth.Accounts.Account
  alias ExAuth.Repo
  alias ExAuth.Tokens.Token

  @prefix "emo_"
  @bytes 32

  @doc """
  Issues a token for an account.

  Returns `{:ok, raw_token, token}`. The raw token is not recoverable after
  this call returns.

  Options:

    * `:expires_in` — seconds until expiry. Omit for a token that does not
      expire, which is the right choice for a paired pendant and the wrong one
      for anything a browser holds.
  """
  @spec issue(Account.t(), String.t(), keyword()) ::
          {:ok, String.t(), Token.t()} | {:error, Ecto.Changeset.t()}
  def issue(%Account{} = account, label, opts \\ []) do
    raw = generate()

    attrs = %{
      token_hash: hash(raw),
      label: label,
      account_id: account.id,
      expires_at: expires_at(Keyword.get(opts, :expires_in))
    }

    %Token{}
    |> Token.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, token} -> {:ok, raw, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verifies a presented token and returns the account behind it.

  Rejects a revoked token, an expired one, and one whose account has since been
  disabled — the last of those matters because the account check happens here
  rather than only at password time, so disabling an account takes effect on
  the next request even for a client that never logs in.
  """
  @spec verify(String.t()) ::
          {:ok, Account.t(), Token.t()} | {:error, :bad_token | :expired | :revoked | :disabled}
  def verify(raw) when is_binary(raw) do
    now = DateTime.utc_now()

    query =
      from t in Token,
        where: t.token_hash == ^hash(raw),
        preload: [:account]

    case Repo.one(query) do
      nil ->
        {:error, :bad_token}

      %Token{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :revoked}

      %Token{} = token ->
        cond do
          not Token.usable?(token, now) -> {:error, :expired}
          token.account.disabled_at != nil -> {:error, :disabled}
          true -> {:ok, token.account, token}
        end
    end
  end

  def verify(_raw), do: {:error, :bad_token}

  @doc """
  Records that a token was used.

  Best-effort and deliberately not on the request path's critical section: this
  is for an operator asking "is this pendant still talking to us", not for
  anything the protocol depends on.
  """
  @spec touch(Token.t()) :: :ok
  def touch(%Token{} = token) do
    from(t in Token, where: t.id == ^token.id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])

    :ok
  end

  @spec revoke(Token.t() | integer()) :: :ok
  def revoke(%Token{id: id}), do: revoke(id)

  def revoke(id) when is_integer(id) do
    from(t in Token, where: t.id == ^id and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    :ok
  end

  @spec revoke_all_for_account(integer()) :: :ok
  def revoke_all_for_account(account_id) when is_integer(account_id) do
    from(t in Token, where: t.account_id == ^account_id and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    :ok
  end

  @spec list_for_account(integer()) :: [Token.t()]
  def list_for_account(account_id) do
    Repo.all(from t in Token, where: t.account_id == ^account_id, order_by: [desc: t.inserted_at])
  end

  @doc "The prefix every token carries."
  def prefix, do: @prefix

  @doc """
  Whether a string is shaped like one of our tokens.

  Useful for telling "you sent us something that is not a token" from "you sent
  us a token we do not recognise" without a database lookup — but note the
  answer is never used to skip verification, only to phrase an error.
  """
  @spec well_formed?(term()) :: boolean()
  def well_formed?(raw) when is_binary(raw) do
    case String.split_at(raw, byte_size(@prefix)) do
      {@prefix, body} -> match?({:ok, <<_::binary-size(@bytes)>>}, Base.url_decode64(body, padding: false))
      _ -> false
    end
  end

  def well_formed?(_raw), do: false

  defp generate do
    @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@bytes), padding: false)
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp expires_at(nil), do: nil

  defp expires_at(seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.utc_now() |> DateTime.add(seconds, :second)
  end
end
