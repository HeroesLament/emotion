defmodule ExOpcUA.Server.NodeManager do
  @moduledoc """
  Behaviour that backs the server's address space.

  Implement this in your application (e.g. `ExHMI.AddressSpace`) and pass
  the module as `node_manager:` to `ExOpcUA.Server.start_link/1`.

  The server calls these callbacks synchronously in the connection process,
  so implementations should be fast (ETS reads, GenServer.call with short
  timeout, etc.). Any blocking or crash here stalls/kills the client connection.

  ## Example

      defmodule MyApp.NodeManager do
        @behaviour ExOpcUA.Server.NodeManager

        @impl true
        def init_space do
          :ok
        end

        @impl true
        def handle_read(%ReadValueId{node_id: %NodeId{ns: 1, id: "J1"}}) do
          val = MyApp.State.get_joint(0)
          ExOpcUA.Codec.Types.good_data_value(ExOpcUA.Codec.Types.double_variant(val))
        end
        def handle_read(_), do: bad_data_value()

        @impl true
        def handle_write(%WriteValue{node_id: %NodeId{ns: 1, id: "Command"}, value: dv}) do
          cmd = dv.value.value
          MyApp.Commander.execute(cmd)
          0  # StatusCode Good
        end
        def handle_write(_), do: ExOpcUA.Codec.Primitives.status_bad_not_writable()

        @impl true
        def handle_browse(%BrowseDescription{node_id: node_id}) do
          ExOpcUA.Server.NodeManager.empty_browse_result()
        end
      end
  """

  alias ExOpcUA.Codec.Services.{ReadValueId, WriteValue, BrowseDescription, BrowseResult}
  alias ExOpcUA.Codec.Types.{DataValue, Variant}
  import ExOpcUA.Codec.Primitives
  import ExOpcUA.Codec.Types

  # ── Callbacks ─────────────────────────────────────────────────────────────────

  @doc """
  Called once at server start. Use to register nodes, set up ETS, etc.
  Return `:ok` or `{:error, reason}`.
  """
  @callback init_space() :: :ok | {:error, term()}

  @doc """
  Called for each `ReadValueId` in a Read request.
  Must return a `%DataValue{}`.
  """
  @callback handle_read(ReadValueId.t()) :: DataValue.t()

  @doc """
  Called for each `WriteValue` in a Write request.
  Must return a StatusCode (uint32). 0 = Good.
  """
  @callback handle_write(WriteValue.t()) :: non_neg_integer()

  @doc """
  Called for each `BrowseDescription` in a Browse request.
  Must return a `%BrowseResult{}`.
  """
  @callback handle_browse(BrowseDescription.t()) :: BrowseResult.t()

  @optional_callbacks [init_space: 0]

  # ── Helpers for implementors ──────────────────────────────────────────────────

  @doc "Returns a DataValue with status Bad_NodeIdUnknown."
  def bad_node_id_data_value do
    %DataValue{status_code: status_bad_node_id_unknown()}
  end

  @doc "Returns a DataValue with status Good and no value (used for write-only nodes)."
  def null_data_value do
    %DataValue{status_code: status_good()}
  end

  @doc "Returns an empty BrowseResult (no references)."
  def empty_browse_result do
    %BrowseResult{status_code: 0, continuation_point: nil, references: []}
  end

  @doc "Wraps a float/double in a Good DataValue."
  def double_data_value(v) do
    good_data_value(double_variant(v))
  end

  @doc "Wraps a string in a Good DataValue."
  def string_data_value(v) do
    good_data_value(string_variant(v))
  end

  @doc "Wraps a uint32 in a Good DataValue."
  def uint32_data_value(v) do
    good_data_value(uint32_variant(v))
  end
end
