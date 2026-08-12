defmodule EMotion.CellTest do
  use ExUnit.Case, async: true

  alias EMotion.Cell
  alias EMotion.Cell.Robot

  defp arm(id \\ :arm_a, joints \\ [0.0, 0.0, 0.0]) do
    %Robot{id: id, name: "Arm", joints: joints}
  end

  defp with_arm(joints \\ [0.0, 0.0, 0.0]) do
    {:ok, cell} = Cell.apply_change(Cell.new(), {:add_robot, arm(:arm_a, joints)})
    cell
  end

  describe "apply_change/2" do
    test "bumps the version, so a subscriber can tell replicas apart" do
      cell = Cell.new()
      {:ok, updated} = Cell.apply_change(cell, {:rename, "Weld cell 1"})

      assert updated.version == cell.version + 1
      assert updated.name == "Weld cell 1"
    end

    test "adds and removes robots" do
      {:ok, cell} = Cell.apply_change(Cell.new(), {:add_robot, arm()})
      assert {:ok, %Robot{id: :arm_a}} = Cell.robot(cell, :arm_a)

      {:ok, cell} = Cell.apply_change(cell, {:remove_robot, :arm_a})
      assert Cell.robot(cell, :arm_a) == :error
    end

    test "gives a robot the origin when it arrives without a base" do
      {:ok, cell} = Cell.apply_change(Cell.new(), {:add_robot, arm()})
      {:ok, robot} = Cell.robot(cell, :arm_a)

      assert robot.base == Cell.origin()
    end

    test "refuses a duplicate robot rather than replacing one" do
      {:ok, cell} = Cell.apply_change(Cell.new(), {:add_robot, arm()})

      assert {:error, {:duplicate_robot, :arm_a}} =
               Cell.apply_change(cell, {:add_robot, arm()})
    end

    test "refuses to move a robot that is not here" do
      assert {:error, {:no_such_robot, :ghost}} =
               Cell.apply_change(Cell.new(), {:set_joints, :ghost, [0.0]})
    end

    test "refuses a pose with the wrong number of joints" do
      # The one that matters. A joint list of the wrong length reaching
      # forward kinematics produces a plausible wrong answer rather than an
      # error, and a plausible wrong answer moves a real arm.
      cell = with_arm([0.0, 0.0, 0.0])

      assert {:error, {:wrong_joint_count, :arm_a, 3, 2}} =
               Cell.apply_change(cell, {:set_joints, :arm_a, [0.1, 0.2]})
    end

    test "refuses joint values that are not numbers" do
      cell = with_arm()

      assert {:error, {:not_numbers, :arm_a}} =
               Cell.apply_change(cell, {:set_joints, :arm_a, [0.1, :nan, 0.3]})
    end

    test "normalises joint values to floats" do
      # Integers arrive from parsed text and from URDF defaults; letting them
      # through means a pose that compares unequal to itself after a round
      # trip through a float.
      cell = with_arm()
      {:ok, cell} = Cell.apply_change(cell, {:set_joints, :arm_a, [0, 1, 2]})
      {:ok, robot} = Cell.robot(cell, :arm_a)

      assert robot.joints == [0.0, 1.0, 2.0]
    end

    test "puts and removes frames" do
      {:ok, cell} = Cell.apply_change(Cell.new(), {:put_frame, :workobject, Cell.origin()})
      assert Map.has_key?(cell.frames, :workobject)

      {:ok, cell} = Cell.apply_change(cell, {:remove_frame, :workobject})
      refute Map.has_key?(cell.frames, :workobject)
    end

    test "an unknown change is refused rather than ignored" do
      # Silently ignoring would let a workbench built against a newer studio
      # appear to work while doing nothing.
      assert {:error, {:unknown_change, {:teleport, :arm_a}}} =
               Cell.apply_change(Cell.new(), {:teleport, :arm_a})
    end
  end

  describe "apply_changes/2" do
    test "applies in order" do
      {:ok, cell} =
        Cell.apply_changes(Cell.new(), [
          {:rename, "Cell"},
          {:add_robot, arm()},
          {:set_joints, :arm_a, [0.1, 0.2, 0.3]}
        ])

      {:ok, robot} = Cell.robot(cell, :arm_a)

      assert cell.name == "Cell"
      assert robot.joints == [0.1, 0.2, 0.3]
      assert cell.version == 3
    end

    test "is all or nothing" do
      # A workbench returning three related edits must not leave the document
      # half-changed when the second is rejected.
      cell = with_arm()

      assert {:error, {:no_such_robot, :ghost}} =
               Cell.apply_changes(cell, [
                 {:rename, "Renamed"},
                 {:set_joints, :ghost, [0.0]},
                 {:rename, "Also renamed"}
               ])

      assert cell.name == "Untitled cell"
    end

    test "an empty list is a no-op" do
      cell = Cell.new()
      assert {:ok, ^cell} = Cell.apply_changes(cell, [])
    end
  end

  describe "reading" do
    test "robots come back in a stable order" do
      {:ok, cell} =
        Cell.apply_changes(Cell.new(), [
          {:add_robot, arm(:arm_c)},
          {:add_robot, arm(:arm_a)},
          {:add_robot, arm(:arm_b)}
        ])

      assert Enum.map(Cell.robots(cell), & &1.id) == [:arm_a, :arm_b, :arm_c]
    end
  end

  describe "units" do
    test "poses are canonical, so ExMove needs no conversion" do
      cell = with_arm([0.0, 0.0, 0.0])

      {:ok, cell} =
        Cell.apply_change(cell, {:set_joints, :arm_a, [EMotion.Units.deg(90), 0.0, 0.0]})

      {:ok, robot} = Cell.robot(cell, :arm_a)

      assert_in_delta hd(robot.joints), :math.pi() / 2, 1.0e-9
    end
  end
end
