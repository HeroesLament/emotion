defmodule ExProto.Source.Composite do
  @moduledoc """
  Routes each node to the source that owns it, by the first segment of its id.

  The endpoint takes one source, which was right while there was one kind of
  thing to serve. There are two now — drives, which change every tick, and
  stored geometry, which changes when somebody teaches it — and they fail in
  entirely different ways. Putting both behind one module would mean a `case`
  on a node id prefix in front of two unrelated implementations, which is this
  module, written once, instead of inside another one.

  Routing is by prefix and the fallback is explicit. A node whose first segment
  matches nothing is `:unknown_node` rather than quietly handed to whichever
  source happens to be first — a source answering for a node it does not own is
  how a client gets a plausible number from the wrong subsystem.
  """

  @behaviour ExProto.Source

  alias ExProto.Source

  @typedoc "First segment of a node id, e.g. `\"axes\"`, to the source that owns it."
  @type routes :: %{optional(String.t()) => {module(), term()}}

  @impl ExProto.Source
  def read(node_id, routes) do
    with {:ok, module, arg} <- route(node_id, routes), do: module.read(node_id, arg)
  end

  @impl ExProto.Source
  def write(node_id, value, routes) do
    with {:ok, module, arg} <- route(node_id, routes), do: module.write(node_id, value, arg)
  end

  @impl ExProto.Source
  def call(node_id, args, routes) do
    with {:ok, module, arg} <- route(node_id, routes) do
      Source.call(module, node_id, args, arg)
    end
  end

  # Grouped by owner first, so a source with a batch path still gets a batch.
  # Splitting a read of eight axis nodes into eight single reads because one
  # `cell.tool` was in the list would give away exactly what read_many exists
  # to buy.
  @impl ExProto.Source
  def read_many(node_ids, routes) do
    node_ids
    |> Enum.group_by(&segment/1)
    |> Enum.flat_map(fn {segment, ids} ->
      case Map.fetch(routes, segment) do
        {:ok, {module, arg}} -> Source.read_many(module, ids, arg)
        :error -> Enum.map(ids, &{&1, {:error, :unknown_node}})
      end
    end)
  end

  defp route(node_id, routes) do
    case Map.fetch(routes, segment(node_id)) do
      {:ok, {module, arg}} -> {:ok, module, arg}
      :error -> {:error, :unknown_node}
    end
  end

  defp segment(node_id) do
    case String.split(node_id, ".", parts: 2) do
      [segment | _rest] -> segment
      [] -> node_id
    end
  end
end
