defmodule EMotion.ControllerTest do
  use ExUnit.Case, async: true

  # Define a test controller inline — this is exactly what user callsites look like
  defmodule TestLathe do
    use EMotion.Controller

    axis :z,       type: :linear, unit: :mm,  limits: {-300.0, 0.0}, home_pos: 0.0
    axis :spindle, type: :rotary, unit: :rpm,  limits: {0.0, 3000.0}

    behaviors [SomeBehavior, AnotherBehavior]
  end

  describe "__axes__/0" do
    test "returns one spec per declared axis" do
      assert length(TestLathe.__axes__()) == 2
    end

    test "axis specs have id, name, type, unit" do
      [z, spindle] = TestLathe.__axes__()

      assert z[:type] == :linear
      assert z[:unit] == :mm
      assert z[:name] == "Z"
      assert is_binary(z[:id])

      assert spindle[:type] == :rotary
      assert spindle[:unit] == :rpm
      assert spindle[:name] == "Spindle"
    end

    test "axis ids are unique" do
      ids = TestLathe.__axes__() |> Enum.map(& &1[:id])
      assert ids == Enum.uniq(ids)
    end

    test "preserves declaration order" do
      [first, second] = TestLathe.__axes__()
      assert first[:name]  == "Z"
      assert second[:name] == "Spindle"
    end
  end

  describe "__behaviors__/0" do
    test "returns declared behavior modules" do
      assert TestLathe.__behaviors__() == [SomeBehavior, AnotherBehavior]
    end
  end

  describe "axes_fragment/0" do
    setup do
      %{fragment: TestLathe.axes_fragment()}
    end

    test "returns an Object named Axes", %{fragment: f} do
      assert f.name == "Axes"
      assert f.id   == "axes"
    end

    test "has one child object per axis", %{fragment: f} do
      assert length(f.children) == 2
    end

    test "child names match axis names", %{fragment: f} do
      names = Enum.map(f.children, & &1.name)
      assert "Z"       in names
      assert "Spindle" in names
    end

    test "linear axis child has AtHome property", %{fragment: f} do
      z = Enum.find(f.children, & &1.name == "Z")
      prop_names = Enum.map(z.children, & &1.name)
      assert "AtHome" in prop_names
    end

    test "rotary axis child has Direction property", %{fragment: f} do
      spindle = Enum.find(f.children, & &1.name == "Spindle")
      prop_names = Enum.map(spindle.children, & &1.name)
      assert "Direction" in prop_names
    end
  end

  describe "behaviors/0" do
    test "returns the declared behavior modules" do
      assert TestLathe.behaviors() == [SomeBehavior, AnotherBehavior]
    end
  end

  describe "controller with no behaviors declared" do
    defmodule BehaviorlessMachine do
      use EMotion.Controller
      axis :x, type: :linear, unit: :mm
    end

    test "behaviors/0 returns empty list" do
      assert BehaviorlessMachine.behaviors() == []
    end

    test "axes_fragment/0 still works" do
      f = BehaviorlessMachine.axes_fragment()
      assert length(f.children) == 1
    end
  end
end
