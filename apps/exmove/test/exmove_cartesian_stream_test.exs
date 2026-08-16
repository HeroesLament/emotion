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

  describe "frames" do
    # A pose with the wrist folded over, where the tool's +Z is 91.7° off the
    # base's — measured, and chosen for exactly that. The bent pose the rest of
    # this file uses has the tool only 5.7° from base, where the two frames agree
    # closely enough that a test could pass on a frame argument that did nothing.
    @across [0.0, 0.4, -1.0, 0.0, 2.2, 0.0]

    test "the same twist in base and in tool produces different motion", ctx do
      extend(ctx, @across)
      base = travel(ctx, :base, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0])

      extend(ctx, @across)
      tool = travel(ctx, :tool, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0])

      separation = distance(base, tool)

      # Two 50mm moves at right angles end about 70mm apart. Asserting most of
      # that rather than merely "not zero": a frame argument that rotated the
      # twist slightly wrong would still be non-zero.
      assert separation > 0.05,
             "base and tool jogs ended #{Float.round(separation * 1000, 2)}mm apart"
    end

    test "both travel the same distance", ctx do
      # Only the direction should differ. A frame that also changed the distance
      # travelled would mean the transform was not a rotation.
      extend(ctx, @across)
      start = tcp(ctx.chain)
      base_distance = distance(start, travel(ctx, :base, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0]))

      extend(ctx, @across)
      start = tcp(ctx.chain)
      tool_distance = distance(start, travel(ctx, :tool, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0]))

      assert_in_delta base_distance, tool_distance, base_distance * 0.05
    end

    test "a user frame rotates the twist by the frame and nothing else", ctx do
      # 90 degrees about base Z. Commanding +X in this frame has to come out as
      # +Y in the base — the one assertion that distinguishes a frame that is
      # applied from a frame that is accepted and ignored.
      frame = %ExMove.Frame{x: 0.1, y: -0.2, z: 0.05, rz: :math.pi() / 2}

      extend(ctx, @across)
      start = tcp(ctx.chain)
      finish = travel(ctx, {:user, frame}, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0])

      dx = finish.x - start.x
      dy = finish.y - start.y

      assert dy > 0.02, "expected motion along base +Y, got dy=#{Float.round(dy * 1000, 1)}mm"
      assert abs(dx) < abs(dy) / 4, "expected little motion along base X, got dx=#{Float.round(dx * 1000, 1)}mm"
    end

    test "a user frame's translation does not move the arm", ctx do
      # A frame is a rotation and an offset, and only the rotation can affect a
      # velocity. Two frames differing by 300mm of translation must produce the
      # same jog — if the offset leaked into the twist the arm would set off
      # toward the frame's origin.
      near = %ExMove.Frame{x: 0.0, y: 0.0, z: 0.0, rz: 0.3}
      far = %ExMove.Frame{x: 0.3, y: -0.3, z: 0.3, rz: 0.3}

      extend(ctx, @across)
      a = travel(ctx, {:user, near}, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0])

      extend(ctx, @across)
      b = travel(ctx, {:user, far}, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0])

      assert distance(a, b) < 1.0e-3
    end

    test "a user frame with no rotation is the base frame", ctx do
      identity = %ExMove.Frame{x: 0.4, y: 0.4, z: 0.4}

      extend(ctx, @across)
      in_base = travel(ctx, :base, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0])

      extend(ctx, @across)
      in_user = travel(ctx, {:user, identity}, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0])

      assert distance(in_base, in_user) < 1.0e-3
    end

    test "an unknown frame is refused rather than treated as base", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx

      :ok =
        CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0],
          clock: :external,
          hz: 200,
          frame: :workpiece
        )

      step(ctx, 200)

      assert CartesianStream.status(chain.name) == {:refused, :unknown_frame}

      for axis_id <- axis_ids do
        assert Exdrive.Drive.status(axis_id).target_velocity == 0.0
      end
    end
  end

  describe "the tool speed limit" do
    test "a jog above the manual limit is capped, not refused", ctx do
      %{chain: chain} = ctx

      # 1 m/s, four times what ISO 10218 allows in manual mode. The arm can do
      # it — this pose is nowhere near a singularity and a joint would only have
      # to turn 1.44 rad/s — so nothing about the machine objects. The cap does.
      :ok =
        CartesianStream.hold(chain, [0.0, 0.0, 1.0, 0.0, 0.0, 0.0],
          clock: :external,
          hz: 200,
          max_joint_velocity: 5.0
        )

      step(ctx, 200)

      assert {:limited, :tool_speed, fraction} = CartesianStream.status(chain.name)
      assert_in_delta fraction, 0.25, 0.001
    end

    test "the tool travels at the limit rather than at what was asked", ctx do
      %{chain: chain} = ctx

      :ok =
        CartesianStream.hold(chain, [0.0, 0.0, 1.0, 0.0, 0.0, 0.0],
          clock: :external,
          hz: 200,
          max_joint_velocity: 5.0
        )

      run(ctx, 200, 0.25)
      from = tcp(chain)
      run(ctx, 200, 1.0)

      # 250 mm in the second, not the metre that was commanded.
      assert_in_delta distance(from, tcp(chain)), 0.25, 0.01
    end

    test "a jog below the limit is untouched by it", ctx do
      %{chain: chain} = ctx

      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0], clock: :external, hz: 200)
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == :tracking
    end

    test "a cap doing its job never reads as a refusal", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx

      # 10 m/s scales to a fortieth of what was asked — below the speed floor
      # that refuses a jog which has run out of arm. It must not refuse here: the
      # arm is fine, the number was silly, and the machine's answer is "no, 250
      # mm/s" rather than "something is wrong".
      :ok =
        CartesianStream.hold(chain, [0.0, 0.0, 10.0, 0.0, 0.0, 0.0],
          clock: :external,
          hz: 200,
          max_joint_velocity: 50.0
        )

      step(ctx, 200)

      assert {:limited, :tool_speed, _fraction} = CartesianStream.status(chain.name)

      assert Enum.any?(axis_ids, &(abs(Exdrive.Drive.status(&1).target_velocity) > 0.0)),
             "the arm was stopped by a limit that was only supposed to slow it"
    end

    test "a rotation is not measured against a limit in metres per second", ctx do
      %{chain: chain} = ctx

      # 2 rad/s about the tool centre point. Its linear speed is zero by
      # definition, so a cap on translation has nothing to say — and comparing
      # the two under one norm would slow a spin for being fast in the wrong
      # unit.
      :ok =
        CartesianStream.hold(chain, [0.0, 0.0, 0.0, 2.0, 0.0, 0.0],
          clock: :external,
          hz: 200,
          max_joint_velocity: 50.0
        )

      step(ctx, 200)

      refute match?({:limited, :tool_speed, _}, CartesianStream.status(chain.name))
    end
  end

  describe "move_linear" do
    test "arrives at the target and stops", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx

      from = tcp(chain)
      target = %ExMove.Frame{from | z: from.z + 0.08}

      :ok = CartesianStream.move_linear(chain, target, clock: :external, hz: 200, feedrate: 0.05)

      run(ctx, 200, 3.0)

      assert CartesianStream.status(chain.name) == {:done, :reached}

      arrived = tcp(chain)
      assert_in_delta arrived.z, target.z, 1.0e-3
      assert_in_delta arrived.x, from.x, 1.0e-3
      assert_in_delta arrived.y, from.y, 1.0e-3

      for axis_id <- axis_ids do
        assert Exdrive.Drive.status(axis_id).target_velocity == 0.0,
               "#{axis_id} was still commanded after arriving"
      end
    end

    test "does not overshoot", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      target = %ExMove.Frame{from | z: from.z + 0.08}

      :ok = CartesianStream.move_linear(chain, target, clock: :external, hz: 200, feedrate: 0.05)

      # Sampled every tick, because an overshoot is corrected on the next one and
      # a coarser sample would never see it. This is what the `dt` floor on the
      # time-to-go is for: within one tick of the target the arm covers exactly
      # what is left rather than another tick's worth of feedrate.
      worst =
        Enum.reduce(1..600, from.z, fn _i, worst ->
          step(ctx, 200)
          max(worst, tcp(chain).z)
        end)

      assert worst <= target.z + 1.0e-4,
             "overshot to #{Float.round((worst - target.z) * 1000, 3)}mm past the target"
    end

    test "travels in a straight line, not just to the right place", ctx do
      %{chain: chain} = ctx

      extend(ctx, [0.0, 0.4, -1.0, 0.0, 2.2, 0.0])
      from = tcp(chain)
      target = %ExMove.Frame{from | y: from.y - 0.08}

      :ok = CartesianStream.move_linear(chain, target, clock: :external, hz: 200, feedrate: 0.05)

      run(ctx, 200, 0.25)

      worst =
        Enum.reduce(1..400, 0.0, fn _i, worst ->
          step(ctx, 200)
          p = tcp(chain)
          max(worst, :math.sqrt(:math.pow(p.x - from.x, 2) + :math.pow(p.z - from.z, 2)))
        end)

      assert worst < 0.001,
             "left the commanded line by #{Float.round(worst * 1000, 3)}mm"
    end

    test "holds the feedrate it was given", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      target = %ExMove.Frame{from | z: from.z + 0.15}

      :ok = CartesianStream.move_linear(chain, target, clock: :external, hz: 200, feedrate: 0.05)

      run(ctx, 200, 0.25)
      start = tcp(chain)
      run(ctx, 200, 1.0)

      assert_in_delta distance(start, tcp(chain)), 0.05, 0.005
    end

    test "reorienting and translating arrive together", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      target = %ExMove.Frame{from | z: from.z + 0.05, rx: from.rx + 0.3}

      :ok =
        CartesianStream.move_linear(chain, target,
          clock: :external,
          hz: 200,
          feedrate: 0.05,
          angular_feedrate: 0.5
        )

      run(ctx, 200, 4.0)

      assert CartesianStream.status(chain.name) == {:done, :reached}

      arrived = tcp(chain)
      assert_in_delta arrived.z, target.z, 1.0e-3
      assert_in_delta arrived.rx, target.rx, 5.0e-3
    end

    test "the tool speed cap applies to a move as much as to a jog", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      target = %ExMove.Frame{from | z: from.z + 0.5}

      # A metre a second, asked for as a feedrate rather than as a jog. Same
      # machinery, so the same 250 mm/s answer — the cap is a property of the
      # controller, not of one command.
      :ok =
        CartesianStream.move_linear(chain, target,
          clock: :external,
          hz: 200,
          feedrate: 1.0,
          max_joint_velocity: 5.0
        )

      step(ctx, 200)

      assert {:limited, :tool_speed, fraction} = CartesianStream.status(chain.name)
      assert_in_delta fraction, 0.25, 0.01
    end

    test "a jog clears the queue rather than being followed by it", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)

      :ok =
        CartesianStream.move_linear(chain, %ExMove.Frame{from | z: from.z + 0.02},
          clock: :external,
          hz: 200,
          feedrate: 0.05
        )

      :ok = CartesianStream.move_linear(chain, %ExMove.Frame{from | z: from.z + 0.04}, feedrate: 0.05)
      assert CartesianStream.queued(chain.name) == 1

      # An operator taking hold of the arm has taken hold of it. Queued moves
      # firing afterwards because nobody thought to cancel them is how a machine
      # surprises somebody.
      :ok = CartesianStream.hold(chain, [0.0, 0.0, 0.05, 0.0, 0.0, 0.0])

      assert CartesianStream.queued(chain.name) == 0
      assert CartesianStream.intent(chain.name) == [0.0, 0.0, 0.05, 0.0, 0.0, 0.0]

      run(ctx, 200, 0.5)
      assert CartesianStream.status(chain.name) == :tracking
    end

    test "a zero-length move is already finished", ctx do
      %{chain: chain} = ctx

      :ok = CartesianStream.move_linear(chain, tcp(chain), clock: :external, hz: 200, feedrate: 0.05)
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == {:done, :reached}
    end
  end

  describe "the motion queue" do
    test "a second move follows the first rather than replacing it", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      first = %ExMove.Frame{from | z: from.z + 0.04}
      second = %ExMove.Frame{first | y: first.y - 0.04}

      :ok = CartesianStream.move_linear(chain, first, clock: :external, hz: 200, feedrate: 0.05)
      :ok = CartesianStream.move_linear(chain, second, feedrate: 0.05)

      assert CartesianStream.queued(chain.name) == 1

      run(ctx, 200, 4.0)

      assert CartesianStream.status(chain.name) == {:done, :reached}
      assert CartesianStream.queued(chain.name) == 0

      arrived = tcp(chain)
      assert_in_delta arrived.z, second.z, 1.0e-3
      assert_in_delta arrived.y, second.y, 1.0e-3
    end

    test "the corner is turned, not cut, with FINE termination", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      corner = %ExMove.Frame{from | z: from.z + 0.04}
      finish = %ExMove.Frame{corner | y: corner.y - 0.04}

      :ok = CartesianStream.move_linear(chain, corner, clock: :external, hz: 200, feedrate: 0.05)
      :ok = CartesianStream.move_linear(chain, finish, feedrate: 0.05)

      closest =
        Enum.reduce(1..800, 1.0, fn _i, closest ->
          step(ctx, 200)
          p = tcp(chain)
          min(closest, :math.sqrt(:math.pow(p.z - corner.z, 2) + :math.pow(p.y - corner.y, 2)))
        end)

      # Default termination settles on the point. Anything more than the arrival
      # tolerance away and the arm never actually reached the corner it was told
      # to go to.
      assert closest < 1.0e-3,
             "missed the corner by #{Float.round(closest * 1000, 3)}mm"
    end

    test "a blend rounds the corner and keeps moving", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      corner = %ExMove.Frame{from | z: from.z + 0.04}
      finish = %ExMove.Frame{corner | y: corner.y - 0.04}

      :ok =
        CartesianStream.move_linear(chain, corner,
          clock: :external,
          hz: 200,
          feedrate: 0.05,
          blend: 0.01
        )

      :ok = CartesianStream.move_linear(chain, finish, feedrate: 0.05)

      {closest, slowest} =
        Enum.reduce(1..800, {1.0, 1.0}, fn _i, {closest, slowest} ->
          before = tcp(chain)
          step(ctx, 200)
          p = tcp(chain)

          d = :math.sqrt(:math.pow(p.z - corner.z, 2) + :math.pow(p.y - corner.y, 2))
          moved = distance(before, p) * 200

          # Only while it is anywhere near the corner; the ends of the move are
          # legitimately slow and are not what this is measuring.
          if d < 0.02, do: {min(closest, d), min(slowest, moved)}, else: {closest, slowest}
        end)

      # Rounded: it stays outside the arrival tolerance, and inside the blend
      # radius it was given. Cutting the corner entirely would be a different
      # bug from not blending at all, and this catches both.
      assert closest > 1.0e-3, "settled on the corner instead of rounding it"
      assert closest < 0.011, "rounded #{Float.round(closest * 1000, 2)}mm wide of a 10mm blend"

      # And kept moving. The point of a blend is that the arm does not stop in
      # the corner, so a speed anywhere near zero there means it did.
      assert slowest > 0.02,
             "slowed to #{Float.round(slowest * 1000, 1)}mm/s in a corner it was told to round"
    end

    test "a blend with nothing to blend into settles on the point", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      target = %ExMove.Frame{from | z: from.z + 0.04}

      :ok =
        CartesianStream.move_linear(chain, target,
          clock: :external,
          hz: 200,
          feedrate: 0.05,
          blend: 0.01
        )

      run(ctx, 200, 3.0)

      # Rounding a corner into nothing is just stopping short, and the operator
      # asked to end up on the point.
      assert CartesianStream.status(chain.name) == {:done, :reached}
      assert_in_delta tcp(chain).z, target.z, 1.0e-3
    end

    test "releasing throws the queue away", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)

      :ok =
        CartesianStream.move_linear(chain, %ExMove.Frame{from | z: from.z + 0.04},
          clock: :external,
          hz: 200,
          feedrate: 0.05
        )

      :ok = CartesianStream.move_linear(chain, %ExMove.Frame{from | z: from.z + 0.08}, feedrate: 0.05)

      :ok = CartesianStream.release(chain.name)

      assert CartesianStream.whereis(chain.name) == nil
      assert CartesianStream.queued(chain.name) == nil
    end
  end

  describe "a drive whose mode changed underneath the stream" do
    test "the stream puts it back rather than commanding into the void", ctx do
      %{chain: chain, axis_ids: axis_ids} = ctx

      from = tcp(chain)

      :ok =
        CartesianStream.move_linear(chain, %ExMove.Frame{from | z: from.z + 0.01},
          clock: :external,
          hz: 200,
          feedrate: 0.05
        )

      run(ctx, 200, 1.0)
      assert CartesianStream.status(chain.name) == {:done, :reached}

      # Somebody writes a position setpoint. That deliberately puts the drive
      # into profile_position — otherwise the write would be discarded — and it
      # happens behind the stream's back.
      for axis_id <- axis_ids do
        Exdrive.Drive.set_mode(axis_id, :profile_position)
      end

      here = tcp(chain)
      :ok = CartesianStream.move_linear(chain, %ExMove.Frame{here | z: here.z + 0.02}, feedrate: 0.05)
      run(ctx, 200, 2.0)

      # Without putting the mode back the arm does not move at all, while every
      # status reads healthy and the stream reports itself as tracking. Found on
      # a live controller, by an arc that sat perfectly still.
      assert_in_delta tcp(chain).z, here.z + 0.02, 1.0e-3
    end
  end

  describe "move_arc" do
    test "goes round, not across", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)

      # A quarter circle in the YZ plane: out in Z, round through a via point
      # that is off the straight line, and back.
      via = %ExMove.Frame{from | y: from.y - 0.028, z: from.z + 0.028}
      finish = %ExMove.Frame{from | y: from.y - 0.04}

      :ok = CartesianStream.move_arc(chain, via, finish, clock: :external, hz: 200, feedrate: 0.05)

      farthest =
        Enum.reduce(1..800, 0.0, fn _i, farthest ->
          step(ctx, 200)
          max(farthest, tcp(chain).z - from.z)
        end)

      assert CartesianStream.status(chain.name) == {:done, :reached}

      arrived = tcp(chain)
      assert_in_delta arrived.y, finish.y, 2.0e-3
      assert_in_delta arrived.z, finish.z, 2.0e-3

      # A straight line between the endpoints never leaves z. Bulging out to the
      # via point is the entire difference between an arc and a linear move, and
      # a `move_arc` that quietly went straight would pass every other assertion
      # in this test.
      assert farthest > 0.02,
             "only bulged #{Float.round(farthest * 1000, 1)}mm — that is a straight line"
    end

    test "stays on the circle rather than merely hitting the three points", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)
      via = %ExMove.Frame{from | y: from.y - 0.028, z: from.z + 0.028}
      finish = %ExMove.Frame{from | y: from.y - 0.04}

      # The circle through the three points, worked out here independently of
      # the stream: centre and radius in the YZ plane.
      {cy, cz, radius} = circle_through({from.y, from.z}, {via.y, via.z}, {finish.y, finish.z})

      :ok = CartesianStream.move_arc(chain, via, finish, clock: :external, hz: 200, feedrate: 0.05)

      worst =
        Enum.reduce(1..800, 0.0, fn _i, worst ->
          step(ctx, 200)
          p = tcp(chain)
          r = :math.sqrt(:math.pow(p.y - cy, 2) + :math.pow(p.z - cz, 2))
          max(worst, abs(r - radius))
        end)

      assert worst < 0.002,
             "left the circle by #{Float.round(worst * 1000, 2)}mm"
    end

    test "three points that are not a circle are refused", ctx do
      %{chain: chain} = ctx

      from = tcp(chain)

      # Collinear: the via point sits on the straight line between the ends. An
      # arc command that quietly became a straight line would be a program doing
      # something other than what it says.
      via = %ExMove.Frame{from | z: from.z + 0.02}
      finish = %ExMove.Frame{from | z: from.z + 0.04}

      :ok = CartesianStream.move_arc(chain, via, finish, clock: :external, hz: 200, feedrate: 0.05)
      step(ctx, 200)

      assert CartesianStream.status(chain.name) == {:refused, :not_an_arc}
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

  # Hold in `frame` for a second and report where the tool ended up.
  defp travel(ctx, frame, twist) do
    :ok = CartesianStream.hold(ctx.chain, twist, clock: :external, hz: 200, frame: frame)
    run(ctx, 200, 1.0)
    CartesianStream.release(ctx.chain.name)
    tcp(ctx.chain)
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

  # Centre and radius of the circle through three points in a plane. Written out
  # here rather than reused from the stream, because a test that checks a circle
  # with the same code that drew it checks nothing.
  defp circle_through({ax, ay}, {bx, by}, {cx, cy}) do
    d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))

    ux =
      ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) +
         (cx * cx + cy * cy) * (ay - by)) / d

    uy =
      ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) +
         (cx * cx + cy * cy) * (bx - ax)) / d

    {ux, uy, :math.sqrt(:math.pow(ax - ux, 2) + :math.pow(ay - uy, 2))}
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
