defmodule ExProto.LazySource do
  @moduledoc """
  A source whose module a test can unload.

  It exists on disk rather than being defined inside a test file, which is the
  whole point: `:code.delete/1` on a module with no beam behind it cannot be
  undone, and what this proves is that `ExProto.Source` finds an optional
  callback on a module the VM has not loaded yet.
  """

  @behaviour ExProto.Source

  @impl true
  def read(_node_id, _arg), do: {:ok, :read}

  @impl true
  def write(_node_id, _value, _arg), do: {:error, :not_writable}

  @impl true
  def read_many(node_ids, _arg), do: Enum.map(node_ids, &{&1, {:ok, :batched}})

  @impl true
  def call(_node_id, _args, _arg), do: :ok
end
