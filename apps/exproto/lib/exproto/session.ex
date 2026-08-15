defmodule ExProto.Session do
  @moduledoc """
  Everything one client connection knows.

  A session is a plain struct threaded through `ExProto.Dispatch`, not a
  process. That is what makes the whole protocol testable without a socket: a
  test builds a session, hands it a decoded request, and gets back a response
  and a new session, with nothing running in the background and no timing to
  get wrong.

  When the transport arrives it will own one of these per connection, and the
  dispatcher will not change.

  ## What lives here and what doesn't

  The node table and the value source live here because they are constant for
  the connection's lifetime, and passing them separately through every call
  would be five arguments pretending to be one.

  Subscription *delivery* does not live here. A session records what a client
  subscribed to; something with a clock decides when to send. Keeping the timer
  out of the session is the same rule the drives follow — see `Exdrive.Drive`
  on why a simulator that owns its own clock cannot be stepped.
  """

  alias ExMo.Projection.JSONRPC.OpenRPC

  @max_subscriptions 32

  defstruct [
    :table,
    :source,
    :principal,
    initialized?: false,
    protocol_version: nil,
    client_info: nil,
    client_capabilities: %{},
    subscriptions: %{},
    next_subscription: 1
  ]

  @type t :: %__MODULE__{
          table: map(),
          source: {module(), term()},
          principal: ExAuth.Principal.t() | nil,
          initialized?: boolean(),
          protocol_version: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map(),
          subscriptions: %{String.t() => map()},
          next_subscription: pos_integer()
        }

  @doc """
  A fresh session for one connection.

  `:table` is the projected node table; `:source` is `{module, arg}` for
  reading and writing values; `:principal` is who authenticated.

  The principal is required rather than optional. A session with no principal
  would be a session that can be constructed by forgetting an argument, and the
  thing it would then permit is everything — so the absence of a credential has
  to be spelled out as `ExAuth.Principal` never being nil in normal operation.
  Tests that genuinely want an unauthenticated session pass one explicitly.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      table: Keyword.fetch!(opts, :table),
      source: Keyword.fetch!(opts, :source),
      principal: Keyword.fetch!(opts, :principal)
    }
  end

  @doc """
  Whether this session's principal holds `grant`.

  The single authorisation question the protocol layer asks. Sessions with no
  principal answer `false` to everything rather than raising: a bug that
  produces an unauthenticated session should fail closed and be visible as a
  refusal, not crash a connection in a way that looks like a network fault.
  """
  @spec can?(t(), atom()) :: boolean()
  def can?(%__MODULE__{principal: nil}, _grant), do: false
  def can?(%__MODULE__{principal: principal}, grant), do: ExAuth.can?(principal, grant)

  @doc "The protocol revision this build speaks."
  @spec protocol_version() :: String.t()
  defdelegate protocol_version, to: OpenRPC

  @doc "How many subscriptions one connection may hold."
  @spec max_subscriptions() :: pos_integer()
  def max_subscriptions, do: @max_subscriptions

  @doc """
  Marks the session initialized with the negotiated version and client details.
  """
  @spec initialize(t(), String.t(), map(), map()) :: t()
  def initialize(session, version, client_info, capabilities) do
    %{
      session
      | initialized?: true,
        protocol_version: version,
        client_info: client_info,
        client_capabilities: capabilities || %{}
    }
  end

  @doc """
  Records a subscription and returns its id.

  Ids are per-session sequential rather than random. A client only ever sees
  its own, they read clearly in a log, and there is nothing to collide with
  because a session is one connection.
  """
  @spec subscribe(t(), [String.t()], number()) :: {:ok, String.t(), t()} | {:error, :too_many}
  def subscribe(session, node_ids, rate_hz) do
    if map_size(session.subscriptions) >= @max_subscriptions do
      {:error, :too_many}
    else
      id = "sub_#{session.next_subscription}"

      subscription = %{
        id: id,
        node_ids: node_ids,
        rate_hz: rate_hz,
        # Monotonic per subscription, and it SKIPS: a gap means values were
        # conflated away between ticks, which is expected and must never be
        # treated as a resync trigger.
        seq: 0
      }

      {:ok, id,
       %{
         session
         | subscriptions: Map.put(session.subscriptions, id, subscription),
           next_subscription: session.next_subscription + 1
       }}
    end
  end

  @doc """
  Removes a subscription.

  Idempotent by design: a client tearing down after a reconnect should not have
  to reason about whether the controller already dropped it, so removing one
  that was never there succeeds.
  """
  @spec unsubscribe(t(), String.t()) :: t()
  def unsubscribe(session, id) do
    %{session | subscriptions: Map.delete(session.subscriptions, id)}
  end

  @doc "Looks a node up in the session's table."
  @spec fetch_node(t(), String.t()) :: {:ok, map()} | :error
  def fetch_node(session, node_id), do: Map.fetch(session.table.nodes, node_id)
end
