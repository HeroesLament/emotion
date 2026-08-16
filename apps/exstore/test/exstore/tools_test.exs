defmodule ExStore.ToolsTest do
  use ExStore.DataCase

  alias ExStore.Tools

  test "a tool is six numbers and a name" do
    {:ok, tool} = Tools.create(%{name: "gripper", z: 0.15})
    assert tool.z == 0.15
    refute tool.fitted
  end

  test "nothing is fitted until something is" do
    tool_fixture(%{name: "gripper"})
    refute Tools.fitted()
  end

  test "fitting a tool unfits whatever was on the flange" do
    gripper = tool_fixture(%{name: "gripper", z: 0.15})
    welder = tool_fixture(%{name: "welder", z: 0.30})

    {:ok, _} = Tools.fit(gripper)
    assert Tools.fitted().name == "gripper"

    {:ok, _} = Tools.fit(welder)
    assert Tools.fitted().name == "welder"
    refute Tools.get(gripper.id).fitted
  end

  test "fitting by name, which is what a pendant has" do
    tool_fixture(%{name: "gripper"})
    assert {:ok, %{name: "gripper"}} = Tools.fit("gripper")
    assert {:error, :unknown_tool} = Tools.fit("the_one_in_the_drawer")
  end

  test "a bare flange is a state, not a missing answer" do
    gripper = tool_fixture()
    {:ok, _} = Tools.fit(gripper)

    assert {:ok, 1} = Tools.unfit()
    refute Tools.fitted()
  end

  test "the database refuses two tools fitted at once" do
    # Not the context function — this asserts the constraint rather than the
    # code that is careful to respect it. A future importer will not be.
    a = tool_fixture()
    b = tool_fixture()
    {:ok, _} = Tools.fit(a)

    assert {:error, _} = Repo.update(ExStore.Geometry.Tool.fit_changeset(b, true))
  end

  test "names are unique and the reserved ones are refused" do
    tool_fixture(%{name: "gripper"})
    assert {:error, _} = Tools.create(%{name: "gripper"})
    assert {:error, _} = Tools.create(%{name: "none"})
  end
end
