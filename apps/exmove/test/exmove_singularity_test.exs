defmodule ExMove.SingularityTest do
  use ExUnit.Case, async: true

  alias ExMove.{IK, JointState, Library}

  @moduledoc """
  What happens as the arm approaches a singularity, and why the two singularities
  this chain has do not want the same answer.

  A **boundary** singularity — here, approaching full extension as j3 goes to
  zero — costs the arm a translational degree of freedom in the direction it is
  already reaching. A translation through it is genuinely hard, and the joint
  rates that would hold a constant tool speed go to infinity.

  A **wrist** singularity — j5 to zero, aligning the j4 and j6 axes — costs a
  rotational degree of freedom. A translation through it is not hard at all,
  because a translation never needed the axis that was lost.

  Manipulability collapses identically in both. That is the whole reason the
  refusal is on the residual: `w` is a property of the pose and cannot tell those
  two situations apart, while the residual knows what was asked for.
  """

  # 0.05 m/s in +Z, the jog speed everything else in this suite is measured at.
  @translate [0.0, 0.0, 0.05, 0.0, 0.0, 0.0]

  @ceiling 0.5

  setup do
    %{chain: Library.demo()}
  end

  defp solve(chain, q, twist) do
    IK.solve_velocity(chain, JointState.from_positions(q), twist)
  end

  describe "manipulability" do
    test "collapses toward both singularities", %{chain: chain} do
      {:ok, _, bent} = solve(chain, [0.0, 0.6, -0.8, 0.0, 0.7, 0.0], @translate)
      {:ok, _, extended} = solve(chain, [0.0, 0.6, -0.005, 0.0, 0.7, 0.0], @translate)
      {:ok, _, wrist} = solve(chain, [0.0, 0.6, -0.8, 0.0, 0.001, 0.0], @translate)

      assert extended.manipulability < bent.manipulability / 10
      assert wrist.manipulability < bent.manipulability / 10
    end

    test "is zero at a singularity rather than an error", %{chain: chain} do
      {:ok, _, report} = solve(chain, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0], @translate)
      assert report.manipulability == 0.0
    end
  end

  describe "the rates near a singularity" do
    test "an undemanding pose is solved exactly and slowly", %{chain: chain} do
      {:ok, _, report} = solve(chain, [0.0, 0.6, -1.2, 0.0, 0.7, 0.0], @translate)

      assert report.residual < 1.0e-6
      assert report.peak_rate < @ceiling
    end

    test "approaching full extension the rates diverge and the direction does not",
         %{chain: chain} do
      # The solver's job is to answer the question honestly, not to make the
      # answer comfortable. 25 rad/s really is what a 0.05 m/s tool move costs
      # here, and the residual says the direction is still exactly right — which
      # is what makes scaling the whole vector the correct response, and damping
      # the wrong one.
      {:ok, _, report} = solve(chain, [0.0, 0.6, -0.005, 0.0, 0.7, 0.0], @translate)

      assert report.peak_rate > 20.0
      assert report.residual < 1.0e-6
    end

    test "a translation through the wrist singularity costs nothing", %{chain: chain} do
      # The case a manipulability floor would have refused. The arm is as
      # singular as it gets and the command sails through it.
      {:ok, _, report} = solve(chain, [0.0, 0.6, -1.2, 0.0, 0.0, 0.0], @translate)

      assert report.manipulability == 0.0
      assert report.residual < 1.0e-6
      assert report.peak_rate < @ceiling
    end

    test "rotation at that same pose is the thing that degrades", %{chain: chain} do
      # Which rotation is not asserted — that is a fact about this chain's wrist
      # rather than about the policy. What matters is the pair: at a pose where
      # `w` is exactly zero, a translation comes back perfect and a rotation does
      # not. That is the distinction `w` cannot draw and the residual can.
      #
      # Measured here: rx 3.6e-12, ry 0.067, rz 0.098. Note how modest those are
      # even at an exact singularity — the remaining five joints supply 90% of a
      # single-axis rotation between them. Which is why the refusal floor sits
      # well above these, and why the speed floor rather than the residual is
      # what actually stops this arm. A residual large enough to refuse on takes
      # a command with no achievable component at all.
      residuals =
        for twist <- [
              [0.0, 0.0, 0.0, 0.2, 0.0, 0.0],
              [0.0, 0.0, 0.0, 0.0, 0.2, 0.0],
              [0.0, 0.0, 0.0, 0.0, 0.0, 0.2]
            ] do
          {:ok, _, report} = solve(chain, [0.0, 0.6, -1.2, 0.0, 0.0, 0.0], twist)
          report.residual
        end

      {:ok, _, translating} = solve(chain, [0.0, 0.6, -1.2, 0.0, 0.0, 0.0], @translate)

      assert translating.residual < 1.0e-6
      assert Enum.max(residuals) > 100 * translating.residual,
             "rotation was as clean as translation at a wrist singularity, got " <>
               inspect(residuals)
    end
  end

  describe "the residual" do
    test "is the fraction of the command that is not delivered", %{chain: chain} do
      # Hand-checkable: at a well conditioned pose J·dq is the commanded twist,
      # so nothing is missing.
      {:ok, _, report} = solve(chain, [0.0, 0.6, -1.2, 0.0, 0.7, 0.0], @translate)
      assert_in_delta report.residual, 0.0, 1.0e-9
    end

    test "stays at zero all the way down to the singularity", %{chain: chain} do
      # The reason the floor is not a tuning knob. Every one of these poses is
      # harder than the last, the joint rates climb through three orders of
      # magnitude, and the direction is right the whole way — so the residual has
      # nothing to say until the arm actually cannot go where it was pointed.
      # The tolerance loosens at the end and that is the λ floor showing through:
      # at j3=-0.001 the residual is 1.8e-5, which is the 1e-6 damping finally
      # being large enough to matter against a JJᵀ that has almost lost rank. Two
      # orders below the smallest thing anything keys off, and it goes the right
      # way — the floor is the last thing standing between this and a division by
      # zero, so it should start to show exactly there.
      for j3 <- [-0.4, -0.1, -0.05, -0.02, -0.01, -0.001] do
        {:ok, _, report} = solve(chain, [0.0, 0.6, j3, 0.0, 0.7, 0.0], @translate)

        assert report.residual < 1.0e-3,
               "j3=#{j3} reported residual #{report.residual}"
      end
    end

    test "a zero command has no residual to speak of", %{chain: chain} do
      # Division by |v|. A released button asserts zero, and it must not produce
      # a NaN that then propagates into a refusal.
      {:ok, _, report} =
        solve(chain, [0.0, 0.6, -1.2, 0.0, 0.7, 0.0], [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
      assert report.residual == 0.0
    end
  end

  describe "cost" do
    @tag :measurement
    test "a solve stays inside a 200 Hz tick", %{chain: chain} do
      {us, _} =
        :timer.tc(fn ->
          for _ <- 1..500, do: solve(chain, [0.0, 0.6, -1.2, 0.0, 0.7, 0.0], @translate)
        end)

      # 200 Hz is 5000µs of budget per tick, and this now carries a determinant
      # the old solve did not. Asserting an order of magnitude rather than a
      # number, so the test fails on a regression rather than on a busy laptop.
      assert us / 500 < 500
    end
  end
end
