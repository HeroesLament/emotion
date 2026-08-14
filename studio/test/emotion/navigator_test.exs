defmodule EMotion.NavigatorTest do
  @moduledoc """
  Camera gestures.

  Worth testing precisely because the failure mode is "it feels wrong" rather
  than an exception — an inverted axis or a drag that keeps going after the
  button is up produces a camera that works and annoys.
  """

  use ExUnit.Case, async: true

  alias Cedar.Camera
  alias EMotion.Navigator

  defp down(button, x, y, modifiers \\ []) do
    %{type: :down, button: button, x: x, y: y, modifiers: modifiers, wheel_delta: nil}
  end

  defp move(x, y), do: %{type: :move, button: nil, x: x, y: y, modifiers: [], wheel_delta: nil}
  defp up, do: %{type: :up, button: :left, x: 0, y: 0, modifiers: [], wheel_delta: nil}
  defp wheel(delta), do: %{type: :wheel, button: nil, x: 0, y: 0, modifiers: [], wheel_delta: delta}

  defp drag(nav, button, from, to, modifiers \\ []) do
    {x0, y0} = from
    {x1, y1} = to

    nav
    |> Navigator.handle(down(button, x0, y0, modifiers))
    |> Navigator.handle(move(x1, y1))
  end

  describe "orbit" do
    test "a left drag rotates the camera" do
      nav = Navigator.new()
      after_drag = drag(nav, :left, {100, 100}, {160, 100})

      refute after_drag.camera.yaw == nav.camera.yaw
    end

    test "dragging right turns the scene right" do
      # Which means moving the eye left. Inverting this is the single most
      # common way a camera ends up feeling wrong.
      nav = Navigator.new(camera: Camera.new(yaw: 0.0, pitch: 0.0, distance: 4.0))
      {before_x, _, _} = Camera.eye(nav.camera)
      {after_x, _, _} = Camera.eye(drag(nav, :left, {100, 100}, {150, 100}).camera)

      assert after_x < before_x
    end

    test "dragging down raises the eye" do
      nav = Navigator.new(camera: Camera.new(pitch: 0.0))
      after_drag = drag(nav, :left, {100, 100}, {100, 150})

      assert after_drag.camera.pitch > nav.camera.pitch
    end

    test "orbiting leaves the target and distance alone" do
      nav = Navigator.new(camera: Camera.new(target: {1.0, 2.0, 3.0}, distance: 5.0))
      after_drag = drag(nav, :left, {0, 0}, {90, 40})

      assert after_drag.camera.target == {1.0, 2.0, 3.0}
      assert after_drag.camera.distance == 5.0
    end

    test "a drag accumulates across several moves" do
      # The delta that matters is between consecutive moves, not from the
      # press. Getting that wrong makes a slow drag accelerate.
      one =
        Navigator.new()
        |> Navigator.handle(down(:left, 0, 0))
        |> Navigator.handle(move(30, 0))
        |> Navigator.handle(move(60, 0))

      straight =
        Navigator.new()
        |> Navigator.handle(down(:left, 0, 0))
        |> Navigator.handle(move(60, 0))

      assert_in_delta one.camera.yaw, straight.camera.yaw, 1.0e-9
    end
  end

  describe "pan" do
    test "a middle drag moves the target" do
      nav = Navigator.new()
      after_drag = drag(nav, :middle, {100, 100}, {140, 120})

      refute after_drag.camera.target == nav.camera.target
    end

    test "shift and left also pans, for mice with no middle button" do
      nav = Navigator.new()
      shifted = drag(nav, :left, {100, 100}, {140, 100}, [:shift])
      plain = drag(nav, :left, {100, 100}, {140, 100})

      refute shifted.camera.target == nav.camera.target
      assert plain.camera.target == nav.camera.target
    end

    test "panning scales with distance" do
      # A millimetre of screen should move less world when you are close to it.
      near = Navigator.new(camera: Camera.new(distance: 1.0))
      far = Navigator.new(camera: Camera.new(distance: 20.0))

      near_shift = shift_of(near, drag(near, :middle, {0, 0}, {50, 0}))
      far_shift = shift_of(far, drag(far, :middle, {0, 0}, {50, 0}))

      assert far_shift > near_shift
    end

    test "panning does not change the orbit" do
      nav = Navigator.new(camera: Camera.new(yaw: 30.0, pitch: 20.0, distance: 4.0))
      after_drag = drag(nav, :middle, {0, 0}, {40, 40})

      assert after_drag.camera.yaw == 30.0
      assert after_drag.camera.pitch == 20.0
      assert after_drag.camera.distance == 4.0
    end

    defp shift_of(before, later) do
      Cedar.Math.length(Cedar.Math.sub(later.camera.target, before.camera.target))
    end
  end

  describe "dolly" do
    test "the wheel changes distance in both directions" do
      nav = Navigator.new(camera: Camera.new(distance: 4.0))

      closer = Navigator.handle(nav, wheel(1))
      further = Navigator.handle(nav, wheel(-1))

      assert closer.camera.distance < 4.0
      assert further.camera.distance > 4.0
    end

    test "a zero wheel event does nothing" do
      nav = Navigator.new(camera: Camera.new(distance: 4.0))

      assert Navigator.handle(nav, wheel(0)).camera.distance == 4.0
    end

    test "wheeling in forever never reaches the target" do
      nav = Enum.reduce(1..300, Navigator.new(), fn _, n -> Navigator.handle(n, wheel(1)) end)

      assert nav.camera.distance > 0.0
    end
  end

  describe "drag lifecycle" do
    test "moving without pressing does nothing" do
      nav = Navigator.new()

      assert Navigator.handle(nav, move(200, 200)) == nav
    end

    test "releasing ends the drag" do
      nav =
        Navigator.new()
        |> Navigator.handle(down(:left, 0, 0))
        |> Navigator.handle(up())

      refute Navigator.dragging?(nav)

      after_move = Navigator.handle(nav, move(500, 500))
      assert after_move.camera == nav.camera
    end

    test "leaving the window ends the drag" do
      # Otherwise the drag resumes from wherever the mouse re-enters, which is
      # a visible jump.
      nav =
        Navigator.new()
        |> Navigator.handle(down(:left, 0, 0))
        |> Navigator.handle(%{type: :leave, button: nil, x: 0, y: 0, modifiers: [], wheel_delta: nil})

      refute Navigator.dragging?(nav)
    end

    test "the right button is not a gesture" do
      nav = Navigator.new()
      after_press = Navigator.handle(nav, down(:right, 0, 0))

      refute Navigator.dragging?(after_press)
    end

    test "unknown events pass through untouched" do
      nav = Navigator.new()

      assert Navigator.handle(nav, %{type: :enter}) == nav
      assert Navigator.handle(nav, %{something: :else}) == nav
    end
  end

  describe "camera replacement" do
    test "put_camera swaps it" do
      nav = Navigator.new() |> Navigator.put_camera(Camera.new(distance: 9.0))

      assert nav.camera.distance == 9.0
    end

    test "update_camera ends any drag" do
      # A standard view chosen mid-drag must not leave the drag live, or the
      # next mouse move yanks the new view away.
      nav =
        Navigator.new()
        |> Navigator.handle(down(:left, 0, 0))
        |> Navigator.update_camera(&Camera.look(&1, :top))

      refute Navigator.dragging?(nav)
      assert nav.camera.pitch > 80.0
    end
  end
