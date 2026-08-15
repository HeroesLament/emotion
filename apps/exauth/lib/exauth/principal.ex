defmodule ExAuth.Principal do
  @moduledoc """
  Who is on the other end of a connection, and what they may do.

  A principal is built once, when a connection authenticates, and then carried
  for the life of that connection. Grants are resolved from the role at that
  moment and frozen into a `MapSet`, which makes every subsequent check a
  constant-time membership test rather than a database round-trip on the
  request path.

  ## The consequence of freezing

  Changing an account's role does not affect connections that are already open.
  This is a deliberate trade and it is the same one OPC UA makes for a Session.
  The alternative — re-reading the role per request — puts the credential
  database on the hot path of a system that is also trying to hold a 1 kHz
  control loop, and it still would not be synchronous, only differently racy.

  What it means operationally is that demoting or disabling an account must
  also drop that account's open connections, or the demotion does not take
  effect until the operator reconnects. `ExAuth.revoke_sessions/1` is the hook
  for that; anything that changes a role is responsible for calling it.
  """

  alias ExAuth.{Grant, Role}

  @enforce_keys [:account_id, :username, :role, :grants]
  defstruct [
    :account_id,
    :username,
    :role,
    :grants,
    :token_id,
    :authenticated_at
  ]

  @type t :: %__MODULE__{
          account_id: integer(),
          username: String.t(),
          role: Role.t(),
          grants: MapSet.t(Grant.t()),
          token_id: integer() | nil,
          authenticated_at: DateTime.t() | nil
        }

  @doc """
  Builds a principal for an authenticated account.
  """
  @spec new(map(), keyword()) :: t()
  def new(account, opts \\ []) do
    %__MODULE__{
      account_id: account.id,
      username: account.username,
      role: account.role,
      grants: Role.grants(account.role),
      token_id: Keyword.get(opts, :token_id),
      authenticated_at: Keyword.get(opts, :authenticated_at, DateTime.utc_now())
    }
  end

  @doc """
  Whether this principal holds `grant`.

  The only authorisation question the rest of the system should ever ask. Note
  that it takes a grant, not a role — code that branches on a role name has
  hard-coded a policy decision that belongs in `ExAuth.Role`.
  """
  @spec can?(t(), Grant.t()) :: boolean()
  def can?(%__MODULE__{grants: grants}, grant), do: MapSet.member?(grants, grant)

  @doc """
  Same question, as a `with`-friendly result.
  """
  @spec authorize(t(), Grant.t()) :: :ok | {:error, {:forbidden, Grant.t()}}
  def authorize(%__MODULE__{} = principal, grant) do
    if can?(principal, grant), do: :ok, else: {:error, {:forbidden, grant}}
  end

  @doc """
  A description safe to write into a log or an audit record.

  Deliberately carries no token material and no hash — an audit log that leaks
  credentials is worse than no audit log, because it is also durable.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{username: username, role: role, token_id: nil}) do
    "#{username} (#{role}, password)"
  end

  def describe(%__MODULE__{username: username, role: role, token_id: token_id}) do
    "#{username} (#{role}, token ##{token_id})"
  end
end
