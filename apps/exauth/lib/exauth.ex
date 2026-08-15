defmodule ExAuth do
  @moduledoc """
  The controller's single credential authority.

  Every external surface — the JSON-RPC endpoint in `exproto`, the OPC UA
  server in `ex_opcua`, and whatever admin UI arrives next — authenticates
  through here and authorises with `ExAuth.Grant`. That is the whole reason
  this is its own application rather than living inside `exproto`: two surfaces
  with two credential stores will eventually disagree about who is allowed to
  move the arm, and the disagreement will be discovered by the arm moving.

  ABB arrived at the same shape. Their User Authorization System is one store
  backing Robot Web Services, the PC SDK, the FlexPendant and FTP alike.

  ## The two steps

  `login/3` exchanges a username and password for a bearer token. Password
  verification is deliberately expensive, so it happens once.

  `authenticate/2` exchanges that token for an `ExAuth.Principal` on every
  subsequent connection, cheaply.

  ## What this does not do

  It does not know about transports, sockets or the information model. It
  answers "who is this" and "may they do X", and nothing else.
  """

  alias ExAuth.{Accounts, Grant, Principal, Throttle, Tokens}

  @default_token_label "unnamed client"

  @typedoc "Why an authentication attempt failed."
  @type failure ::
          :bad_credentials
          | :disabled
          | :bad_token
          | :expired
          | :revoked
          | {:throttled, pos_integer()}

  @doc """
  Exchanges a username and password for a token and a principal.

  Options:

    * `:label` — what to call this client in the token list. An operator
      revoking access needs to know which row is the tablet they lost.
    * `:expires_in` — seconds until the token expires.
    * `:peer` — the client's address, throttled alongside the username.

  On success returns `{:ok, principal, raw_token}`. The raw token is shown
  once and never again.

  ## Failure is uniform on purpose

  Bad password, unknown user and disabled account all surface as
  `:bad_credentials` to a caller that has not authenticated. The distinction is
  real and it is recorded in the audit log; it is just not told to whoever is
  guessing, because each distinction is a free answer to a question they were
  asking.
  """
  @spec login(String.t(), String.t(), keyword()) ::
          {:ok, Principal.t(), String.t()} | {:error, failure()}
  def login(username, password, opts \\ []) do
    keys = throttle_keys(username, Keyword.get(opts, :peer))

    with :ok <- check_throttle(keys),
         {:ok, account} <- Accounts.verify_password(username, password) do
      Enum.each(keys, &Throttle.record_success/1)
      account = Accounts.touch_login(account)

      case Tokens.issue(account, Keyword.get(opts, :label, @default_token_label),
             expires_in: Keyword.get(opts, :expires_in)
           ) do
        {:ok, raw, token} ->
          {:ok, Principal.new(account, token_id: token.id), raw}

        {:error, _changeset} ->
          {:error, :bad_credentials}
      end
    else
      {:error, {:throttled, _seconds} = throttled} ->
        {:error, throttled}

      {:error, _reason} ->
        Enum.each(keys, &Throttle.record_failure/1)
        {:error, :bad_credentials}
    end
  end

  @doc """
  Exchanges a bearer token for a principal.

  This is what runs on the connection path, so it is a single indexed lookup
  and a cheap hash — no Argon2, no throttle. Throttling a 256-bit random
  credential protects against nothing and would let anyone lock out a pendant
  by spamming garbage at its username.
  """
  @spec authenticate(String.t(), keyword()) :: {:ok, Principal.t()} | {:error, failure()}
  def authenticate(raw_token, opts \\ []) do
    case Tokens.verify(raw_token) do
      {:ok, account, token} ->
        if Keyword.get(opts, :touch, true), do: Tokens.touch(token)
        {:ok, Principal.new(account, token_id: token.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether a principal holds a grant."
  @spec can?(Principal.t(), Grant.t()) :: boolean()
  defdelegate can?(principal, grant), to: Principal

  @doc "`:ok` or `{:error, {:forbidden, grant}}`, for use in a `with`."
  @spec authorize(Principal.t(), Grant.t()) :: :ok | {:error, {:forbidden, Grant.t()}}
  defdelegate authorize(principal, grant), to: Principal

  @doc """
  Revokes every token an account holds.

  The hook `ExAuth.Principal` refers to: a principal freezes its grants at
  connect time, so anything that changes what an account may do must also cut
  the connections still running on the old answer.
  """
  @spec revoke_sessions(integer()) :: :ok
  defdelegate revoke_sessions(account_id), to: Tokens, as: :revoke_all_for_account

  # ── Throttling ────────────────────────────────────────────────────────────

  defp throttle_keys(username, nil), do: [{:user, normalize(username)}]

  defp throttle_keys(username, peer), do: [{:user, normalize(username)}, {:peer, peer}]

  defp normalize(username) when is_binary(username),
    do: username |> String.trim() |> String.downcase()

  defp normalize(other), do: other

  defp check_throttle(keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Throttle.check(key) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
