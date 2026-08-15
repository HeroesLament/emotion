defmodule ExProto.Source do
  @moduledoc """
  Where node values actually come from.

  The protocol layer knows what nodes exist, what they are called, what type
  they are and whether they may be written — all of that comes from the
  Information Model. What it deliberately does not know is what any of them
  currently *is*. That is this behaviour's job, and keeping it behind one is
  what lets the whole node surface be tested with no drives, no CAN bus and no
  processes.

  A source is a module plus an opaque term, so an implementation can be a bare
  map in a test and a registry of running drives in production without the
  dispatcher noticing.

  ## Errors are the protocol's vocabulary, not the source's

  An implementation returns one of a fixed set of reasons, and the dispatcher
  maps them onto the error codes in the generated OpenRPC document. That means
  a source cannot invent a failure mode the protocol has no way to express — if
  a new one is needed, it gets added here and to the document together, rather
  than leaking through as an opaque term a client cannot act on.
  """

  @type node_id :: String.t()
  @type value :: term()

  @typedoc """
  Why a read or write failed.

    * `:unknown_node` — no such node in this source
    * `:not_readable` / `:not_writable` — the node exists but not for this
    * `:rejected` — the controller refused in its current state, e.g. a write
      to an axis that is not enabled
  """
  @type reason :: :unknown_node | :not_readable | :not_writable | :rejected

  @doc "Reads one node's current value."
  @callback read(node_id(), term()) :: {:ok, value()} | {:error, reason()}

  @doc """
  Writes one node.

  Returns the term the source considers the node to hold afterwards, which is
  not necessarily what was asked for — a drive may clamp a target to a joint
  limit, and a client that is told what it asked for rather than what happened
  will draw the wrong thing.
  """
  @callback write(node_id(), value(), term()) :: {:ok, value()} | {:error, reason()}

  @doc """
  Reads several nodes.

  Optional. The default reads them one at a time, which is correct but costs a
  round trip per node against a real transport; a source that can fetch a whole
  axis in one message should say so by implementing this.
  """
  @callback read_many([node_id()], term()) :: [{node_id(), {:ok, value()} | {:error, reason()}}]

  @optional_callbacks read_many: 2

  @doc """
  Reads several nodes through a source, using its batch path when it has one.
  """
  @spec read_many(module(), [node_id()], term()) ::
          [{node_id(), {:ok, value()} | {:error, reason()}}]
  def read_many(module, node_ids, arg) do
    if function_exported?(module, :read_many, 2) do
      module.read_many(node_ids, arg)
    else
      Enum.map(node_ids, fn id -> {id, module.read(id, arg)} end)
    end
  end
end
