defmodule ExMove.FrameAlgebraTest do
  use ExUnit.Case, async: true

  alias ExMove.{FK, Frame}

  @moduledoc """
  Composing a pose with the frame it was taught in.

  Two functions, and the whole of what a user frame does. They are tested
  against each other and against hand-computed answers, because the failure
  mode here is not a crash — it is a pose that is wrong by a rotation and
  entirely plausible, which is the kind that reaches a fixture before it
  reaches a test.
  """

  describe "compose" do
    test "a translated frame offsets the pose" do
      fixture = %Frame{x: 1.0, y: 2.0, z: 3.0}
      point = %Frame{x: 0.1, y: 0.0, z: 0.0}

      assert %Frame{x: x, y: y, z: z} = FK.compose(fixture, point)
      assert_in_delta x, 1.1, 1.0e-9
      assert_in_delta y, 2.0, 1.0e-9
      assert_in_delta z, 3.0, 1.0e-9
    end

    test "a rotated frame turns the pose, and about the frame's origin" do
      # 90 degrees about Z: the point's +X becomes the base's +Y.
      fixture = %Frame{x: 1.0, rz: :math.pi() / 2}
      point = %Frame{x: 0.5}

      assert %Frame{x: x, y: y} = FK.compose(fixture, point)
      assert_in_delta x, 1.0, 1.0e-9
      assert_in_delta y, 0.5, 1.0e-9
    end

    test "the order is base-outwards and is not commutative" do
      a = %Frame{x: 1.0, rz: :math.pi() / 2}
      b = %Frame{x: 0.5}

      refute close?(FK.compose(a, b), FK.compose(b, a))
    end

    test "composing with the identity changes nothing" do
      point = %Frame{x: 0.3, y: -0.2, z: 0.9, rx: 0.4, ry: -0.2, rz: 1.1}
      assert close?(FK.compose(%Frame{}, point), point)
      assert close?(FK.compose(point, %Frame{}), point)
    end

    test "nesting composes, which is what a fixture on a positioner is" do
      table = %Frame{x: 1.0, rz: :math.pi() / 2}
      jig = %Frame{x: 0.5}
      hole = %Frame{x: 0.25}

      # Left to right from the base outwards, and associative either way round.
      assert close?(
               FK.compose(FK.compose(table, jig), hole),
               FK.compose(table, FK.compose(jig, hole))
             )
    end
  end

  describe "express_in" do
    test "is the inverse of compose, which is how teaching stores a point" do
      # The arm reports where it is in the base; the pendant says USER; what
      # gets stored is the pose in the frame, so that moving the frame later
      # moves the point.
      fixture = %Frame{x: 0.4, y: -0.1, z: 0.2, rx: 0.3, ry: -0.2, rz: 1.1}
      in_base = %Frame{x: 0.9, y: 0.3, z: 0.5, rx: -0.4, ry: 0.15, rz: -0.7}

      stored = FK.express_in(fixture, in_base)

      assert close?(FK.compose(fixture, stored), in_base)
    end

    test "re-teaching the frame moves the point by exactly the frame's move" do
      # The property the whole table exists for, expressed without a database:
      # store a point in a frame, move the frame 100mm, and the point in the
      # base has moved 100mm and not a millimetre more.
      before = %Frame{x: 0.4, y: 0.0, z: 0.2}
      taught_at = %Frame{x: 0.6, y: 0.1, z: 0.2}
      stored = FK.express_in(before, taught_at)

      moved = %Frame{before | x: before.x + 0.1}
      now = FK.compose(moved, stored)

      assert_in_delta now.x, taught_at.x + 0.1, 1.0e-9
      assert_in_delta now.y, taught_at.y, 1.0e-9
      assert_in_delta now.z, taught_at.z, 1.0e-9
    end
  end

  defp close?(a, b) do
    Enum.all?([:x, :y, :z, :rx, :ry, :rz], fn field ->
      abs(Map.fetch!(a, field) - Map.fetch!(b, field)) < 1.0e-9
    end)
  end
end
