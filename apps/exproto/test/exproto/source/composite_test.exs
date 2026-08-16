defmodule ExProto.Source.CompositeTest do
  use ExUnit.Case, async: true

  alias ExProto.Source.{Composite, Static}

  @moduledoc """
  Routing by the first segment of a node id, and refusing everything else.

  The property that matters is the negative one: a node whose segment matches
  no route is unknown, rather than handed to whichever source happens to be
  first. A source answering for a node it does not own is how a client gets a
  plausible number from the wrong subsystem — which reads as a working system
  right up until somebody acts on it.
  """

  setup do
    {:ok, axes} = Static.start_link(values: %{"axes.j1.position" => 0.5, "axes.j2.position" => 1.5})
    {:ok, cell} = Static.start_link(values: %{"cell.tool" => "gripper"})

    %{routes: %{"axes" => {Static, axes}, "cell" => {Static, cell}}}
  end

  test "reads go to the source that owns the segment", %{routes: routes} do
    assert Composite.read("axes.j1.position", routes) == {:ok, 0.5}
    assert Composite.read("cell.tool", routes) == {:ok, "gripper"}
  end

  test "an unrouted segment is unknown", %{routes: routes} do
    assert Composite.read("printers.k1c_01.door_state", routes) == {:error, :unknown_node}
    assert Composite.write("printers.k1c_01.door", "open", routes) == {:error, :unknown_node}
    assert Composite.call("printers.k1c_01.open", %{}, routes) == {:error, :unknown_node}
  end

  test "a batch read is grouped by owner and answers for every node asked", %{routes: routes} do
    ids = ["axes.j1.position", "cell.tool", "axes.j2.position", "nowhere.at.all"]

    answers = Map.new(Composite.read_many(ids, routes))

    assert answers["axes.j1.position"] == {:ok, 0.5}
    assert answers["axes.j2.position"] == {:ok, 1.5}
    assert answers["cell.tool"] == {:ok, "gripper"}
    assert answers["nowhere.at.all"] == {:error, :unknown_node}
    assert map_size(answers) == 4
  end

  test "a node id with no dot in it still routes", %{routes: routes} do
    # `axes` itself is an object, and browsing asks about it.
    assert Composite.read("axes", routes) == {:error, :unknown_node}
  end
end
