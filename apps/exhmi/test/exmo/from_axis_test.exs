defmodule ExMo.Schema.FromAxisTest do
  use ExUnit.Case, async: true

  alias ExMo.Schema.FromAxis
  alias ExMo.Schema.{Object, Property}

  @linear_spec %{
    id:       "axis.z",
    name:     "Z",
    type:     :linear,
    unit:     :mm,
    limits:   {-300.0, 0.0},
    home_pos: 0.0
  }

  @rotary_spec %{
    id:    "spindle",
    name:  "Spindle",
    type:  :rotary,
    unit:  :rpm,
    limits: {0.0, 3000.0}
  }

  describe "linear axis" do
    setup do
      %{obj: FromAxis.to_object(@linear_spec)}
    end

    test "returns an Object with correct id and name", %{obj: obj} do
      assert %Object{id: "axis.z", name: "Z"} = obj
    end

    test "has all five standard properties", %{obj: obj} do
      names = Enum.map(obj.children, & &1.name)
      assert "Position"       in names
      assert "TargetPosition" in names
      assert "Velocity"       in names
      assert "DriveState"     in names
      assert "FaultCode"      in names
    end

    test "has AtHome property", %{obj: obj} do
      names = Enum.map(obj.children, & &1.name)
      assert "AtHome" in names
    end

    test "does not have Direction property", %{obj: obj} do
      names = Enum.map(obj.children, & &1.name)
      refute "Direction" in names
    end

    test "Position is observable and read-only", %{obj: obj} do
      pos = Enum.find(obj.children, & &1.name == "Position")
      assert pos.readable   == true
      assert pos.writable   == false
      assert pos.observable == true
    end

    test "TargetPosition is writable", %{obj: obj} do
      tp = Enum.find(obj.children, & &1.name == "TargetPosition")
      assert tp.writable == true
    end

    test "unit label appears in Position description", %{obj: obj} do
      pos = Enum.find(obj.children, & &1.name == "Position")
      assert pos.description =~ "mm"
    end
  end

  describe "rotary axis" do
    setup do
      %{obj: FromAxis.to_object(@rotary_spec)}
    end

    test "returns an Object with correct id and name", %{obj: obj} do
      assert %Object{id: "spindle", name: "Spindle"} = obj
    end

    test "has Direction property", %{obj: obj} do
      names = Enum.map(obj.children, & &1.name)
      assert "Direction" in names
    end

    test "does not have AtHome property", %{obj: obj} do
      names = Enum.map(obj.children, & &1.name)
      refute "AtHome" in names
    end

    test "Direction is writable and observable", %{obj: obj} do
      dir = Enum.find(obj.children, & &1.name == "Direction")
      assert dir.writable   == true
      assert dir.observable == true
    end

    test "unit label appears in Velocity description", %{obj: obj} do
      vel = Enum.find(obj.children, & &1.name == "Velocity")
      assert vel.description =~ "RPM"
    end
  end

  describe "extra properties" do
    test "are appended after standard and type-specific properties" do
      extra = %Property{
        id:   "spindle.load",
        name: "Load",
        type: :float,
        readable: true, writable: false, observable: true
      }
      obj = FromAxis.to_object(Map.put(@rotary_spec, :extra, [extra]))
      names = Enum.map(obj.children, & &1.name)
      assert "Load" in names
      assert List.last(names) == "Load"
    end
  end

  describe "custom description" do
    test "uses provided description over default" do
      obj = FromAxis.to_object(Map.put(@linear_spec, :description, "The big one"))
      assert obj.description == "The big one"
    end

    test "generates a default description when none provided" do
      obj = FromAxis.to_object(@linear_spec)
      assert obj.description =~ "Z"
      assert obj.description =~ "mm"
    end
  end
end
