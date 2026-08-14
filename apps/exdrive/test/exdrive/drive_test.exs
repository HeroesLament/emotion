defmodule Exdrive.DriveTest do
  @moduledoc """
  The two properties that make the simulated drive useful as a test fixture:
  time is an input, and every number is SI.

  Everything here runs under `clock: :external`, which is the point — none of
  these tests wait for a wall clock, so the whole file executes in milliseconds
  regardless of how much simulated motion it covers.
  """

  use ExUnit.Case, async: true

  alias Exdrive.Drive

  # A unique axis per test, so registered names never collide across the
  # async suite.
  setup context do
    {:ok, axis: :"t_#{:erlang.phash2(context.test)}"}
  end

  defp start!(axis, opts \\ []) do
    opts = Keyword.merge([axis_id: axis, clock: :external], opts)
    {:ok, pid} = Drive.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)
    pid
  end

  defp enabled!(axis, opts \\ []) do
    start!(axis, opts)
    Drive.enable(axis)
    # `status/1` is a call, ordered behind every cast above it, and
    # not_ready_to_switch_on postpones it until initialisation completes.
    %{state: :operation_enabled} = Drive.status(axis)
    axis
  end

  # gen_statem's :sys.get_state/1 returns {state_name, data}.
  defp data(axis) do
    {_state, data} = :sys.get_state(Process.whereis(:"exdrive_axis_#{axis}"))
    data
  end

  describe "time is an input" do
    test "an externally clocked drive does not move on its own", %{axis: axis} do
      enabled!(axis)
      Drive.set_target_position(axis, 1.0)

      before = Drive.status(axis).actual_position
      Process.sleep(30)

      # Thirty milliseconds of wall clock. An internally clocked drive would
      # have taken thirty steps by now.
      assert Drive.status(axis).actual_position == before
    end

    test "a tick advances it", %{axis: axis} do
      enabled!(axis)
      Drive.set_target_position(axis, 1.0)

      Drive.tick(axis, 0.01)

      assert Drive.status(axis).actual_position > 0.0
    end

    test "velocity depends on dt, not on how many ticks it took", %{axis: axis} do
      # Constant torque gives constant acceleration, so velocity after a given
      # span of simulated time is exact regardless of how it was subdivided.
      # If dt were ignored — the old behaviour — these would differ by 2x.
      enabled!(axis, sim_inertia: 2.0)
      Drive.set_mode(axis, :profile_torque)
      Drive.set_target_torque(axis, 4.0)
      Drive.tick(axis, 0.02)
      one_step = Drive.status(axis).actual_velocity

      other = :"#{axis}_b"
      enabled!(other, sim_inertia: 2.0)
      Drive.set_mode(other, :profile_torque)
      Drive.set_target_torque(other, 4.0)
      Drive.tick(other, 0.01)
      Drive.tick(other, 0.01)
      two_steps = Drive.status(other).actual_velocity

      assert_in_delta one_step, two_steps, 1.0e-9
    end

    test "acceleration is torque over inertia, in SI", %{axis: axis} do
      # 4 N·m into 2 kg·m² is 2 rad/s², so half a second gives 1 rad/s.
      enabled!(axis, sim_inertia: 2.0)
      Drive.set_mode(axis, :profile_torque)
      Drive.set_target_torque(axis, 4.0)

      Drive.tick(axis, 0.5)

      assert_in_delta Drive.status(axis).actual_velocity, 1.0, 1.0e-6
    end

    test "ten seconds of motion costs no wall clock", %{axis: axis} do
      enabled!(axis)
      Drive.set_mode(axis, :profile_velocity)
      Drive.set_target_velocity(axis, 1.0)

      started = System.monotonic_time(:millisecond)
      for _ <- 1..100, do: Drive.tick(axis, 0.1)
      status = Drive.status(axis)
      elapsed = System.monotonic_time(:millisecond) - started

      assert status.actual_position > 5.0, "should have travelled several radians"
      assert elapsed < 500, "took #{elapsed}ms of real time for 10s of simulation"
    end

    test "an internally clocked drive still advances by itself", %{axis: axis} do
      # The default has to keep working, or every IEx session breaks.
      {:ok, pid} = Drive.start_link(axis_id: axis, clock: :internal)
      on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)

      Drive.enable(axis)
      %{state: :operation_enabled} = Drive.status(axis)
      Drive.set_target_position(axis, 1.0)

      Process.sleep(50)

      assert Drive.status(axis).actual_position > 0.0
    end

    @tag :capture_log
    test "an unknown clock is rejected at start", %{axis: axis} do
      Process.flag(:trap_exit, true)
      assert {:error, %ArgumentError{}} = Drive.start_link(axis_id: axis, clock: :wall)
    end
  end

  describe "SI contract" do
    test "profile velocity clamps in rad/s", %{axis: axis} do
      # A far target with a 2 rad/s ceiling travels 2 rad in one second, not
      # however far a degrees-flavoured default would have carried it.
      enabled!(axis)
      Drive.set_target_position(axis, 1000.0)

      Drive.tick(axis, 1.0)

      status = Drive.status(axis)
      assert_in_delta status.actual_velocity, 2.0, 1.0e-6
      assert_in_delta status.actual_position, 2.0, 1.0e-6
    end

    test "quick stop decelerates far harder than a profile stop", %{axis: axis} do
      # 0x6085 exists precisely so a quick stop is not a normal stop. If the
      # defaults ever converge, quick stop stops meaning anything.
      enabled!(axis)
      d = data(axis)

      assert d.quick_stop_decel >= 10 * d.profile_decel
    end

    test "homing tolerance is radians, not degrees", %{axis: axis} do
      # The old tolerance was 0.5 — fine as degrees, absurd as radians, since
      # it would call the axis home nearly 30° out.
      enabled!(axis)
      d = data(axis)

      assert d.homing_tolerance < 0.02,
             "a tolerance of #{d.homing_tolerance} rad is degrees in disguise"
    end

    test "homing converges to zero and reports it", %{axis: axis} do
      enabled!(axis)

      # Park it a radian out, then run the seek.
      Drive.set_mode(axis, :profile_velocity)
      Drive.set_target_velocity(axis, 1.0)
      Drive.tick(axis, 1.0)
      Drive.set_target_velocity(axis, 0.0)

      Drive.subscribe(axis)
      Drive.set_mode(axis, :homing)
      for _ <- 1..500, do: Drive.tick(axis, 0.01)

      status = Drive.status(axis)
      assert status.homing_complete
      assert_in_delta status.actual_position, 0.0, 1.0e-9
      assert_received {:homing_complete, ^axis}
    end
  end

  describe "the state machine" do
    test "a setpoint sent in switched_on is applied when operation is enabled",
         %{axis: axis} do
      # gen_statem postponement. Worth pinning because losing it would be
      # silent — the axis would simply not move and nothing would say why.
      start!(axis)
      Drive.control_word(axis, 0x0006)
      Drive.control_word(axis, 0x0007)
      %{state: :switched_on} = Drive.status(axis)

      Drive.set_target_position(axis, 0.5)
      Drive.control_word(axis, 0x000F)

      assert %{state: :operation_enabled, target_position: 0.5} = Drive.status(axis)
    end

    test "a setpoint sent before switch-on is dropped, not queued", %{axis: axis} do
      # Documents a real gap rather than asserting a wish. Only `switched_on`
      # postpones setpoints; `switch_on_disabled` and `ready_to_switch_on`
      # discard them via their catch-all clauses. So a caller that pushes a
      # target before the drive is on gets no motion and no error — which is
      # worth knowing about deliberately rather than discovering on a bench.
      start!(axis)
      Drive.set_target_position(axis, 0.5)
      Drive.enable(axis)

      status = Drive.status(axis)
      assert status.state == :operation_enabled
      assert status.target_position == 0.0
    end

    test "quick stop ramps down and lands in switch_on_disabled", %{axis: axis} do
      enabled!(axis)
      Drive.set_mode(axis, :profile_velocity)
      Drive.set_target_velocity(axis, 2.0)
      for _ <- 1..100, do: Drive.tick(axis, 0.01)

      assert Drive.status(axis).actual_velocity > 1.0

      Drive.quick_stop(axis)
      for _ <- 1..100, do: Drive.tick(axis, 0.01)

      status = Drive.status(axis)
      assert status.state == :switch_on_disabled
      assert status.actual_velocity == 0.0
    end

    test "quick stop is far quicker than a profile stop would be", %{axis: axis} do
      # At 2 rad/s with quick_stop_decel of 100 rad/s², stopping takes 20ms.
      # On profile_decel it would take 200ms. The distinction is the whole
      # reason 0x6085 is a separate object.
      enabled!(axis)
      Drive.set_mode(axis, :profile_velocity)
      Drive.set_target_velocity(axis, 2.0)
      for _ <- 1..200, do: Drive.tick(axis, 0.01)

      Drive.quick_stop(axis)
      for _ <- 1..5, do: Drive.tick(axis, 0.005)

      assert Drive.status(axis).state == :switch_on_disabled,
             "25ms of quick stop should have stopped a 2 rad/s axis"
    end
  end
end
