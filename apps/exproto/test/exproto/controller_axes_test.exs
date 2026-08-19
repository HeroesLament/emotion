defmodule ExProto.ControllerAxesTest do
  @moduledoc """
  What counts as an axis.

  `ExProto.Controller.axes/1` decides which nodes get a drive process started
  for them, so a wrong answer here is not cosmetic: it starts drives that map to
  no hardware, and `EMotion.Drive` then has to resolve an axis id that names
  nothing.
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, table} = ExProto.Controller.node_table()
    %{table: table}
  end

  test "the six joints are axes", %{table: table} do
    axes = ExProto.Controller.axes(table)
    for j <- ~w(j1 j2 j3 j4 j5 j6), do: assert(j in axes, "expected #{j} in #{inspect(axes)}")
  end

  test "tcp is not an axis", %{table: table} do
    # axes.tcp carries a pose — x, y, z, rx, ry, rz. It is where the tool is,
    # not a thing that can be commanded to a position.
    refute "tcp" in ExProto.Controller.axes(table)
  end

  test "cartesian is not an axis", %{table: table} do
    # axes.cartesian carries stream state — manipulability, speed_fraction,
    # reason. Starting a drive called "cartesian" is how this was found: the
    # id names no atom, so resolving it raised at controller boot.
    refute "cartesian" in ExProto.Controller.axes(table)
  end

  test "nothing but the joints is an axis", %{table: table} do
    assert ExProto.Controller.axes(table) == ~w(j1 j2 j3 j4 j5 j6)
  end

  test "every reported axis resolves to a drive module without raising", %{table: table} do
    # The whole point. Before the fix this raised ArgumentError on "cartesian".
    for axis <- ExProto.Controller.axes(table) do
      assert is_atom(EMotion.Drive.for(axis))
    end
  end

  test "every reported axis has a PDS state, which is what makes it a drive", %{table: table} do
    ids = MapSet.new(ExProto.Controller.axes(table))

    have_pds =
      table
      |> EMotion.Projection.JSONRPC.filter(:property)
      |> Enum.flat_map(fn node ->
        case String.split(node.node_id, ".") do
          ["axes", axis, "pds_state"] -> [axis]
          _ -> []
        end
      end)
      |> MapSet.new()

    assert MapSet.equal?(ids, have_pds)
  end
end
