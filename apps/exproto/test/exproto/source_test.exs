defmodule ExProto.SourceTest do
  @moduledoc """
  The behaviour's own dispatch, which is where optional callbacks are decided.
  """

  # Not async: it unloads a module, and the code server is global.
  use ExUnit.Case, async: false

  alias ExProto.{LazySource, Source}

  describe "optional callbacks on a module the VM has not loaded" do
    setup do
      # The state a freshly booted controller is actually in: the source module
      # is on disk, nothing has called it, and it is not in memory.
      # purge, delete, purge: delete only marks the current code old, and a
      # module with old code still counts as loaded.
      :code.purge(LazySource)
      :code.delete(LazySource)
      :code.purge(LazySource)
      refute :erlang.module_loaded(LazySource)
      :ok
    end

    test "call/4 finds one" do
      # `function_exported?/3` alone answers false here, and the caller would be
      # told the controller has no command bound to the node — on a source that
      # implements every command it declares. The first jog of a controller's
      # life is exactly this case.
      assert Source.call(LazySource, "axes.j1.jog", %{"velocity" => 0.1}, nil) == :ok
    end

    test "read_many/3 finds one, rather than quietly falling back" do
      # The fallback is correct but different: one round trip per node, and five
      # values from five different instants where the source would have given
      # one consistent snapshot.
      # :batched only comes from read_many/2. The per-node fallback would answer
      # :read and look just as correct.
      assert Source.read_many(LazySource, ["axes.j1.position"], nil) == [
               {"axes.j1.position", {:ok, :batched}}
             ]
    end
  end

  test "a module that genuinely has no call/3 still says so" do
    defmodule Commandless do
      @behaviour ExProto.Source
      @impl true
      def read(_id, _arg), do: {:error, :unknown_node}
      @impl true
      def write(_id, _value, _arg), do: {:error, :not_writable}
    end

    assert Source.call(Commandless, "axes.j1.jog", %{}, nil) == {:error, :not_callable}
  end
end