end

defmodule EMotion.BootTest do
  @moduledoc """
  Startup progress.

  The property under test is that the splash can tell the truth: steps really
  run concurrently and off the caller, and a step that fails does not stop the
  others.
  """

  use ExUnit.Case, async: false

  alias EMotion.Boot

  defp start(steps, opts \\ []) do
    {:ok, pid} = Boot.start_link([steps: steps, name: nil] ++ opts)
    pid
  end

  defp await_complete(pid, timeout \\ 2_000) do
    receive do
      {:boot, %{complete?: true} = progress} -> progress
      {:boot, _partial} -> await_complete(pid, timeout)
    after
      timeout -> flunk("boot did not complete within #{timeout}ms")
    end
  end

  test "reports progress as steps finish" do
    pid = start([{"A", fn -> :a end}, {"B", fn -> :b end}])
    Boot.subscribe(pid)
    Boot.run(pid)

    progress = await_complete(pid)

    assert progress.total == 2
    assert progress.done == 2
    assert progress.results["A"] == :a
    assert progress.results["B"] == :b
  end

  test "steps run concurrently, which is the entire point" do
    # Serial execution would take 300ms; concurrent takes about 150.
    pid =
      start([
        {"Slow one", fn -> Process.sleep(150) end},
        {"Slow two", fn -> Process.sleep(150) end}
      ])

    Boot.subscribe(pid)

    started = System.monotonic_time(:millisecond)
    Boot.run(pid)
    await_complete(pid)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 280, "took #{elapsed}ms, which looks serial"
  end

  test "does not block the caller" do
    pid = start([{"Slow", fn -> Process.sleep(200) end}])
    Boot.subscribe(pid)
    Boot.run(pid)

    # Returned immediately; the work is still going.
    refute Boot.progress(pid).complete?
  end

  test "a failing step is recorded and the rest carry on" do
    # An unreachable controller should open the studio with a disconnected
    # indicator, not refuse to open it.
    pid = start([{"Good", fn -> :fine end}, {"Bad", fn -> raise "no controller" end}])
    Boot.subscribe(pid)
    Boot.run(pid)

    progress = await_complete(pid)

    assert progress.complete?
    assert progress.results["Good"] == :fine
    assert [{"Bad", {:exception, message}}] = Boot.failures(progress)
    assert message =~ "no controller"
  end

  test "status names what is still running" do
    assert Boot.status(%{complete?: false, running: ["Controller"], failed: []}) == "Controller…"
    assert Boot.status(%{complete?: true, running: [], failed: []}) == "Ready"
    assert Boot.status(%{complete?: true, running: [], failed: [{"X", :bad}]}) =~ "failed"
  end

  test "an empty boot is never complete, so nothing hangs on it" do
    # A studio with no steps should not sit on a splash forever waiting for a
    # completion that cannot arrive; callers check total.
    pid = start([])
    progress = Boot.subscribe(pid)

    assert progress.total == 0
    refute progress.complete?
  end
end
