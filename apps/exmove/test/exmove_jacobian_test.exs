defmodule ExMove.JacobianTest do
  use ExUnit.Case, async: true

  alias ExMove.{Chain, FK, IK, JointState, Library, Math}

  @moduledoc """
  The Jacobian, checked against forward kinematics.

  This is the test that was missing, and its absence shipped a Cartesian jog
  that moved the arm 175mm in a direction nobody commanded.

  The check that existed was `J·dq == commanded twist`. That passes on a wrong
  Jacobian, because it only asks whether the linear solve inverted the matrix it
  was given — it compares `J` with itself. A Jacobian is a claim about how *the
  arm* moves, and the only thing that can refute it is the arm: here, a finite
  difference of `FK.solve/2`, which is the same forward kinematics the tool
  centre point and the Studio viewport are drawn from.

  Every case below is at a bent pose. The zero pose of this chain is straight up
  at full extension, which is a singularity: the columns there are degenerate and
  agree with almost anything.
  """

  # Radians. Small enough that the second-order term is far below the tolerance,
  # large enough to stay well clear of float cancellation in the difference.
  @h 1.0e-7

  # The linear rows carry the error this test exists to catch — a wrong pivot
  # changes a lever arm, which is a position effect. 1.0e-6 m/rad is four orders
  # below the discrepancy that shipped.
  @tolerance 1.0e-6

  setup do
    %{chain: Library.demo()}
  end

  describe "linear rows against a finite difference of FK" do
    poses = [
      {"bent, elbow down", [0.0, 0.6, -1.2, 0.0, 0.7, 0.0]},
      {"bent, elbow up", [0.0, -0.5, 1.1, 0.0, -0.6, 0.0]},
      {"base rotated off the XZ plane", [0.9, 0.4, -0.9, 0.3, 0.5, 0.2]},
      {"every joint off zero", [0.3, -0.7, 0.8, -1.1, 0.4, 2.2]},
      {"wrist folded", [-1.2, 0.5, -1.4, 1.5, 1.2, -0.8]}
    ]

    for {name, q} <- poses do
      test "#{name}", %{chain: chain} do
        q = unquote(q)
        analytic = linear_rows(chain, q)
        numeric = finite_difference(chain, q)

        for {row, i} <- Enum.with_index(analytic),
            {{a, b}, j} <- Enum.with_index(Enum.zip(row, Enum.at(numeric, i))) do
          assert_in_delta a,
                          b,
                          @tolerance,
                          "row #{i}, column j#{j + 1}: Jacobian says #{a}, " <>
                            "moving that joint says #{b}"
        end
      end
    end
  end

  describe "the specific failure that shipped" do
    # A wrong pivot survives `J·dq == twist` and dies here. Stated as its own
    # test because the failure had a shape: the solve was internally perfect and
    # the arm went somewhere else, and a regression would look the same.
    test "joint velocities for a commanded twist actually produce it", %{chain: chain} do
      q = [0.0, 0.6, -1.2, 0.0, 0.7, 0.0]
      commanded = [0.0, 0.0, 0.05, 0.0, 0.0, 0.0]

      {:ok, %JointState{velocities: dq}, _report} =
        IK.solve_velocity(chain, JointState.from_positions(q), commanded)

      # Where FK says the tool goes when the joints move at dq.
      before = FK.solve(chain, JointState.from_positions(q))

      after_ =
        FK.solve(
          chain,
          JointState.from_positions(Enum.zip(q, dq) |> Enum.map(fn {a, b} -> a + b * @h end))
        )

      actual = [(after_.x - before.x) / @h, (after_.y - before.y) / @h, (after_.z - before.z) / @h]

      for {a, c} <- Enum.zip(actual, Enum.take(commanded, 3)) do
        assert_in_delta a, c, 1.0e-5
      end
    end

    test "a pose with nonzero rpy is not a special case", %{chain: chain} do
      # The shipped bug rotated each joint axis by its parent's rotation and
      # omitted the joint's own rpy. Every joint in the demo chain has zero rpy,
      # so the axes came out right by luck and only the pivots were wrong. Tilt
      # one and the axis error appears too.
      chain = update_in(chain.joints, fn joints ->
        List.update_at(joints, 2, &%{&1 | rpy: {0.3, 0.0, 0.2}})
      end)

      q = [0.2, 0.5, -1.0, 0.4, 0.6, -0.3]

      for {row, i} <- Enum.with_index(linear_rows(chain, q)),
          {{a, b}, j} <- Enum.with_index(Enum.zip(row, Enum.at(finite_difference(chain, q), i))) do
        assert_in_delta a, b, @tolerance, "row #{i}, column j#{j + 1}"
      end
    end
  end

  describe "angular rows" do
    # Not finite-differenced: FK reports orientation as rpy, and differencing rpy
    # gives Euler rates rather than the angular velocity the Jacobian's bottom
    # three rows carry. The two are related by a matrix that is itself singular
    # at gimbal lock, so a mismatch would be ambiguous between a real error and
    # the conversion. What is checked instead is the property that made the
    # linear rows wrong: each column is the joint's own axis in the base frame.
    test "each column is the joint axis rotated into the base frame", %{chain: chain} do
      q = [0.4, 0.3, -0.8, 0.9, 0.5, -0.2]
      %{flat: jac, n: n} = IK.jacobian(chain, JointState.from_positions(q))

      frames = FK.solve_frames(chain, JointState.from_positions(q))

      for {{joint, frame}, i} <- Enum.with_index(Enum.zip(chain.joints, frames)) do
        expected = rotate(frame_matrix(chain, q, i), joint.axis)
        actual = for row <- 3..5, do: Enum.at(jac, row * n + i)

        for {a, b} <- Enum.zip(actual, Tuple.to_list(expected)) do
          assert_in_delta a, b, 1.0e-9, "angular column j#{i + 1}"
        end

        # An axis is a unit vector and stays one under rotation. A column that
        # has drifted off unit length is a composition error upstream.
        assert_in_delta :math.sqrt(Enum.reduce(actual, 0.0, &(&1 * &1 + &2))), 1.0, 1.0e-9
        _ = frame
      end
    end
  end

  describe "shape" do
    test "6 rows by one column per joint", %{chain: chain} do
      %{flat: flat, n: n} = IK.jacobian(chain, JointState.zero(6))
      assert n == length(chain.joints)
      assert length(flat) == 6 * n
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp linear_rows(chain, q) do
    %{flat: jac, n: n} = IK.jacobian(chain, JointState.from_positions(q))
    for row <- 0..2, do: for(col <- 0..(n - 1), do: Enum.at(jac, row * n + col))
  end

  # d(tcp)/d(theta_j), one column per joint, as three rows to match the
  # Jacobian's layout.
  defp finite_difference(chain, q) do
    base = FK.solve(chain, JointState.from_positions(q))

    q
    |> Enum.with_index()
    |> Enum.map(fn {_theta, j} ->
      moved = FK.solve(chain, JointState.from_positions(List.update_at(q, j, &(&1 + @h))))
      [(moved.x - base.x) / @h, (moved.y - base.y) / @h, (moved.z - base.z) / @h]
    end)
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end

  # The cumulative transform after joint i — the frame the Jacobian's column i
  # has to be built from.
  defp frame_matrix(%Chain{} = chain, q, i) do
    chain.joints
    |> Enum.zip(q)
    |> Enum.take(i + 1)
    |> Enum.reduce(Math.identity(), fn {joint, theta}, acc ->
      {ox, oy, oz} = joint.origin
      {roll, pitch, yaw} = joint.rpy

      t =
        Math.mul(
          Math.mul(Math.translation(ox, oy, oz), Math.rotation_rpy(roll, pitch, yaw)),
          Math.rotation_axis(joint.axis, theta)
        )

      Math.mul(acc, t)
    end)
  end

  defp rotate({m0, m1, m2, _, m4, m5, m6, _, m8, m9, m10, _, _, _, _, _}, {ax, ay, az}) do
    {m0 * ax + m1 * ay + m2 * az, m4 * ax + m5 * ay + m6 * az, m8 * ax + m9 * ay + m10 * az}
  end
end
