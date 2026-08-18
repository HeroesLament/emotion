defmodule ExStore.PointsTest do
  use ExStore.DataCase

  alias ExStore.{Frames, Points, Robots, Tools}

  @moduledoc """
  A taught point stores everything needed to send the arm back.

  The tests worth their space are the refusals, because each one is a failure
  that would otherwise be discovered by the arm: a joint vector from a
  different mechanism, a frame deleted out from under a point, a tool deleted
  along with the evidence of what was fitted.
  """

  @joints [
    %{name: "j_a", lower: -3.0, upper: 3.0, max_vel: 1.0},
    %{name: "j_b", lower: -3.0, upper: 3.0, max_vel: 1.0},
    %{name: "j_c", lower: -3.0, upper: 3.0, max_vel: 1.0}
  ]

  setup do
    {:ok, robot} =
      Robots.store(%{
        name: "arm#{System.unique_integer([:positive])}",
        urdf: "<robot name=\"arm\"/>",
        joints: @joints
      })

    %{robot: robot}
  end

  defp point_fixture(robot, attrs \\ %{}) do
    {:ok, point} =
      attrs
      |> Enum.into(%{
        name: "p#{System.unique_integer([:positive])}",
        robot_id: robot.id,
        joints: [0.1, 0.2, 0.3]
      })
      |> Points.teach()

    point
  end

  describe "teaching" do
    test "stores the pose, the joint solution, and what was fitted", %{robot: robot} do
      {:ok, frame} = Frames.create(%{name: "fixture", x: 0.4})
      {:ok, gripper} = Tools.create(%{name: "gripper", z: 0.15})

      {:ok, _point} =
        Points.teach(%{
          name: "approach",
          robot_id: robot.id,
          frame_id: frame.id,
          tool_id: gripper.id,
          x: 0.1,
          y: 0.2,
          z: 0.3,
          joints: [0.5, -0.5, 1.0]
        })

      stored = Points.by_name("approach")
      assert stored.x == 0.1
      assert stored.frame_id == frame.id
      assert stored.tool_id == gripper.id
      assert ExStore.Cell.Point.joints(stored) == [0.5, -0.5, 1.0]
    end

    test "a bare flange is recorded as one rather than as an absence", %{robot: robot} do
      point = point_fixture(robot)
      assert point.tool_id == nil
    end

    test "re-teaching the same name moves the point", %{robot: robot} do
      point_fixture(robot, %{name: "approach", x: 0.1})
      {:ok, _} = Points.teach(%{name: "approach", robot_id: robot.id, x: 0.9, joints: [0.0, 0.0, 0.0]})

      assert length(Points.list()) == 1
      assert Points.by_name("approach").x == 0.9
    end

    test "a point with no joint solution is refused", %{robot: robot} do
      # Not an optimisation to store it. A pose reachable two ways, replayed
      # without knowing which way it was taught, is the flip that ABB's
      # confdata exists to prevent.
      assert {:error, changeset} = Points.teach(%{name: "nowhere", robot_id: robot.id})
      assert changeset.errors[:joints]
    end

    test "a joint vector from a different arm is refused", %{robot: robot} do
      assert {:error, changeset} =
               Points.teach(%{name: "wrong", robot_id: robot.id, joints: [0.0, 0.0, 0.0, 0.0]})

      assert [message] = errors_on(changeset).joints
      assert message =~ "4 positions"
      assert message =~ "3 joints"
    end

    test "a point with no robot at all is refused", %{robot: _robot} do
      assert {:error, _} = Points.teach(%{name: "orphan", joints: [0.0, 0.0, 0.0]})
    end

    test "names that would read as something else in a program are refused", %{robot: robot} do
      for name <- ~w(base tool here home) do
        assert {:error, _} = Points.teach(%{name: name, robot_id: robot.id, joints: [0.0, 0.0, 0.0]}),
               "expected #{name} to be refused"
      end
    end
  end

  describe "what a point holds onto" do
    test "its frame cannot be deleted while it exists", %{robot: robot} do
      {:ok, frame} = Frames.create(%{name: "fixture"})
      point_fixture(robot, %{frame_id: frame.id})

      assert {:error, changeset} = Frames.delete(frame)
      assert [message] = errors_on(changeset).id
      assert message =~ "points taught in it"
      assert Frames.by_name("fixture")
    end

    test "nor can the tool that was fitted", %{robot: robot} do
      {:ok, gripper} = Tools.create(%{name: "gripper", z: 0.15})
      point_fixture(robot, %{tool_id: gripper.id})

      assert {:error, _} = Tools.delete(gripper)
      assert Tools.by_name("gripper")
    end

    test "a frame with no points is still deletable", %{robot: _robot} do
      {:ok, frame} = Frames.create(%{name: "unused"})
      assert {:ok, _} = Frames.delete(frame)
    end

    test "in_frame lists exactly what a re-teach would move", %{robot: robot} do
      {:ok, fixture} = Frames.create(%{name: "fixture"})
      {:ok, other} = Frames.create(%{name: "elsewhere"})

      a = point_fixture(robot, %{frame_id: fixture.id})
      b = point_fixture(robot, %{frame_id: fixture.id})
      _c = point_fixture(robot, %{frame_id: other.id})

      moved = Points.in_frame(fixture.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert moved == Enum.sort([a.id, b.id])
    end
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
