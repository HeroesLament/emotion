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

    test "carries the properties its interface actually has", %{obj: obj} do
      names = Enum.map(obj.children, & &1.name)

      # Every axis, on every tier.
      assert "Position"       in names
      assert "TargetPosition" in names
      assert "State"          in names

      # This fixture is a CiA 402 axis (the default), so it also has the servo
      # detail. DriveState is gone: the neutral node is State, and the raw PDS
      # string is PdsState, published beside it rather than instead of it.
      assert "Velocity"       in names
      assert "PdsState"       in names
      assert "StatusWord"     in names
      assert "FaultCode"      in names
      refute "DriveState"     in names
    end

    test "a PWM axis is not described as a servo", %{obj: obj} do
      pwm =
        obj
        |> Map.get(:meta)
        |> then(fn _ -> ExMo.Schema.FromAxis.to_object(%{id: "p", name: "P", type: :linear, interface: :pwm}) end)

      names = Enum.map(pwm.children, & &1.name)

      # A hobby servo has no PDS state machine, no CANopen emergency code, no
      # feedback of any kind. Publishing those would describe a machine that
      # does not exist.
      refute "PdsState"   in names
      refute "StatusWord" in names
      refute "FaultCode"  in names
      refute "Velocity"   in names
      # And it cannot know it is home, so it does not claim to.
      refute "AtHome"     in names

      assert "Position" in names
      assert "State"    in names
    end

    test "position says whether it is measured or assumed" do
      servo = ExMo.Schema.FromAxis.to_object(%{id: "s", name: "S", type: :rotary})
      stepper = ExMo.Schema.FromAxis.to_object(%{id: "t", name: "T", type: :rotary, interface: :step_dir})

      servo_pos = Enum.find(servo.children, &(&1.name == "Position"))
      stepper_pos = Enum.find(stepper.children, &(&1.name == "Position"))

      assert servo_pos.meta[:feedback] == true
      assert servo_pos.description =~ "Measured"

      # The number a stepper reports is what it was told, which stops being
      # true the moment it stalls.
      assert stepper_pos.meta[:feedback] == false
      assert stepper_pos.description =~ "open loop"
    end

    test "an unknown interface is refused rather than treated as a servo" do
      assert_raise ArgumentError, ~r/unknown axis interface/, fn ->
        ExMo.Schema.FromAxis.to_object(%{id: "x", name: "X", type: :rotary, interface: :ethercat})
      end
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
