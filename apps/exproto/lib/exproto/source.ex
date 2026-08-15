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
    * `:not_callable` — the node exists but this source has no command for it
  """
  @type reason ::
          :unknown_node | :not_readable | :not_writable | :not_callable | :rejected

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

  @doc """
  Invokes a method node.

  Optional: a source with no commands does not implement it, and the dispatcher
  answers `:not_callable` for every method rather than crashing.

  ## Acceptance, not completion

  Every axis command in the model is asynchronous, and this returns when the
  command has been *accepted*, not when the machine has finished doing it. A
  CiA 402 enable is three control words through a state machine that may refuse
  them; homing takes as long as it takes. The outcome is observed on the axis's
  `state`, which is subscribable, rather than reported here — a call that
  blocked until the drive agreed would be describing a machine that had not
  finished moving.

  `{:error, :rejected}` therefore means the command could not even be started,
  not that it failed.
  """
  @callback call(node_id(), args :: map(), term()) :: :ok | {:error, reason()}

  @optional_callbacks read_many: 2, call: 3

  @doc """
  Invokes a method through a source, or reports that it has none.
  """
  @spec call(module(), node_id(), map(), term()) :: :ok | {:error, reason()}
  def call(module, node_id, args, arg) do
    if exports?(module, :call, 3) do
      module.call(node_id, args, arg)
    else
      {:error, :not_callable}
    end
  end

  @doc """
  Reads several nodes through a source, using its batch path when it has one.
  """
  @spec read_many(module(), [node_id()], term()) ::
          [{node_id(), {:ok, value()} | {:error, reason()}}]
  def read_many(module, node_ids, arg) do
    if exports?(module, :read_many, 2) do
      module.read_many(node_ids, arg)
    else
      Enum.map(node_ids, fn id -> {id, module.read(id, arg)} end)
    end
  end

  # `function_exported?/3` answers for modules that are *loaded*, and the BEAM
  # loads lazily: a source module nobody has called yet is on disk and not in
  # memory, so asking about it returns false and the optional callback it does
  # implement looks absent.
  #
  # This is not theoretical. It cost a controller its first jog: the axis was
  # enabled, the model declared the command, the source implemented it, and the
  # first client to call one before reading anything was told the controller had
  # no command bound to that node. Reading a value first "fixed" it, which is
  # the shape of bug that gets diagnosed as a network fault.
  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
