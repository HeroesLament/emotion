defmodule ExStore.RobotsTest do
  use ExStore.DataCase

  alias ExStore.Cell.Robot
  alias ExStore.Robots

  @moduledoc """
  Storing a mechanism, and commissioning it separately.

  The claims worth making here are the two refusals — a commissioning row for a
  joint that does not exist, and a soft limit outside the metal — plus the one
  that makes the split worth having at all: re-storing a re-exported drawing
  keeps the wiring.
  """

  @joints [
    %{name: "shoulder", lower: -3.0, upper: 3.0, max_vel: 1.0},
    %{name: "elbow", lower: -2.0, upper: 2.0, max_vel: 1.5},
    %{name: "wrist_1", lower: nil, upper: nil, max_vel: nil}
  ]

  defp robot_fixture(attrs \\ %{}) do
    {:ok, robot} =
      attrs
      |> Enum.into(%{
        name: "arm#{System.unique_integer([:positive])}",
        urdf: "<robot name=\"arm\"/>",
        joints: @joints
      })
      |> Robots.store()

    robot
  end

  describe "storing" do
    test "keeps the document byte for byte" do
      urdf = "<?xml version=\"1.0\"?>\n<robot name=\"arm\">\n  <!-- a comment -->\n</robot>\n"
      robot = robot_fixture(%{urdf: urdf})

      assert Robots.by_name(robot.name).urdf == urdf
    end

    test "and a summary of what the document said" do
      robot = robot_fixture()
      stored = Robots.by_name(robot.name)

      assert Robot.joint_names(stored) == ~w(shoulder elbow wrist_1)
      assert Robot.travel(stored, "elbow") == {-2.0, 2.0}
      # A continuous joint has no travel, and nil is how the suite says so.
      assert Robot.travel(stored, "wrist_1") == nil
    end

    test "re-storing replaces the document rather than making a second robot" do
      robot = robot_fixture(%{name: "arctos"})
      {:ok, _} = Robots.store(%{name: "arctos", urdf: "<robot name=\"v2\"/>", joints: @joints})

      assert length(Robots.list()) == 1
      assert Robots.by_name("arctos").urdf == "<robot name=\"v2\"/>"
      assert Robots.by_name("arctos").id == robot.id
    end
  end

  describe "which robot this controller is" do
    test "none, until somebody says" do
      robot_fixture()
      refute Robots.active()
    end

    test "loading one unloads the other" do
      a = robot_fixture()
      b = robot_fixture()

      {:ok, _} = Robots.activate(a)
      assert Robots.active().id == a.id

      {:ok, _} = Robots.activate(b)
      assert Robots.active().id == b.id
    end

    test "a name that is not there is refused" do
      assert {:error, :unknown_robot} = Robots.activate("the_one_in_the_catalogue")
    end
  end

  describe "commissioning" do
    test "records what the drawing does not know" do
      robot = robot_fixture()

      assert {:ok, setting} =
               Robots.commission(robot, "shoulder", %{
                 axis_id: "j1",
                 max_vel: 0.8,
                 soft_lower: -2.5,
                 soft_upper: 2.5,
                 home: 0.0
               })

      assert setting.axis_id == "j1"
      assert setting.max_vel == 0.8
    end

    test "twice is a correction, not a second row" do
      robot = robot_fixture()
      {:ok, _} = Robots.commission(robot, "shoulder", %{axis_id: "j1", max_vel: 0.8})
      {:ok, _} = Robots.commission(robot, "shoulder", %{axis_id: "j1", max_vel: 0.9})

      assert length(Robots.settings(robot)) == 1
      assert Robots.setting(robot, "shoulder").max_vel == 0.9
    end

    test "a joint the robot does not have is refused, and it says what it does have" do
      # The failure this catches: a re-exported drawing with a joint renamed,
      # which otherwise leaves a commissioning row pointing at nothing and an
      # axis with no limits at all.
      robot = robot_fixture()

      assert {:error, changeset} = Robots.commission(robot, "shoulder_pan", %{axis_id: "j1"})
      assert [message] = errors_on(changeset).joint_name
      assert message =~ "shoulder, elbow, wrist_1"
    end

    test "a soft limit outside the mechanical travel is refused" do
      robot = robot_fixture()

      assert {:error, changeset} = Robots.commission(robot, "elbow", %{soft_upper: 2.5})
      assert [message] = errors_on(changeset).soft_upper
      assert message =~ "-2.0..2.0"
    end

    test "a soft limit inside it is fine, which is the whole point of having one" do
      robot = robot_fixture()
      assert {:ok, _} = Robots.commission(robot, "elbow", %{soft_lower: -1.0, soft_upper: 1.0})
    end

    test "a continuous joint takes a soft limit, having nothing else to stop it" do
      robot = robot_fixture()
      assert {:ok, _} = Robots.commission(robot, "wrist_1", %{soft_lower: -6.0, soft_upper: 6.0})
    end

    test "a soft limit the wrong way round is refused" do
      robot = robot_fixture()
      assert {:error, _} = Robots.commission(robot, "elbow", %{soft_lower: 1.0, soft_upper: -1.0})
    end

    test "a velocity of zero is refused rather than stored as a stopped axis" do
      robot = robot_fixture()
      assert {:error, _} = Robots.commission(robot, "elbow", %{max_vel: 0.0})
    end

    test "two joints on one drive is refused" do
      robot = robot_fixture()
      {:ok, _} = Robots.commission(robot, "shoulder", %{axis_id: "j1"})

      assert {:error, _} = Robots.commission(robot, "elbow", %{axis_id: "j1"})
    end
  end

  describe "the wiring" do
    test "is in chain order, with a hole where nobody has wired one" do
      robot = robot_fixture()
      {:ok, _} = Robots.commission(robot, "wrist_1", %{axis_id: "j3"})
      {:ok, _} = Robots.commission(robot, "shoulder", %{axis_id: "j1"})

      # Always as long as the chain: a shorter list would line up wrongly
      # against the joints and put the wrong number on the wrong axis.
      assert Robots.axis_ids(robot) == [:j1, nil, :j3]
    end

    test "survives re-storing the drawing" do
      # The reason the two tables exist. Re-exporting a CAD file must not lose
      # which drive is joint 3.
      robot = robot_fixture(%{name: "arctos"})
      {:ok, _} = Robots.commission(robot, "shoulder", %{axis_id: "j1", max_vel: 0.8})

      {:ok, restored} =
        Robots.store(%{name: "arctos", urdf: "<robot name=\"arctos-v2\"/>", joints: @joints})

      assert Robots.setting(restored, "shoulder").axis_id == "j1"
      assert Robots.setting(restored, "shoulder").max_vel == 0.8
    end

    test "and is deleted with the robot, rather than left pointing at nothing" do
      robot = robot_fixture()
      {:ok, _} = Robots.commission(robot, "shoulder", %{axis_id: "j1"})

      {:ok, _} = Robots.delete(robot)

      assert Repo.aggregate(ExStore.Cell.JointSetting, :count) == 0
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
