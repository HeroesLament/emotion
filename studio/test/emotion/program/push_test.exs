defmodule EMotion.Program.PushTest do
  @moduledoc """
  Pushing a program bundle onto a controller.

  The refusal is the design: points install because they are job data; a frame
  or a tool the cell does not have is refused because it is a claim about how
  the cell is physically built.
  """
  use ExUnit.Case, async: true

  alias EMotion.Program.Bundle

  defmodule StubLink do
    @moduledoc false
    use GenServer

    def start_link(cell), do: GenServer.start_link(__MODULE__, cell)
    def calls(pid), do: pid |> GenServer.call(:calls) |> Enum.reverse()

    @impl true
    def init(cell), do: {:ok, %{cell: cell, calls: []}}

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

    def handle_call({:call, "cell.list_points", _}, _from, s),
      do: {:reply, {:ok, %{"points" => s.cell.points}}, s}

    def handle_call({:call, "cell.list_frames", _}, _from, s),
      do: {:reply, {:ok, %{"frames" => s.cell.frames}}, s}

    def handle_call({:call, "cell.list_tools", _}, _from, s),
      do: {:reply, {:ok, %{"tools" => s.cell.tools}}, s}

    def handle_call({:call, "program.list", _}, _from, s),
      do: {:reply, {:ok, %{"programs" => s.cell.programs}}, s}

    def handle_call({:call, "program.append", args}, _from, s),
      do: {:reply, {:ok, %{"seq" => 0}}, %{s | calls: [{"program.append", args} | s.calls]}}

    def handle_call({:call, node_id, args}, _from, s),
      do: {:reply, {:ok, %{}}, %{s | calls: [{node_id, args} | s.calls]}}
  end

  defp named(names), do: Enum.map(names, &%{"name" => &1})

  defp cell(opts \\ []) do
    %{
      points: named(Keyword.get(opts, :points, [])),
      frames: named(Keyword.get(opts, :frames, ["base", "fixture"])),
      tools: named(Keyword.get(opts, :tools, ["welder"])),
      programs: named(Keyword.get(opts, :programs, []))
    }
  end

  defp bundle do
    %Bundle{
      name: "pick",
      statements: [
        %{"seq" => 0, "kind" => "move_joint",
          "args" => [%{"name" => "point", "value" => "home"}],
          "refs" => [%{"arg" => "point", "kind" => "point", "name" => "home"}]}
      ],
      points: [%{"name" => "home", "frame" => "fixture", "tool" => "welder",
                 "joints" => [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                 "x" => 0.1, "y" => 0.0, "z" => 0.2, "rx" => 0.0, "ry" => 0.0, "rz" => 0.0}],
      frames: named(["fixture"]),
      tools: named(["welder"])
    }
  end

  defp link(cell) do
    {:ok, pid} = StubLink.start_link(cell)
    %{pid: pid, opts: [name: pid]}
  end

  describe "the plan" do
    test "points create when the cell does not have them" do
      %{opts: opts} = link(cell())
      {:ok, plan} = Bundle.plan(bundle(), opts)
      assert {:create, :point, "home", nil} in plan
      assert {:create, :program, "pick", nil} in plan
    end

    test "points replace when it does" do
      %{opts: opts} = link(cell(points: ["home"], programs: ["pick"]))
      {:ok, plan} = Bundle.plan(bundle(), opts)
      assert {:replace, :point, "home", nil} in plan
      assert {:replace, :program, "pick", nil} in plan
    end

    test "a frame the cell does not have is a refusal, not a step" do
      %{opts: opts} = link(cell(frames: ["base"]))
      {:ok, plan} = Bundle.plan(bundle(), opts)
      assert {:refuse, :frame, "fixture", :not_in_this_cell} in plan
      refute Enum.any?(plan, &match?({:create, :frame, _, _}, &1))
    end

    test "a tool the cell does not have is a refusal too" do
      %{opts: opts} = link(cell(tools: []))
      {:ok, plan} = Bundle.plan(bundle(), opts)
      assert {:refuse, :tool, "welder", :not_in_this_cell} in plan
    end

    test "a frame the cell already has gets no line at all" do
      # Saying "leave alone" for every frame buries the one that matters.
      %{opts: opts} = link(cell())
      {:ok, plan} = Bundle.plan(bundle(), opts)
      refute Enum.any?(plan, &match?({_, :frame, _, _}, &1))
    end

    test "writes nothing" do
      %{pid: pid, opts: opts} = link(cell())
      {:ok, _plan} = Bundle.plan(bundle(), opts)
      assert StubLink.calls(pid) == []
    end
  end

  describe "pushing" do
    test "a missing frame refuses the whole push and writes nothing" do
      # Partly installing a program whose points cannot all land would leave a
      # program on the machine naming things that are not there.
      %{pid: pid, opts: opts} = link(cell(frames: ["base"]))

      assert {:error, {:cell_not_commissioned, refusals}} = Bundle.push(bundle(), opts)
      assert {:refuse, :frame, "fixture", :not_in_this_cell} in refusals
      assert StubLink.calls(pid) == []
    end

    test "points are defined before the program is built" do
      # program.append refuses a statement naming a point that does not exist.
      %{pid: pid, opts: opts} = link(cell())
      {:ok, _done} = Bundle.push(bundle(), opts)

      ids = for {id, _args} <- StubLink.calls(pid), do: id
      assert Enum.find_index(ids, &(&1 == "cell.define_point")) <
               Enum.find_index(ids, &(&1 == "program.create"))
    end

    test "a point carries its pose, its joints, its frame and its tool" do
      %{pid: pid, opts: opts} = link(cell())
      {:ok, _done} = Bundle.push(bundle(), opts)

      assert {_, args} = Enum.find(StubLink.calls(pid), &match?({"cell.define_point", _}, &1))
      assert args["name"] == "home"
      assert args["joints"] == [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
      assert args["frame"] == "fixture"
      assert args["tool"] == "welder"
      assert args["z"] == 0.2
    end

    test "the program is deleted and rebuilt rather than merged" do
      # A push installs the artifact, so the machine ends up with exactly what
      # the file says — including the absence of a statement somebody added on
      # the pendant. Merging would be reconciliation wearing a different hat.
      %{pid: pid, opts: opts} = link(cell(programs: ["pick"]))
      {:ok, _done} = Bundle.push(bundle(), opts)

      ids = for {id, _args} <- StubLink.calls(pid), do: id
      assert "program.delete" in ids
      assert Enum.find_index(ids, &(&1 == "program.delete")) <
               Enum.find_index(ids, &(&1 == "program.create"))
    end

    test "statements go in sequence order" do
      %{pid: pid, opts: opts} = link(cell())

      two = %{bundle() | statements: [
        %{"seq" => 1, "kind" => "wait", "args" => [%{"name" => "seconds", "value" => "1"}], "refs" => []},
        %{"seq" => 0, "kind" => "move_joint",
          "args" => [%{"name" => "point", "value" => "home"}],
          "refs" => [%{"arg" => "point", "kind" => "point", "name" => "home"}]}
      ]}

      {:ok, _done} = Bundle.push(two, opts)
      kinds = for {"program.append", args} <- StubLink.calls(pid), do: args["kind"]
      assert kinds == ["move_joint", "wait"]
    end

    test "reports what it did" do
      %{opts: opts} = link(cell())
      {:ok, done} = Bundle.push(bundle(), opts)
      assert {:create, :point, "home", nil} in done
      assert {:installed, :program, "pick", nil} in done
    end
  end
end
