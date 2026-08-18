defmodule ExProto.Program.RunTest do
  use ExUnit.Case, async: false

  alias ExMo.Program.Editor
  alias ExMove.{CartesianStream, JointState}
  alias ExProto.Mode
  alias ExProto.Program.Run
  alias ExStore.{Points, Programs, Robots, Tools}

  @moduledoc """
  The tests `PROGRAMS.md` §10 names for execution, against real drives.

  The first one is the point of the whole exercise: a program runs with nobody
  watching. It cannot be tested by accident — a run that quietly depended on its
  caller would pass every other test in this file.
  """

  @bent [0.0, 0.6, -1.2, 0.0, 0.7, 0.0]

  setup_all do
    chain = ExMo.Cell.Loaded.chain()

    for axis_id <- chain.axis_ids do
      case Exdrive.start_axis(axis_id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      Exdrive.enable(axis_id)
    end

    :ok
  end

  setup do
    chain = ExMo.Cell.Loaded.chain()
    CartesianStream.release(chain.name)

    for {axis_id, position} <- Enum.zip(chain.axis_ids, @bent) do
      Exdrive.Drive.set_mode(axis_id, :profile_position)
      Exdrive.Drive.set_target_position(axis_id, position)
    end

    # Settled, not slept at. Every test in this file teaches a point relative to
    # where the arm is standing, so a start pose that varies by a few
    # milliradians makes the moves different lengths from one run to the next —
    # and near this pose the joint rate ceiling turns a longer move into a
    # noticeably slower one.
    settle(chain)

    start_supervised!({ExProto.Jog, name: RunTestJog})
    start_supervised!({Mode, name: RunTestMode, jog: RunTestJog, run: RunTestRun, position: :auto})
    start_supervised!({Run, name: RunTestRun, mode: RunTestMode})

    tag = System.unique_integer([:positive])

    # This app's tests are not sandboxed — they run against the file, because the
    # processes under test are not descendants of the test process — so anything
    # written here is cleaned up here.
    existing = ExStore.Robots.active()

    {:ok, robot} =
      case existing do
        nil ->
          {:ok, fresh} =
            Robots.store(%{
              name: "bench#{tag}",
              urdf: "<robot/>",
              joints: Enum.map(1..6, &%{name: "joint#{&1}", lower: -3.05, upper: 3.05})
            })

          Robots.activate(fresh)

        robot ->
          {:ok, robot}
      end

    on_exit(fn ->
      CartesianStream.release(chain.name)

      # Programs first: a point a program moves to refuses deletion, which is the
      # rule this file's fixtures have to obey like anything else.
      for program <- Programs.list(), String.contains?(program.name, "t#{tag}") do
        Programs.delete(program)
      end

      for point <- Points.list(), String.contains?(point.name, "t#{tag}"), do: Points.delete(point)
      for tool <- Tools.list(), String.contains?(tool.name, "t#{tag}"), do: Tools.delete(tool)
      Tools.unfit()

      # And the robot, if this file is what invented one. Leaving it behind makes
      # every sibling app's "nothing is commissioned yet" test fail, one run
      # later, for no visible reason.
      if is_nil(existing) do
        case Robots.by_name("bench#{tag}") do
          nil -> :ok
          created -> Robots.delete(created)
        end
      end
    end)

    %{tag: tag, robot: robot, chain: chain}
  end

  # A point at the arm's current pose, nudged in Z so a move to it is short.
  defp teach(name, dz) do
    chain = ExMo.Cell.Loaded.chain()
    {:ok, js} = JointState.read(chain)
    pose = ExMove.FK.solve(ExMo.Cell.chain(), js)

    {:ok, robot} = {:ok, ExStore.Robots.active()}

    {:ok, point} =
      Points.teach(%{
        name: name,
        robot_id: robot.id,
        # Whatever is fitted right now, because that is what teaching records
        # and what a replay is checked against.
        tool_id: ExStore.Tools.fitted() && ExStore.Tools.fitted().id,
        joints: js.positions,
        x: pose.x,
        y: pose.y,
        z: pose.z + dz,
        rx: pose.rx,
        ry: pose.ry,
        rz: pose.rz
      })

    point
  end

  defp program_with(tag, statements) do
    {:ok, program} = Programs.create(%{name: "prog_t#{tag}"})

    for {kind, args} <- statements do
      {:ok, _} = Editor.append(program, kind, args)
    end

    program
  end

  # Twelve seconds. Measured rather than guessed: a 40 mm move commanded at
  # 20 mm/s takes about seven seconds near this pose, because the joint rate
  # ceiling scales it — the arm is doing what it was told, slowly, which is
  # exactly what CARTESIAN.md's limiting is for. A patience shorter than the
  # machine's honest worst case tests the test.
  defp settle(chain, tries \\ 100) do
    {:ok, first} = ExMove.JointState.read(chain)
    Process.sleep(20)
    {:ok, second} = ExMove.JointState.read(chain)

    moved? =
      Enum.zip(first.positions, second.positions)
      |> Enum.any?(fn {a, b} -> abs(a - b) > 1.0e-5 end)

    cond do
      not moved? -> :ok
      tries > 0 -> settle(chain, tries - 1)
      true -> :ok
    end
  end

  defp wait_until(fun, tries \\ 600) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(20) && wait_until(fun, tries - 1)
      # The run's own status in the failure message, because "condition never
      # became true" about a state machine is a sentence that costs an hour.
      true ->
        flunk(
          "never became true; run is #{inspect(Run.status(RunTestRun))}, " <>
            "stream is #{inspect(ExMove.CartesianStream.status(ExMo.Cell.Loaded.chain().name))}"
        )
    end
  end

  describe "running" do
    test "a program runs with nobody watching", %{tag: tag} do
      # The property that separates a stored program from a document. The
      # starting process dies immediately after the call and the run finishes
      # anyway.
      teach("a_t#{tag}", 0.02)
      program_with(tag, [{"move_linear", %{"point" => "a_t#{tag}", "feedrate" => 0.05}}])

      caller = spawn(fn -> Run.start("prog_t#{tag}", RunTestRun) end)
      wait_until(fn -> not Process.alive?(caller) end)

      wait_until(fn -> Run.status(RunTestRun).state == :done end)
      assert Run.status(RunTestRun).statement == 1
    end

    test "a wait happens where the program says it does", %{tag: tag} do
      # The look-ahead barrier, asserted rather than assumed: the arm is standing
      # on the first move's end point for the whole of the wait, rather than the
      # wait starting while it is still travelling.
      teach("a_t#{tag}", 0.03)

      program_with(tag, [
        {"move_linear", %{"point" => "a_t#{tag}", "feedrate" => 0.05}},
        {"wait", %{"seconds" => 0.4}},
        {"move_linear", %{"point" => "a_t#{tag}", "feedrate" => 0.05}}
      ])

      :ok = Run.start("prog_t#{tag}", RunTestRun)

      wait_until(fn -> Run.status(RunTestRun).kind == "wait" end)

      # Mid-wait the arm has arrived and is not being commanded anywhere.
      assert Run.status(RunTestRun).state == :running
      assert CartesianStream.queued(ExMo.Cell.Loaded.chain().name) in [0, nil]

      wait_until(fn -> Run.status(RunTestRun).state == :done end)
    end

    test "a program is refused outside auto", %{tag: tag} do
      teach("a_t#{tag}", 0.02)
      program_with(tag, [{"move_linear", %{"point" => "a_t#{tag}"}}])

      :ok = Mode.select(:manual, RunTestMode)

      assert {:error, {:wrong_mode, :manual}} = Run.start("prog_t#{tag}", RunTestRun)
      assert Run.status(RunTestRun).state == :idle
    end

    test "turning the key out of auto stops a running program", %{tag: tag} do
      teach("a_t#{tag}", 0.05)

      program_with(tag, [
        {"move_linear", %{"point" => "a_t#{tag}", "feedrate" => 0.01}},
        {"wait", %{"seconds" => 5.0}}
      ])

      :ok = Run.start("prog_t#{tag}", RunTestRun)
      wait_until(fn -> Run.status(RunTestRun).state == :running end)

      :ok = Mode.select(:manual, RunTestMode)

      wait_until(fn -> Run.status(RunTestRun).state == :idle end)
    end

    test "a second program is refused while one runs", %{tag: tag} do
      teach("a_t#{tag}", 0.05)
      program_with(tag, [{"wait", %{"seconds" => 2.0}}])

      :ok = Run.start("prog_t#{tag}", RunTestRun)
      assert {:error, {:already_running, _}} = Run.start("prog_t#{tag}", RunTestRun)
    end

    test "an empty program is refused rather than instantly done", %{tag: tag} do
      {:ok, _} = Programs.create(%{name: "prog_t#{tag}"})
      assert {:error, {:empty_program, _}} = Run.start("prog_t#{tag}", RunTestRun)
    end

    test "a program that is not there is refused by name" do
      assert {:error, {:unknown_program, "nope"}} = Run.start("nope", RunTestRun)
    end
  end

  describe "holding" do
    test "stops the arm and resumes on the same statement", %{tag: tag} do
      # Short. The claim is about holding and resuming, not about travel, and
      # near this pose the rate ceiling delivers about a third of the commanded
      # tool speed — so a long move here tests the test's patience instead.
      teach("a_t#{tag}", 0.01)
      program_with(tag, [{"move_linear", %{"point" => "a_t#{tag}", "feedrate" => 0.02}}])


      :ok = Run.start("prog_t#{tag}", RunTestRun)
      wait_until(fn -> Run.status(RunTestRun).state == :running end)

      :ok = Run.hold(RunTestRun)
      assert Run.status(RunTestRun).state == :held

      # Held means stopped: no stream is holding the arm.
      assert CartesianStream.whereis(ExMo.Cell.Loaded.chain().name) == nil

      :ok = Run.resume(RunTestRun)

      wait_until(fn -> Run.status(RunTestRun).state == :done end)
    end

    test "resume during an arc is refused, naming the statement", %{tag: tag} do
      # The one case re-issuing cannot be exact: the via point may be behind the
      # arm, and a circle recomputed through it is a different path.
      teach("via_t#{tag}", 0.04)
      teach("end_t#{tag}", 0.08)

      program_with(tag, [
        {"move_arc", %{"via" => "via_t#{tag}", "point" => "end_t#{tag}", "feedrate" => 0.01}}
      ])

      :ok = Run.start("prog_t#{tag}", RunTestRun)
      wait_until(fn -> Run.status(RunTestRun).kind == "move_arc" end)
      :ok = Run.hold(RunTestRun)
      assert Run.status(RunTestRun).kind == "move_arc"

      assert {:error, {:cannot_resume_arc, _index}} = Run.resume(RunTestRun)
    end

    test "stop abandons the run", %{tag: tag} do
      teach("a_t#{tag}", 0.05)
      program_with(tag, [{"wait", %{"seconds" => 5.0}}])

      :ok = Run.start("prog_t#{tag}", RunTestRun)
      :ok = Run.stop_run(RunTestRun)

      assert %{state: :idle, statement: 0} = Run.status(RunTestRun)
    end
  end

  describe "the fitted tool" do
    test "a point taught with another tool faults the run", %{tag: tag} do
      {:ok, gripper} = Tools.create(%{name: "gripper_t#{tag}", z: 0.05})
      {:ok, _} = Tools.fit(gripper)

      teach("a_t#{tag}", 0.02)

      {:ok, _} = Tools.unfit()

      program_with(tag, [{"move_linear", %{"point" => "a_t#{tag}"}}])
      :ok = Run.start("prog_t#{tag}", RunTestRun)

      wait_until(fn -> Run.status(RunTestRun).state == :faulted end)

      assert Run.status(RunTestRun).reason =~ "gripper_t#{tag}"
      assert Run.status(RunTestRun).reason =~ "none"
    end
  end

  describe "a run's death" do
    test "leaves an arm that is not moving", %{tag: tag, chain: chain} do
      teach("a_t#{tag}", 0.1)
      program_with(tag, [{"move_linear", %{"point" => "a_t#{tag}", "feedrate" => 0.01}}])

      :ok = Run.start("prog_t#{tag}", RunTestRun)
      wait_until(fn -> CartesianStream.whereis(chain.name) != nil end)

      pid = Process.whereis(RunTestRun)
      Process.exit(pid, :kill)

      wait_until(fn -> CartesianStream.whereis(chain.name) == nil end)

      for axis_id <- chain.axis_ids do
        assert Exdrive.Drive.status(axis_id).target_velocity == 0.0
      end
    end
  end
end
