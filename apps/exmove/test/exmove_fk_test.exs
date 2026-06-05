defmodule ExMove.FKTest do
  use ExUnit.Case, async: true

  alias ExMove.{Chain, FK, Frame, JointState, URDF}

  setup do
    {:ok, chain} = URDF.load(:arctos)
    %{chain: chain}
  end

  describe "solve/2 at zero pose" do
    test "returns a Frame", %{chain: chain} do
      js = JointState.zero(6)
      frame = FK.solve(chain, js)
      assert %Frame{} = frame
    end

    test "TCP is above base at zero (positive Z)", %{chain: chain} do
      js = JointState.zero(6)
      frame = FK.solve(chain, js)
      assert frame.z > 0.0
    end

    test "zero pose is reproducible", %{chain: chain} do
      js = JointState.zero(6)
      f1 = FK.solve(chain, js)
      f2 = FK.solve(chain, js)
      assert_frames_equal(f1, f2)
    end
  end

  describe "solve/2 joint rotation effects" do
    test "rotating j1 (base Z) changes x/y but not z", %{chain: chain} do
      js0  = JointState.from_positions([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
      js90 = JointState.from_positions([:math.pi() / 2, 0.0, 0.0, 0.0, 0.0, 0.0])

      f0  = FK.solve(chain, js0)
      f90 = FK.solve(chain, js90)

      # Z should be unchanged — j1 rotates around Z axis
      assert_in_delta f0.z, f90.z, 1.0e-6
      # x/y should change (arm sweeps in XY plane)
      assert_differs f0.x, f90.x, 1.0e-3
    end

    test "rotating j2 (shoulder X) changes Z height", %{chain: chain} do
      js0   = JointState.from_positions([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
      js_up = JointState.from_positions([0.0, :math.pi() / 4, 0.0, 0.0, 0.0, 0.0])

      f0   = FK.solve(chain, js0)
      f_up = FK.solve(chain, js_up)

      # Shoulder rotation should change Z
      assert_differs f0.z, f_up.z, 1.0e-3
    end

    test "full rotation of j1 returns to same pose", %{chain: chain} do
      js0      = JointState.from_positions([0.0,            0.0, 0.0, 0.0, 0.0, 0.0])
      js_2pi   = JointState.from_positions([2 * :math.pi(), 0.0, 0.0, 0.0, 0.0, 0.0])

      f0    = FK.solve(chain, js0)
      f_2pi = FK.solve(chain, js_2pi)

      assert_frames_equal(f0, f_2pi, 1.0e-10)
    end
  end

  describe "solve_frames/2" do
    test "returns one frame per joint", %{chain: chain} do
      js     = JointState.zero(6)
      frames = FK.solve_frames(chain, js)
      assert length(frames) == Chain.dof(chain)
    end

    test "last frame matches solve/2 TCP (excluding tool offset)", %{chain: chain} do
      js     = JointState.zero(6)
      frames = FK.solve_frames(chain, js)
      last   = List.last(frames)
      # Last intermediate frame is tip of last joint — near but not equal to
      # TCP when tool offset is non-zero (default Frame is zero offset so equal)
      tcp    = FK.solve(chain, js)
      assert_frames_equal(last, tcp)
    end
  end

  # --- Helpers --------------------------------------------------------------

  defp assert_frames_equal(f1, f2, tol \\ 1.0e-9) do
    assert_in_delta f1.x,  f2.x,  tol
    assert_in_delta f1.y,  f2.y,  tol
    assert_in_delta f1.z,  f2.z,  tol
    assert_in_delta f1.rx, f2.rx, tol
    assert_in_delta f1.ry, f2.ry, tol
    assert_in_delta f1.rz, f2.rz, tol
  end

  defp assert_differs(a, b, tol) do
    refute abs(a - b) < tol,
      "Expected values to differ by more than #{tol}, got #{a} and #{b}"
  end
end
