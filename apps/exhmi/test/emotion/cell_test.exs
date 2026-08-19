defmodule EMotion.CellTest do
  use ExUnit.Case, async: false

  alias EMotion.Cell
  alias ExMove.Frame
  alias ExStore.{Frames, Tools}

  @moduledoc """
  The seam: stored rows on one side, transforms on the other.

  These are the tests `PROGRAMS.md` §9 opens with, written against the pair of
  tables rather than against points, because points do not exist yet — and the
  property does not need them to be true.
  """

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ExStore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "frames" do
    test "base and tool are computed, never stored" do
      assert Cell.frame("base") == {:ok, :base}
      assert Cell.frame("tool") == {:ok, :tool}
      # And a row cannot shadow either, so the two answers cannot diverge.
      assert {:error, _} = Frames.create(%{name: "base"})
    end

    test "a stored frame resolves to its six numbers" do
      {:ok, _} = Frames.create(%{name: "fixture", x: 0.4, y: -0.1, rz: 1.0})

      assert {:ok, {:user, %Frame{x: 0.4, y: -0.1, rz: 1.0}}} = Cell.frame("fixture")
    end

    test "an unknown frame is an error, not a fallback to base" do
      assert Cell.frame("the_one_from_last_year") == {:error, :unknown_frame}
    end

    test "a nested frame composes down from the root" do
      # 90 degrees about Z at x=1, with a jig 0.5 along the table's own X. The
      # jig lands at (1.0, 0.5) in the base, which is the answer only if the
      # composition happened in the right order.
      {:ok, table} = Frames.create(%{name: "table", x: 1.0, rz: :math.pi() / 2})
      {:ok, _jig} = Frames.create(%{name: "jig", x: 0.5, parent_id: table.id})

      assert {:ok, %Frame{x: x, y: y}} = Cell.resolve("jig")
      assert_in_delta x, 1.0, 1.0e-9
      assert_in_delta y, 0.5, 1.0e-9
    end

    test "re-teaching a frame moves what was taught in it, and nothing else" do
      # The property the table exists for. Points are not built yet, so the
      # taught things here are poses expressed in the frame — which is exactly
      # what a point will store.
      {:ok, fixture} = Frames.create(%{name: "fixture", x: 0.4})
      {:ok, other} = Frames.create(%{name: "elsewhere", x: 0.9})

      {:ok, held} = Cell.pose_in_frame("fixture", %Frame{x: 0.6, y: 0.1})
      {:ok, unrelated} = Cell.pose_in_frame("elsewhere", %Frame{x: 1.0, y: 0.1})

      {:ok, _} = Frames.teach(fixture, %{x: 0.5})

      assert {:ok, %Frame{x: moved}} = Cell.pose_in_base("fixture", held)
      assert_in_delta moved, 0.7, 1.0e-9

      assert {:ok, %Frame{x: still}} = Cell.pose_in_base("elsewhere", unrelated)
      assert_in_delta still, 1.0, 1.0e-9
      assert other.x == 0.9
    end

    test "re-teaching a parent moves its children" do
      {:ok, table} = Frames.create(%{name: "table", x: 1.0})
      {:ok, _jig} = Frames.create(%{name: "jig", x: 0.5, parent_id: table.id})

      {:ok, %Frame{x: before}} = Cell.resolve("jig")
      {:ok, _} = Frames.teach(table, %{x: 1.25})
      {:ok, %Frame{x: now}} = Cell.resolve("jig")

      assert_in_delta now - before, 0.25, 1.0e-9
    end
  end

  describe "the fitted tool" do
    test "a bare flange is the identity, not a missing answer" do
      assert Cell.tool() == %Frame{}
      assert Cell.tool_name() == nil
      assert Cell.chain().tool == %Frame{}
    end

    test "the chain carries whatever is fitted" do
      {:ok, gripper} = Tools.create(%{name: "gripper", z: 0.15})
      {:ok, _} = Tools.fit(gripper)

      assert %Frame{z: 0.15} = Cell.tool()
      assert Cell.tool_name() == "gripper"
      assert %Frame{z: 0.15} = Cell.chain().tool
    end

    test "swapping the tool changes where the arm believes its TCP is" do
      # The point of the whole table, in one assertion: the same joint angles
      # put the TCP in two different places depending on what is bolted on.
      {:ok, short} = Tools.create(%{name: "gripper", z: 0.10})
      {:ok, long} = Tools.create(%{name: "welder", z: 0.35})
      here = %ExMove.JointState{positions: [0.0, 0.6, -1.2, 0.0, 0.7, 0.0]}

      {:ok, _} = Tools.fit(short)
      with_short = ExMove.FK.solve(Cell.chain(), here)

      {:ok, _} = Tools.fit(long)
      with_long = ExMove.FK.solve(Cell.chain(), here)

      separation =
        :math.sqrt(
          :math.pow(with_long.x - with_short.x, 2) +
            :math.pow(with_long.y - with_short.y, 2) +
            :math.pow(with_long.z - with_short.z, 2)
        )

      assert_in_delta separation, 0.25, 1.0e-6
    end
  end
end
