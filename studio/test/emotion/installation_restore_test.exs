defmodule EMotion.InstallationRestoreTest do
  @moduledoc """
  Restoring an installation: what it writes, what order it writes it in, and —
  the part that matters — what it deliberately does not write.
  """
  use ExUnit.Case, async: true

  alias EMotion.Installation

  defmodule StubLink do
    @moduledoc false
    use GenServer

    def start_link(live), do: GenServer.start_link(__MODULE__, live)
    def calls(pid), do: pid |> GenServer.call(:calls) |> Enum.reverse()
    def fail(pid, node_id, reason), do: GenServer.call(pid, {:fail, node_id, reason})

    @impl true
    def init(live), do: {:ok, %{live: live, calls: [], fail: %{}}}

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

    def handle_call({:fail, node_id, reason}, _from, state) do
      {:reply, :ok, %{state | fail: Map.put(state.fail, node_id, reason)}}
    end

    def handle_call({:call, "cell.installation", _args}, _from, state) do
      {:reply, {:ok, state.live}, state}
    end

    def handle_call({:call, node_id, args}, _from, state) do
      state = %{state | calls: [{node_id, args} | state.calls]}

      case Map.fetch(state.fail, node_id) do
        {:ok, reason} -> {:reply, {:error, reason}, state}
        :error -> {:reply, {:ok, %{}}, state}
      end
    end
  end

  defp live do
    %{
      "robot" => %{"name" => "arctos", "urdf" => "<robot/>"},
      "joints" => [%{"joint" => "joint1", "axis" => "j1", "max_vel" => 1.57}],
      "frames" => [pose_row("bench")],
      "tools" => [pose_row("welder") |> Map.put("fitted", true)],
      "mastering" => [
        %{"axis" => "j1", "state" => "referenced", "offset" => 0.0, "drift" => 0.0},
        %{"axis" => "j2", "state" => "referenced", "offset" => 0.125, "drift" => 0.0}
      ]
    }
  end

  defp pose_row(name, parent \\ "") do
    %{"name" => name, "parent" => parent, "x" => 0.1, "y" => 0.0, "z" => 0.0,
      "rx" => 0.0, "ry" => 0.0, "rz" => 0.0}
  end

  defp backup do
    %Installation{
      robot: %{"name" => "arctos", "urdf" => "<robot/>"},
      joints: [%{"joint" => "joint1", "axis" => "j1", "max_vel" => 1.4}],
      # deliberately out of depth order in the file
      frames: [pose_row("seam_a", "weld_cell"), pose_row("bench"), pose_row("weld_cell")],
      tools: [pose_row("welder") |> Map.put("fitted", true), pose_row("gripper")],
      mastering: [%{"axis" => "j1", "state" => "referenced", "offset" => 0.9, "drift" => 0.0}]
    }
  end

  defp link do
    {:ok, pid} = StubLink.start_link(live())
    %{pid: pid, opts: [name: pid]}
  end

  describe "the plan" do
    test "distinguishes what exists from what does not" do
      %{opts: opts} = link()
      {:ok, plan} = Installation.plan(backup(), opts)

      assert {:replace, :frame, "bench", nil} in plan
      assert {:create, :frame, "weld_cell", nil} in plan
      assert {:replace, :tool, "welder", nil} in plan
      assert {:create, :tool, "gripper", nil} in plan
      assert {:replace, :joint, "joint1", nil} in plan
    end

    test "mastering is always skipped, and says why" do
      # An operator who cannot see that mastering was deliberately not restored
      # will assume it was, which is the belief that ends at the workpiece.
      %{opts: opts} = link()
      {:ok, plan} = Installation.plan(backup(), opts)

      assert {:skip, :mastering, "j1", :belongs_to_the_unit} in plan
      refute Enum.any?(plan, &match?({action, :mastering, _, _} when action != :skip, &1))
    end

    test "the robot description is skipped, and says why" do
      %{opts: opts} = link()
      {:ok, plan} = Installation.plan(backup(), opts)
      assert {:skip, :robot, "arctos", :already_commissioned} in plan
    end

    test "a backup from a different arm still refuses to re-commission" do
      %{opts: opts} = link()
      other = %{backup() | robot: %{"name" => "someone_elses", "urdf" => "<robot/>"}}
      {:ok, plan} = Installation.plan(other, opts)
      assert {:skip, :robot, "someone_elses", :chain_is_compile_time} in plan
    end

    test "writes nothing" do
      # The whole point of a dry run. INSTALLATION.md requires the person to
      # ask, and they cannot ask for what they have not been shown.
      %{pid: pid, opts: opts} = link()
      {:ok, _plan} = Installation.plan(backup(), opts)
      assert StubLink.calls(pid) == []
    end
  end

  describe "installing" do
    test "parents are created before their children" do
      # A frame naming a parent the controller does not have yet is refused,
      # and that refusal would be a fact about ordering rather than the backup.
      %{pid: pid, opts: opts} = link()
      {:ok, _done} = Installation.install(backup(), opts)

      names = for {"cell.teach_frame", args} <- StubLink.calls(pid), do: args["name"]
      assert Enum.find_index(names, &(&1 == "weld_cell")) <
               Enum.find_index(names, &(&1 == "seam_a"))
    end

    test "frames before tools before joints" do
      %{pid: pid, opts: opts} = link()
      {:ok, _done} = Installation.install(backup(), opts)

      kinds = for {node_id, _args} <- StubLink.calls(pid), do: node_id
      assert Enum.uniq(kinds) == ["cell.teach_frame", "cell.teach_tool", "cell.commission"]
    end

    test "no call is ever made that could write a mastering offset" do
      # The assertion the document exists for.
      %{pid: pid, opts: opts} = link()
      {:ok, _done} = Installation.install(backup(), opts)

      for {node_id, _args} <- StubLink.calls(pid) do
        refute node_id =~ "master"
      end
    end

    test "a frame carries its pose and its parent" do
      %{pid: pid, opts: opts} = link()
      {:ok, _done} = Installation.install(backup(), opts)

      assert {_, args} =
               Enum.find(StubLink.calls(pid), fn {id, a} ->
                 id == "cell.teach_frame" and a["name"] == "seam_a"
               end)

      assert args["parent"] == "weld_cell"
      assert args["x"] == 0.1
    end

    test "a refusal is reported per item, with the controller's own words" do
      # One bad joint must not abandon five good ones, which is why
      # cell.commission is per joint rather than per installation.
      %{pid: pid, opts: opts} = link()
      StubLink.fail(pid, "cell.commission", %{"message" => "soft limit outside travel"})

      {:ok, done} = Installation.install(backup(), opts)

      assert {:failed, :joint, "joint1", %{"message" => "soft limit outside travel"}} in done
      assert {:replace, :frame, "bench", nil} in done
    end
  end

  describe "describing it" do
    test "reads as lines a person can check before pressing anything" do
      %{opts: opts} = link()
      {:ok, plan} = Installation.plan(backup(), opts)
      text = Installation.describe(plan)

      assert text =~ ~r/create\s+frame\s+weld_cell/
      assert text =~ ~r/skip\s+mastering\s+j1\s+\(belongs to the unit\)/
      assert text =~ "(already commissioned)"
    end
  end
end
