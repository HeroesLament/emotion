defmodule ExMove.CartesianStreamTest do
  use ExUnit.Case, async: false

  alias ExMove.{CartesianStream, FK, JointState, Library}

  @moduledoc """
  Straightness: does a Cartesian jog travel along the line it was commanded?

  Run through real `Exdrive.Drive` processes rather than by integrating the
  stream's output, because "the joints were told the right thing" is not the
  claim being made. The claim is that the arm goes where it was pointed.

  Both clocks are external, so the stream and the drives advance by the same dt
  under the test's control. A straightness test whose result depends on how the
  scheduler interleaved two timers is measuring the machine it ran on.

  ## The bent pose

  Every case starts from a bent pose. The zero pose of this chain is straight up
  at full extension, which is a singularity: joint rates there go to infinity for
  a bounded tool speed, the damped solve returns something finite and arbitrary,
  and any number measured from it means nothing.

  ## What is deliberately not measured

  The first 250ms. The simulated drives ramp at 10 rad/s², so a commanded step
  from rest is followed with a lag, and joints needing different rates reach them
  at different times — which bends the path near the start. That is a drive
  characteristic, not an interpolation error, and the two should not be summed
  into one number and called straightness. The line is taken from where the tool
  actually is once the ramp is done, in the direction commanded.
  """

  @settle 0.25

  setup do
    # Axis ids unique to this module, so the test does not collide with a
    # controller running against :j1..:j6 in the same VM.
    axis_ids = for i <- 1..6, do: :"cs_j#{i}"
    chain = %{Library.demo() | name: :cartesian_stream_test, axis_ids: axis_ids}

    for axis_id <- axis_ids do
      case Exdrive.start_axis(axis_id, clock: :external) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      Exdrive.enable(axis_id)
    end

    on_exit(fn -> CartesianStream.release(chain.name) end)

    wait_for_enabled(axis_ids)

    ctx = %{chain: chain, axis_ids: axis_ids}
    bend(ctx)
    ctx
  end

  describe "straightness" do
    test "jogging +Z at jog speed stays on the commanded line", ctx do
      assert_straight(ctx, 0.05, 200, 1.0)
    end

    test "jogging +Z at the ISO 10218 manual speed limit stays on the line", ctx do
      # 250 mm/s, which is the fastest a Cartesian jog is ever allowed to be, and
      # therefore the speed the tick rate has to be chosen for. Chord error goes
      # as the square of the distance covered in a tick, so this is 25× the
      # error of the case above at the same rate — it is where the margin is.
      assert_straight(ctx, 0.25, 200, 1.0)
    end

    test "the client's assertion rate is not the interpolation rate", ctx do
      # The defect this process exists to prevent, stated as a test: at 10 Hz —
      # the rate a client asserts a hold at — the same jog leaves the line by
      # more than a centimetre. The stream is what decouples the two, so this
      # asserts the bad number rather than a good one. If a future change makes
      # this pass, the tick rate has quietly become the assertion rate again.
      deviation = straightness(ctx, 0.25, 10)

      assert deviation > 5.0,
             "expected a 10 Hz interpolation to visibly leave the line, got " <>
               "#{Float.round(deviation, 3)}mm — has the stream stopped running " <>
               "at its own rate?"
    end
  end

  describe "speed" do
    test "the tool travels at the speed it was asked to", ctx do
      %{chain: chain} = ctx
      speed = 0.05

      :ok = CartesianStream.hold(chain, [0.0, 0.0, speed, 0.0, 0.0, 0.0], clock: :external, hz: 200)

      run(ctx, 200, @settle)
      from = tcp(chain)
      run(ctx, 200, 1.0)
      to = tcp(chain)

      travelled = distance(from, to)

      # Within 2%. The drives follow a velocity setpoint exactly once ramped, so
      # what is left is the chord shortfall — a chord is always shorter than its
      # arc — plus the 1.0e-4 rad rounding in the drive's reported position.
      assert_in_delta travelled, speed * 1.0, speed * 0.02
    end
  end

  describe "the intent" do
    test "refreshing replaces the direction without restarting the tick", ctx do
      %{chain: chain} = ctx

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      pid = CartesianStream.whereis(chain.name)

      :ok = CartesianStream.hold(chain, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0])

      assert CartesianStream.whereis(chain.name) == pid, "refresh restarted the stream"
      assert CartesianStream.intent(chain.name) == [0.05, 0.0, 0.0, 0.0, 0.0, 0.0]
    end

    test "releasing commands zero and stops", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      run(ctx, 200, 0.3)

      assert Enum.any?(axis_ids, &(abs(Exdrive.Drive.status(&1).target_velocity) > 0.0)),
             "nothing was moving before the release, so the release proves nothing"

      :ok = CartesianStream.release(chain.name)

      assert CartesianStream.whereis(chain.name) == nil

      for axis_id <- axis_ids do
        assert Exdrive.Drive.status(axis_id).target_velocity == 0.0,
               "#{axis_id} was left holding a setpoint"
      end
    end

    test "an arm that is not enabled is refused, not partly commanded", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx

      # One joint down is enough. The failure this prevents is five joints
      # commanded and one not, which is a direction nobody asked for.
      Exdrive.Drive.control_word(List.last(axis_ids), 0x0000)
      wait_until(fn -> Exdrive.Drive.status(List.last(axis_ids)).state != :operation_enabled end)

      assert {:error, _} = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external)
      assert CartesianStream.whereis(chain.name) == nil

      for axis_id <- axis_ids do
        assert Exdrive.Drive.status(axis_id).target_velocity == 0.0
      end
    end
  end

  describe "limiting and refusing" do
    test "reports the fraction it is actually moving at", ctx do
      %{chain: chain} = ctx

      # Extended nearly straight, where a modest tool speed asks for joint rates
      # the ceiling will not allow. The tool stays on the commanded line; only
      # the speed gives way.
      extend(ctx, [0.0, 0.6, -0.05, 0.0, 0.7, 0.0])

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      step(ctx, 200)

      assert {:limited, :rate, fraction} = CartesianStream.status(chain.name)
      assert fraction > 0.0 and fraction < 1.0
    end

    test "an unlimited jog says so rather than saying nothing", ctx do
      %{chain: chain} = ctx

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == :tracking
    end

    test "refuses and stops when the achievable speed collapses", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx

      # Close enough to full extension that the fraction falls under the floor.
      extend(ctx, [0.0, 0.6, -0.002, 0.0, 0.7, 0.0])

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == {:refused, :singular}

      # Zero written, not nothing written. An arm that has run out of arm should
      # stop, rather than coast on its last setpoint until the hold lapses.
      for axis_id <- axis_ids do
        assert Exdrive.Drive.status(axis_id).target_velocity == 0.0,
               "#{axis_id} kept its setpoint through a refusal"
      end
    end

    test "a refusal is not permanent — backing off resumes", ctx do
      %{chain: chain} = ctx

      extend(ctx, [0.0, 0.6, -0.002, 0.0, 0.7, 0.0])
      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      step(ctx, 200)
      assert CartesianStream.status(chain.name) == {:refused, :singular}

      # The stream is still running and still holding the intent. A refusal is a
      # statement about this tick, not a latched fault an operator has to clear —
      # the arm has not done anything wrong by being where it is.
      extend(ctx, [0.0, 0.6, -1.2, 0.0, 0.7, 0.0])
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == :tracking
    end

    test "a jog through a wrist singularity is not refused", ctx do
      %{chain: chain} = ctx

      # Manipulability is exactly zero here. A policy keyed on it would stop the
      # arm; the command is a translation and the wrist was never carrying it.
      extend(ctx, [0.0, 0.6, -1.2, 0.0, 0.0, 0.0])

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == :tracking
    end
  end

  describe "joint limits" do
    # The demo chain's joints travel ±3.05 rad, which a Cartesian jog will not
    # reach in any test that finishes. So the chain is given a tight limit on one
    # joint: it is the same code path, with the boundary moved somewhere a test
    # can get to.
    setup ctx do
      joints = List.update_at(ctx.chain.joints, 1, &%{&1 | limit: {-3.05, 0.62}})

      %{chain: %{ctx.chain | joints: joints}}
    end

    test "stops on the boundary and names the joint", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx
      j2 = Enum.at(axis_ids, 1)

      # Bent pose puts j2 at 0.6, so there is 0.02 rad of travel left. A +Z jog
      # drives it further positive.
      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      run(ctx, 200, 1.0)

      assert {:refused, {:joint_limit, :cs_j2}} = CartesianStream.status(chain.name)

      position = Exdrive.Drive.status(j2).actual_position

      # On the boundary, not past it. The tolerance is the drive's own reporting
      # resolution plus one tick of the ramp it is still coming off, not slack in
      # the check: the point of predicting `q + dq·dt` is that the arm arrives
      # exactly here rather than a controller cycle beyond.
      assert position <= 0.62 + 1.0e-3,
             "j2 went past its 0.62 limit to #{position}"

      assert position > 0.61, "j2 stopped short of its limit at #{position}"
    end

    test "slows before it stops rather than arriving at speed", ctx do
      %{chain: chain} = ctx

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)

      # Somewhere in the approach the motion is scaled by the limit rather than
      # by the rate ceiling. Catching it requires looking every tick: the window
      # is one tick wide by construction, because that is exactly how far ahead
      # the check looks.
      seen =
        Enum.reduce(1..200, [], fn _i, acc ->
          step(ctx, 200)
          [CartesianStream.status(chain.name) | acc]
        end)

      assert Enum.any?(seen, &match?({:limited, {:joint_limit, :cs_j2}, _fraction}, &1)),
             "went from tracking straight to refused with no limiting in between"
    end

    test "jogging away from the limit is not refused", ctx do
      %{chain: chain} = ctx

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      run(ctx, 200, 1.0)
      assert {:refused, {:joint_limit, _}} = CartesianStream.status(chain.name)

      # The whole point of not latching. An arm parked on a limit with no way off
      # it is worse than one that never stopped.
      :ok = CartesianStream.hold(chain, [0.0, 0.0, -0.05, 0.0, 0.0, 0.0])
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == :tracking
    end

    test "a continuous joint is not treated as one at zero", ctx do
      # `nil` and `lo >= hi` both mean "this joint turns forever". A limit check
      # that read either as a bound at the origin would refuse every jog on a
      # chain with a continuous wrist, which is most of them.
      %{chain: chain} = ctx

      chain =
        update_in(chain.joints, fn joints ->
          joints
          |> List.update_at(1, &%{&1 | limit: nil})
          |> List.update_at(4, &%{&1 | limit: {1.0, -1.0}})
        end)

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      run(ctx, 200, 0.5)

      assert CartesianStream.status(chain.name) == :tracking
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp assert_straight(ctx, speed, hz, tolerance_mm) do
    deviation = straightness(ctx, speed, hz)

    assert deviation < tolerance_mm,
           "worst deviation from the commanded line was " <>
             "#{Float.round(deviation, 3)}mm at #{speed} m/s, #{hz} Hz"
  end

  # Worst perpendicular distance, in millimetres, from the line through the
  # post-ramp position in the commanded direction.
  defp straightness(%{chain: chain} = ctx, speed, hz) do
    :ok = CartesianStream.hold(chain, [0.0, 0.0, speed, 0.0, 0.0, 0.0], clock: :external, hz: hz, max_joint_velocity: 5.0)

    run(ctx, hz, @settle)
    origin = tcp(chain)

    {_, worst} =
      Enum.reduce(1..round(hz * 1.5), {nil, 0.0}, fn _i, {_, worst} ->
        step(ctx, hz)
        p = tcp(chain)
        # Commanded direction is +Z, so the perpendicular error is everything
        # that is not Z.
        d = :math.sqrt(:math.pow(p.x - origin.x, 2) + :math.pow(p.y - origin.y, 2))
        {p, max(worst, d)}
      end)

    worst * 1000.0
  end

  # Drive the arm to a bent pose in profile_position mode before jogging from it.
  # Also the reset between tests: the drives outlive each one.
  defp bend(%{chain: chain, axis_ids: axis_ids}) do
    target = [0.0, 0.6, -1.2, 0.0, 0.7, 0.0]

    for {axis_id, q} <- Enum.zip(axis_ids, target) do
      Exdrive.Drive.set_mode(axis_id, :profile_position)
      Exdrive.Drive.set_target_position(axis_id, q)
    end

    # The follower is exponential with a 0.1s time constant; 3 seconds of ticks
    # puts it far below the drive's own 1.0e-4 rad reporting resolution.
    for _ <- 1..300, axis_id <- axis_ids, do: Exdrive.Drive.tick(axis_id, 0.01)

    for {axis_id, q} <- Enum.zip(axis_ids, target) do
      assert_in_delta Exdrive.Drive.status(axis_id).actual_position, q, 1.0e-3
    end

    _ = chain
  end

  # Put the arm at an arbitrary pose. Same mechanism as the reset in setup, and
  # separate from it because these cases need poses the straightness tests would
  # never choose.
  defp extend(%{axis_ids: axis_ids}, target) do
    for {axis_id, q} <- Enum.zip(axis_ids, target) do
      Exdrive.Drive.set_mode(axis_id, :profile_position)
      Exdrive.Drive.set_target_position(axis_id, q)
    end

    for _ <- 1..300, axis_id <- axis_ids, do: Exdrive.Drive.tick(axis_id, 0.01)

    for axis_id <- axis_ids, do: Exdrive.Drive.set_mode(axis_id, :profile_velocity)
    :ok
  end

  defp run(ctx, hz, seconds) do
    for _ <- 1..round(hz * seconds), do: step(ctx, hz)
  end

  # One tick of the stream, then one of every drive, by the same dt. The stream
  # writes setpoints and the drives consume them, so this order is the one a real
  # clock would produce.
  defp step(%{chain: chain, axis_ids: axis_ids}, hz) do
    dt = 1.0 / hz
    # Not asserted on: a tick that refuses is a legitimate outcome and the
    # limiting tests below are about exactly that. What the tick did is read from
    # the status, which is the thing a client sees too.
    _ = CartesianStream.tick(chain.name, dt)
    for axis_id <- axis_ids, do: Exdrive.Drive.tick(axis_id, dt)
  end

  defp tcp(chain) do
    positions = for axis_id <- chain.axis_ids, do: Exdrive.Drive.status(axis_id).actual_position
    FK.solve(chain, %JointState{positions: positions})
  end

  defp distance(a, b) do
    :math.sqrt(:math.pow(b.x - a.x, 2) + :math.pow(b.y - a.y, 2) + :math.pow(b.z - a.z, 2))
  end

  defp wait_for_enabled(axis_ids) do
    for axis_id <- axis_ids do
      wait_until(fn -> Exdrive.Drive.status(axis_id).state == :operation_enabled end)
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end
end
