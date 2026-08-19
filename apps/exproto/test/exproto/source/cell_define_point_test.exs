defmodule ExProto.Source.CellDefinePointTest do
  @moduledoc """
  Defining a point from data rather than from where the arm is.

  The counterpart to `cell.teach_point`, and separate from it on purpose.
  Teaching means the arm was here and somebody said so; defining means a file
  said so. The refusals are where the design lives: a frame or a tool this
  cell does not have is refused rather than invented, because inventing one is
  a claim about how the cell is physically built.
  """
  use ExUnit.Case, async: false

  alias ExProto.Source.Cell, as: Source
  alias ExStore.{Frames, Points, Robots, Tools}

  setup do
    tag = System.unique_integer([:positive])

    robot =
      case Robots.active() do
        nil ->
          {:ok, fresh} =
            Robots.store(%{
              name: "bench#{tag}",
              urdf: "<robot/>",
              joints: Enum.map(1..6, &%{name: "joint#{&1}", lower: -3.05, upper: 3.05})
            })

          {:ok, active} = Robots.activate(fresh)
          active

        active ->
          active
      end

    {:ok, frame} = Frames.create(%{name: "f_t#{tag}", x: 0.2, y: 0.0, z: 0.0})
    {:ok, tool} = Tools.create(%{name: "t_t#{tag}", x: 0.0, y: 0.0, z: 0.1})

    on_exit(fn ->
      for name <- ["dp_t#{tag}", "dp2_t#{tag}"] do
        case Points.by_name(name) do
          nil -> :ok
          point -> Points.delete(point)
        end
      end

      Frames.delete(frame)
      Tools.delete(tool)
    end)

    %{tag: tag, robot: robot, frame: frame.name, tool: tool.name, name: "dp_t#{tag}"}
  end

  defp pose(extra) do
    Map.merge(%{"x" => 0.3, "y" => 0.1, "z" => 0.25, "rx" => 0.0, "ry" => 0.0, "rz" => 0.0}, extra)
  end

  defp define(args), do: Source.call("cell.define_point", args, [])

  describe "what it records" do
    test "a point that arrived from a file is marked as such", %{name: name} do
      # Not a quality ranking. A pendant that cannot tell these apart cannot
      # warn anybody that a program moves to places this arm has never been to.
      assert {:ok, %{"name" => ^name, "created" => true}} =
               define(pose(%{"name" => name, "joints" => List.duplicate(0.0, 6)}))

      assert Points.by_name(name).source == "defined"
    end

    test "teaching still marks a point as taught", %{robot: robot, tag: tag} do
      {:ok, _} =
        Points.teach(%{name: "dp2_t#{tag}", robot_id: robot.id, joints: List.duplicate(0.0, 6), x: 0.1})

      assert Points.by_name("dp2_t#{tag}").source == "taught"
    end

    test "the joint vector is stored as given, not solved for", %{name: name} do
      joints = [0.1, -0.2, 0.3, 0.0, 0.5, -0.6]
      assert {:ok, _} = define(pose(%{"name" => name, "joints" => joints}))
      assert Points.by_name(name) |> ExStore.Cell.Point.joints() == joints
    end

    test "re-defining an existing name moves it rather than making a second", %{name: name} do
      assert {:ok, %{"created" => true}} =
               define(pose(%{"name" => name, "joints" => List.duplicate(0.0, 6)}))

      assert {:ok, %{"created" => false}} =
               define(pose(%{"x" => 0.44, "name" => name, "joints" => List.duplicate(0.0, 6)}))

      assert Points.by_name(name).x == 0.44
    end

    test "a frame and a tool are resolved by name", %{name: name, frame: frame, tool: tool} do
      assert {:ok, _} =
               define(
                 pose(%{
                   "name" => name,
                   "joints" => List.duplicate(0.0, 6),
                   "frame" => frame,
                   "tool" => tool
                 })
               )

      point = Points.by_name(name)
      assert Frames.get(point.frame_id).name == frame
      assert Tools.get(point.tool_id).name == tool
    end
  end

  describe "what it refuses" do
    test "no joint vector at all", %{name: name} do
      # It is not solved for and not defaulted. `move_joint` commands the six
      # angles that were recorded rather than solving anything, so a point whose
      # angles came from a solver would have a branch nobody chose, replayed as
      # though somebody had.
      assert {:error, :rejected} = define(pose(%{"name" => name}))
      assert Points.by_name(name) == nil
    end

    test "an empty joint vector", %{name: name} do
      assert {:error, :rejected} = define(pose(%{"name" => name, "joints" => []}))
    end

    test "a joint vector that is not numbers", %{name: name} do
      assert {:error, :rejected} = define(pose(%{"name" => name, "joints" => ["a", "b"]}))
    end

    test "a joint vector of the wrong length for this arm", %{name: name} do
      assert {:error, :rejected} = define(pose(%{"name" => name, "joints" => [0.0, 0.0]}))
      assert Points.by_name(name) == nil
    end

    test "a frame this cell does not have", %{name: name} do
      # The refusal INSTALLATION.md says falls out of the categories. A frame is
      # a claim about where a fixture physically sits, and a file asserting one
      # it has never measured runs cleanly and lands in the wrong place.
      assert {:error, :rejected} =
               define(
                 pose(%{
                   "name" => name,
                   "joints" => List.duplicate(0.0, 6),
                   "frame" => "fixture_from_another_cell"
                 })
               )

      assert Points.by_name(name) == nil
    end

    test "a tool this cell does not have", %{name: name} do
      assert {:error, :rejected} =
               define(
                 pose(%{
                   "name" => name,
                   "joints" => List.duplicate(0.0, 6),
                   "tool" => "somebody_elses_gripper"
                 })
               )

      assert Points.by_name(name) == nil
    end

    test "an unknown frame is refused rather than silently becoming base", %{name: name} do
      # The worst of the available answers would be to relocate somebody's
      # point to the arm's origin and say nothing.
      define(pose(%{"name" => name, "joints" => List.duplicate(0.0, 6), "frame" => "nope"}))
      assert Points.by_name(name) == nil
    end

    test "naming base explicitly is not a missing frame", %{name: name} do
      assert {:ok, _} =
               define(pose(%{"name" => name, "joints" => List.duplicate(0.0, 6), "frame" => "base"}))

      assert Points.by_name(name).frame_id == nil
    end
  end
end
