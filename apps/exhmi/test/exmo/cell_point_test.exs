defmodule ExMo.CellPointTest do
  use ExUnit.Case, async: false

  alias ExMo.Cell
  alias ExMove.{FK, Frame, JointState}
  alias ExStore.Cell.Point
  alias ExStore.{Frames, Points, Robots, Tools}

  @moduledoc """
  Teaching a point, and the property the whole frame table exists for.

  `PROGRAMS.md` §9 opens with it: re-teach a frame and every point taught in it
  moves, and nothing else does. It is asserted here against real drives and the
  real chain rather than against arithmetic, because the claim is about what
  the arm does and not about what `compose/2` returns.
  """

  @bent [0.0, 0.6, -1.2, 0.0, 0.7, 0.0]

  setup_all do
    # Loaded rather than Cell here: this only needs the axis ids, and
    # `Cell.chain/0` reads the fitted tool from a database this process does
    # not yet own a sandbox connection to.
    chain = ExMo.Cell.Loaded.chain()

    for axis_id <- chain.axis_ids do
      case Exdrive.start_axis(axis_id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      Exdrive.enable(axis_id)
    end

    for {axis_id, position} <- Enum.zip(chain.axis_ids, @bent) do
      Exdrive.Drive.set_mode(axis_id, :profile_position)
      Exdrive.Drive.set_target_position(axis_id, position)
    end

    # The follower is exponential, so this leaves the arm near the commanded
    # pose rather than exactly on it. Nothing below depends on where that is —
    # only on the point capturing one instant consistently — so there is
    # nothing here worth waiting out.
    Process.sleep(500)
    :ok
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ExStore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # A point belongs to the arm it was taught on, so there has to be one.
    {:ok, robot} =
      Robots.store(%{
        name: "bench",
        urdf: "<robot name=\"bench\"/>",
        joints:
          Enum.map(1..6, fn i ->
            %{name: "joint#{i}", lower: -3.05, upper: 3.05, max_vel: 1.0}
          end)
      })

    {:ok, robot} = Robots.activate(robot)
    %{robot: robot}
  end

  describe "teaching" do
    test "captures where the arm is, in the frame asked for" do
      {:ok, _frame} = Frames.create(%{name: "fixture", x: 0.3, rz: :math.pi() / 2})

      assert {:ok, point} = Cell.teach_point("approach", frame: "fixture")

      # Against the point's own joint solution rather than against a second
      # read of the drives. The arm is still settling by fractions of a
      # milliradian, so two reads a moment apart disagree by more than this is
      # worth asserting at — and the stronger claim is available for free: the
      # pose that was stored and the joints that were stored describe the same
      # instant.
      chain = Cell.chain()
      taught = FK.solve(chain, JointState.from_positions(Point.joints(point)))

      # Stored in the frame, so the numbers are not the base pose.
      assert abs(point.x - taught.x) > 1.0e-6

      assert {:ok, %Frame{} = replayed} = Cell.point_in_base(point)
      assert_in_delta replayed.x, taught.x, 1.0e-9
      assert_in_delta replayed.y, taught.y, 1.0e-9
      assert_in_delta replayed.z, taught.z, 1.0e-9
    end

    test "captures the joint solution the arm was actually in" do
      assert {:ok, point} = Cell.teach_point("here_now")

      {:ok, js} = JointState.read(Cell.chain())

      # Milliradians, not nanoradians, and the tolerance is doing real work
      # rather than papering over one: the arm is still creeping toward the
      # commanded pose between the teach and this read, so the claim being made
      # is that these are the arm's joints and not that time stood still.
      for {taught, actual} <- Enum.zip(Point.joints(point), js.positions) do
        assert_in_delta taught, actual, 5.0e-3
      end
    end

    test "records the tool that was fitted" do
      {:ok, gripper} = Tools.create(%{name: "gripper", z: 0.15})
      {:ok, _} = Tools.fit(gripper)

      assert {:ok, point} = Cell.teach_point("with_gripper")
      assert point.tool_id == gripper.id
      assert Cell.point_tool_name(point) == "gripper"
    end

    test "a bare flange is recorded as one" do
      assert {:ok, point} = Cell.teach_point("bare")
      assert point.tool_id == nil
      assert Cell.point_tool_name(point) == nil
    end

    test "a frame that is not there is refused rather than taught in base" do
      assert {:error, :unknown_frame} = Cell.teach_point("nowhere", frame: "the_old_jig")
      refute Points.by_name("nowhere")
    end
  end

  describe "re-teaching a frame" do
    test "moves every point taught in it, by exactly the frame's move" do
      {:ok, fixture} = Frames.create(%{name: "fixture", x: 0.3})
      {:ok, _elsewhere} = Frames.create(%{name: "elsewhere", x: 0.9})

      {:ok, a} = Cell.teach_point("a", frame: "fixture")
      {:ok, b} = Cell.teach_point("b", frame: "fixture")
      {:ok, c} = Cell.teach_point("c", frame: "elsewhere")

      {:ok, before_a} = Cell.point_in_base(a)
      {:ok, before_b} = Cell.point_in_base(b)
      {:ok, before_c} = Cell.point_in_base(c)

      {:ok, _} = Frames.teach(fixture, %{x: 0.4})

      {:ok, after_a} = Cell.point_in_base(Points.by_name("a"))
      {:ok, after_b} = Cell.point_in_base(Points.by_name("b"))
      {:ok, after_c} = Cell.point_in_base(Points.by_name("c"))

      # Exactly 100mm, in X, and nothing else.
      assert_in_delta after_a.x - before_a.x, 0.1, 1.0e-9
      assert_in_delta after_a.y - before_a.y, 0.0, 1.0e-9
      assert_in_delta after_a.z - before_a.z, 0.0, 1.0e-9
      assert_in_delta after_b.x - before_b.x, 0.1, 1.0e-9

      # And the point taught somewhere else did not move at all.
      assert_in_delta after_c.x - before_c.x, 0.0, 1.0e-9
    end

    test "a point taught in base does not move when any frame does" do
      {:ok, fixture} = Frames.create(%{name: "fixture", x: 0.3})
      {:ok, point} = Cell.teach_point("in_base")
      {:ok, before} = Cell.point_in_base(point)

      {:ok, _} = Frames.teach(fixture, %{x: 1.0})

      {:ok, unchanged} = Cell.point_in_base(Points.by_name("in_base"))
      assert_in_delta unchanged.x, before.x, 1.0e-12
    end

    test "re-teaching a parent moves points taught in the child" do
      {:ok, table} = Frames.create(%{name: "table", x: 1.0})
      {:ok, _jig} = Frames.create(%{name: "jig", x: 0.5, parent_id: table.id})

      {:ok, point} = Cell.teach_point("hole", frame: "jig")
      {:ok, before} = Cell.point_in_base(point)

      {:ok, _} = Frames.teach(table, %{x: 1.25})

      {:ok, moved} = Cell.point_in_base(Points.by_name("hole"))
      assert_in_delta moved.x - before.x, 0.25, 1.0e-9
    end
  end

  describe "the fitted tool" do
    test "a point taught bare does not match an arm with a gripper on it" do
      {:ok, point} = Cell.teach_point("bare")
      assert Cell.tool_matches?(point)

      {:ok, gripper} = Tools.create(%{name: "gripper", z: 0.15})
      {:ok, _} = Tools.fit(gripper)

      refute Cell.tool_matches?(point)
    end

    test "and matches again when the same tool goes back on" do
      {:ok, gripper} = Tools.create(%{name: "gripper", z: 0.15})
      {:ok, welder} = Tools.create(%{name: "welder", z: 0.35})
      {:ok, _} = Tools.fit(gripper)

      {:ok, point} = Cell.teach_point("with_gripper")

      {:ok, _} = Tools.fit(welder)
      refute Cell.tool_matches?(point)

      {:ok, _} = Tools.fit(gripper)
      assert Cell.tool_matches?(point)
    end
  end

end
