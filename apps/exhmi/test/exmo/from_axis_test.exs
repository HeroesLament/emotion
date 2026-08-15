defmodule ExMo.Schema.FromAxisTest do
  use ExUnit.Case, async: true

  alias ExMo.Schema.FromAxis
  alias ExMo.Schema.{Object, Property}

  @linear_spec %{
    id:       "axis.z",
    name:     "Z",
    type:     :linear,
    display_unit: :mm,
    limits:   {-300.0, 0.0},
    home_pos: 0.0
  }

  @rotary_spec %{
    id:    "spindle",
    name:  "Spindle",
    type:  :rotary,
    display_unit: :rpm,
    limits: {0.0, 3000.0}
  }

  describe "the display hint is not the wire unit" do
    test "a millimetre preference does not make the value millimetres" do
      obj =
        ExMo.Schema.FromAxis.to_object(%{
          id: "axis.z",
          name: "Z",
          type: :linear,
          display_unit: :mm
        })

      pos = Enum.find(obj.children, &(&1.name == "Position"))

      # Two facts, deliberately apart. Collapsing them is how a factor of a
      # thousand ships to a machine that then moves a thousand times too far.
      assert pos.unit == "m"
      assert pos.meta.display_unit == :mm
    end

    test "no preference means no hint, rather than a default one" do
      obj = ExMo.Schema.FromAxis.to_object(%{id: "axis.z", name: "Z", type: :linear})
      pos = Enum.find(obj.children, &(&1.name == "Position"))

      assert pos.unit == "m"
      refute Map.has_key?(pos.meta, :display_unit)
    end
  end

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

    test "the SI unit appears in the Position description", %{obj: obj} do
      pos = Enum.find(obj.children, & &1.name == "Position")
      # Metres, not millimetres — the description states what is on the wire.
      assert pos.description =~ "(m)"
      assert pos.unit == "m"
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

    test "Direction is observable and read-only", %{obj: obj} do
      dir = Enum.find(obj.children, & &1.name == "Direction")

      assert dir.observable == true

      # Was writable until a source had to implement it. Direction is derived
      # from the sign of the measured velocity — there is no CiA 402 object to
      # write it to, and a drive asked to "be clockwise" has been asked
      # nothing. Motion is commanded through TargetPosition or a velocity
      # setpoint; this reports which way the axis is going.
      assert dir.writable == false
      assert is_nil(dir.write_grant)
    end

    test "the SI unit appears in the Velocity description", %{obj: obj} do
      vel = Enum.find(obj.children, & &1.name == "Velocity")
      # Radians per second. RPM is a thing a human is shown, not a thing the
      # model carries.
      assert vel.description =~ "rad/s"
      assert vel.unit == "rad/s"
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
      assert obj.description =~ "metres"
    end
  end
end
