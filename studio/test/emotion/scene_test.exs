defmodule EMotion.SceneTest do
  @moduledoc """
  Turning a cell into something drawable.

  Asserted on transformed points rather than on matrix entries throughout,
  because every way this goes wrong still produces a picture: a transposed
  rotation renders an arm bending the right amount in the wrong direction, and
  a mis-scaled segment renders a link that is simply the wrong length. Neither
  raises.
  """

  use ExUnit.Case, async: true

  alias Cedar.Math
  alias EMotion.{Cell, Pose, Scene}
  alias ExMove.{Chain, Frame, Joint, JointState}

  defp close?(a, b, tolerance \\ 1.0e-9), do: abs(a - b) <= tolerance

  defp close_point?({ax, ay, az}, {bx, by, bz}, tolerance \\ 1.0e-9) do
    close?(ax, bx, tolerance) and close?(ay, by, tolerance) and close?(az, bz, tolerance)
  end

  defp joint(name, origin, axis \\ {0.0, 0.0, 1.0}) do
    %Joint{
      id: name,
      name: to_string(name),
      type: :revolute,
      axis: axis,
      origin: origin,
      rpy: {0.0, 0.0, 0.0}
    }
  end

  # A two-link arm standing up the Y axis, rotating about Z.
  defp chain do
    %Chain{
      name: :test_arm,
      joints: [
        joint(:j1, {0.0, 0.0, 0.0}),
        joint(:j2, {0.0, 0.5, 0.0}),
        joint(:j3, {0.0, 0.5, 0.0})
      ],
      axis_ids: [:j1, :j2, :j3]
    }
  end

  defp robot(opts \\ []) do
    %Cell.Robot{
      id: Keyword.get(opts, :id, :arm_a),
      name: "Arm",
      chain: Keyword.get(opts, :chain, chain()),
      base: Keyword.get(opts, :base, Cell.origin()),
      joints: Keyword.get(opts, :joints, [0.0, 0.0, 0.0])
    }
  end

  defp cell(robots) do
    Enum.reduce(robots, Cell.new(), fn r, acc ->
      {:ok, cell} = Cell.apply_change(acc, {:add_robot, r})
      cell
    end)
  end

  describe "Pose.from_exmove/1" do
    test "transposes, because ExMove is row-major and Cedar is column-major" do
      # Translation lives in the last *row* for ExMove and the last *column*
      # for Cedar. If this is not transposed, a translated frame renders at the
      # origin and a rotation renders as its own inverse.
      exmove = ExMove.Math.translation(1.0, 2.0, 3.0)
      cedar = Pose.from_exmove(exmove)

      assert close_point?(Math.transform_point(cedar, {0.0, 0.0, 0.0}), {1.0, 2.0, 3.0})
    end

    test "a rotation agrees with ExMove's own convention" do
      # The convention is ExMove's; this asserts we read it rather than
      # reinvent it. 90 degrees of yaw takes +X to +Y in both.
      exmove = ExMove.Math.rotation_rpy(0.0, 0.0, :math.pi() / 2)
      cedar = Pose.from_exmove(exmove)

      assert close_point?(Math.transform_point(cedar, {1.0, 0.0, 0.0}), {0.0, 1.0, 0.0}, 1.0e-12)
    end

    test "composition survives the conversion in the same order" do
      # Converting then multiplying in Cedar must equal multiplying in ExMove
      # then converting. If the transpose were applied inconsistently these
      # would differ, and only for transforms that both rotate and translate.
      t = ExMove.Math.translation(0.0, 1.0, 0.0)
      r = ExMove.Math.rotation_rpy(0.0, 0.0, :math.pi() / 2)

      combined = Pose.from_exmove(ExMove.Math.mul(t, r))
      separate = Math.multiply(Pose.from_exmove(t), Pose.from_exmove(r))

      point = {1.0, 0.0, 0.0}

      assert close_point?(
               Math.transform_point(combined, point),
               Math.transform_point(separate, point),
               1.0e-12
             )
    end
  end

  describe "Pose.from_frame/1" do
    test "position lands where the frame says" do
      matrix = Pose.from_frame(%Frame{x: 1.0, y: 2.0, z: 3.0})

      assert close_point?(Math.transform_point(matrix, {0.0, 0.0, 0.0}), {1.0, 2.0, 3.0})
    end

    test "rotation is applied about the frame's own position" do
      matrix = Pose.from_frame(%Frame{x: 1.0, y: 0.0, z: 0.0, rz: :math.pi() / 2})

      # The local +X axis becomes world +Y, offset by the frame's position.
      assert close_point?(Math.transform_point(matrix, {1.0, 0.0, 0.0}), {1.0, 1.0, 0.0}, 1.0e-12)
    end
  end

  describe "joint_positions/3" do
    test "starts at the base and walks out the chain" do
      points = Scene.joint_positions(chain(), [0.0, 0.0, 0.0], Math.identity())

      assert length(points) == 4
      assert close_point?(hd(points), {0.0, 0.0, 0.0})
    end

    test "a straight arm stacks up its axis" do
      [_base, j1, j2, j3] = Scene.joint_positions(chain(), [0.0, 0.0, 0.0], Math.identity())

      assert close_point?(j1, {0.0, 0.0, 0.0})
      assert close_point?(j2, {0.0, 0.5, 0.0})
      assert close_point?(j3, {0.0, 1.0, 0.0})
    end

    test "moving a joint moves everything downstream of it" do
      straight = Scene.joint_positions(chain(), [0.0, 0.0, 0.0], Math.identity())
      bent = Scene.joint_positions(chain(), [0.0, :math.pi() / 2, 0.0], Math.identity())

      # The joint that moved and the ones before it stay put.
      assert close_point?(Enum.at(straight, 2), Enum.at(bent, 2))
      # The one after it does not.
      refute close_point?(Enum.at(straight, 3), Enum.at(bent, 3), 1.0e-3)
    end

    test "the base transform places the whole arm" do
      here = Scene.joint_positions(chain(), [0.0, 0.0, 0.0], Math.identity())
      there = Scene.joint_positions(chain(), [0.0, 0.0, 0.0], Math.translation({2.0, 0.0, 0.0}))

      Enum.zip(here, there)
      |> Enum.each(fn {{ax, ay, az}, {bx, by, bz}} ->
        assert close?(bx - ax, 2.0)
        assert close?(by - ay, 0.0)
        assert close?(bz - az, 0.0)
      end)
    end

    test "a short pose is padded rather than refused" do
      # A cell can hold a robot whose pose has not been set yet. Showing it at
      # home beats not drawing it.
      points = Scene.joint_positions(chain(), [], Math.identity())

      assert length(points) == 4
    end
  end

  describe "segment/3" do
    test "spans from one point to the other" do
      transform = Scene.segment({0.0, 0.0, 0.0}, {0.0, 2.0, 0.0}, 0.1)

      # The unit box's ends are at local y = +/- 0.5.
      assert close_point?(Math.transform_point(transform, {0.0, -0.5, 0.0}), {0.0, 0.0, 0.0})
      assert close_point?(Math.transform_point(transform, {0.0, 0.5, 0.0}), {0.0, 2.0, 0.0})
    end

    test "centres on the midpoint" do
      transform = Scene.segment({1.0, 0.0, 0.0}, {3.0, 0.0, 0.0}, 0.1)

      assert close_point?(Math.transform_point(transform, {0.0, 0.0, 0.0}), {2.0, 0.0, 0.0})
    end

    test "works for a vertical link, which is where Euler angles fail" do
      # A robot at rest is mostly vertical links, and a yaw-then-pitch
      # construction has no defined yaw when the direction is straight up.
      transform = Scene.segment({0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, 0.1)

      assert close_point?(Math.transform_point(transform, {0.0, 0.5, 0.0}), {0.0, 1.0, 0.0})
      assert Enum.all?(transform, &is_float/1)
      refute Enum.any?(transform, &(&1 != &1))
    end

    test "works along every world axis" do
      for target <- [{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}, {1.0, 1.0, 1.0}] do
        transform = Scene.segment({0.0, 0.0, 0.0}, target, 0.05)

        assert close_point?(Math.transform_point(transform, {0.0, 0.5, 0.0}), target, 1.0e-9),
               "failed for #{inspect(target)}"
      end
    end

    test "thickness scales the cross section, not the length" do
      thin = Scene.segment({0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, 0.05)
      thick = Scene.segment({0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, 0.5)

      # Same endpoints...
      assert close_point?(
               Math.transform_point(thin, {0.0, 0.5, 0.0}),
               Math.transform_point(thick, {0.0, 0.5, 0.0})
             )

      # ...different girth. Measured as distance from the segment's axis, not
      # as a world component: perpendicular/1 picks whichever world axis the
      # link is least aligned with, so a vertical link's local X is world -Z.
      # Asserting on a component would be asserting on that arbitrary choice.
      girth = fn transform ->
        centre = Math.transform_point(transform, {0.0, 0.0, 0.0})
        Math.length(Math.sub(Math.transform_point(transform, {0.5, 0.0, 0.0}), centre))
      end

      assert girth.(thick) > girth.(thin)
    end

    test "the basis stays right-handed" do
      # A left-handed basis inverts the geometry, which renders as a link lit
      # from inside out rather than as anything obviously broken.
      transform = Scene.segment({0.0, 0.0, 0.0}, {0.3, 0.9, -0.2}, 0.05)

      x =
        Math.normalize(
          Math.transform_point(transform, {1.0, 0.0, 0.0})
          |> then(&Math.sub(&1, Math.transform_point(transform, {0.0, 0.0, 0.0})))
        )

      y =
        Math.normalize(
          Math.sub(
            Math.transform_point(transform, {0.0, 1.0, 0.0}),
            Math.transform_point(transform, {0.0, 0.0, 0.0})
          )
        )

      z =
        Math.normalize(
          Math.sub(
            Math.transform_point(transform, {0.0, 0.0, 1.0}),
            Math.transform_point(transform, {0.0, 0.0, 0.0})
          )
        )

      assert close?(Math.dot(Math.cross(x, y), z), 1.0, 1.0e-6)
    end
  end

  describe "nodes/2" do
    test "an empty cell draws nothing" do
      assert Scene.nodes(Cell.new()) == []
    end

    test "a robot yields a base, a joint per joint, and a link between each" do
      nodes = Scene.nodes(cell([robot()]))
      ids = Enum.map(nodes, & &1.id)

      assert {:arm_a, :base} in ids
      assert {:arm_a, :joint0} in ids
      assert {:arm_a, :joint2} in ids
      assert {:arm_a, :link1} in ids
    end

    test "every node is well formed for the viewport" do
      for item <- Scene.nodes(cell([robot()])) do
        assert is_map(item.mesh)
        assert length(item.transform) == 16
        assert tuple_size(item.color) == 4
      end
    end

    test "two robots do not collide in the geometry cache" do
      # Sharing an id between arms would make one arm's links jump to the
      # other's poses, which looks like a kinematics bug and is not one.
      nodes = Scene.nodes(cell([robot(id: :arm_a), robot(id: :arm_b)]))
      ids = Enum.map(nodes, & &1.id)

      assert length(ids) == length(Enum.uniq(ids))
      assert {:arm_a, :base} in ids
      assert {:arm_b, :base} in ids
    end

    test "a robot with no chain still shows its base" do
      # So an operator can see where it will stand before it has geometry.
      nodes = Scene.nodes(cell([robot(chain: nil)]))

      assert [%{id: {:arm_a, :base}}] = nodes
    end

    test "zero-length links are skipped rather than drawn degenerate" do
      # The first joint sits at the base origin in most URDFs, so the segment
      # between them has no length and no defined direction.
      nodes = Scene.nodes(cell([robot()]))
      links = Enum.filter(nodes, fn n -> match?({_, :link0}, n.id) end)

      assert links == []
    end

    test "posing the arm moves the nodes" do
      straight = Scene.nodes(cell([robot(joints: [0.0, 0.0, 0.0])]))
      bent = Scene.nodes(cell([robot(joints: [0.0, :math.pi() / 3, 0.0])]))

      refute Enum.map(straight, & &1.transform) == Enum.map(bent, & &1.transform)
    end

    test "posing the arm does not change which nodes exist" do
      # The property the viewport's geometry cache depends on: same ids, same
      # meshes, different transforms means no uploads.
      straight = Scene.nodes(cell([robot(joints: [0.0, 0.0, 0.0])]))
      bent = Scene.nodes(cell([robot(joints: [0.0, :math.pi() / 3, 0.0])]))

      assert Enum.map(straight, & &1.id) == Enum.map(bent, & &1.id)
      assert Enum.map(straight, & &1.mesh) == Enum.map(bent, & &1.mesh)
    end
  end
end
