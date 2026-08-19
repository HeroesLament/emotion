defmodule EMotion.ProgramTest do
  @moduledoc """
  What `EMotion.Program` and `EMotion.Teach` put on the wire.

  Both are vocabularies over `EMotion.Link.call/3` with no state, so what is
  worth testing is exactly two things: the request they build, and what they do
  with a result that is not the shape they expected. A stub link registered
  under a name gives both without a socket, because `call/3` takes the server
  name as an option for this reason.
  """
  use ExUnit.Case, async: true

  alias EMotion.{Program, Teach}

  defmodule StubLink do
    @moduledoc false
    use GenServer

    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)
    def last(pid), do: GenServer.call(pid, :last)

    @impl true
    def init(reply), do: {:ok, %{reply: reply, last: nil}}

    @impl true
    def handle_call(:last, _from, state), do: {:reply, state.last, state}

    def handle_call({:call, node_id, arguments}, _from, state) do
      {:reply, state.reply, %{state | last: {node_id, arguments}}}
    end

    def handle_call({:read, node_ids}, _from, state) do
      {:reply, state.reply, %{state | last: {:read, node_ids}}}
    end
  end

  defp link(reply) do
    {:ok, pid} = StubLink.start_link(reply)
    %{pid: pid, opts: [name: pid]}
  end

  describe "the request that gets built" do
    test "append sends program, kind and args" do
      %{pid: pid, opts: opts} = link({:ok, %{"seq" => 3}})

      assert {:ok, 3} =
               Program.append(
                 "pick",
                 "move_joint",
                 [%{"name" => "point", "value" => "home"}],
                 opts
               )

      assert {"program.append",
              %{
                "program" => "pick",
                "kind" => "move_joint",
                "args" => [%{"name" => "point", "value" => "home"}]
              }} = StubLink.last(pid)
    end

    test "a reference travels as a name, not an id" do
      # The controller stores a foreign key; the wire carries what a person
      # taught. This is what makes a point's deletion refusable later.
      %{pid: pid, opts: opts} = link({:ok, %{"seq" => 0}})
      Program.append("p", "move_joint", [%{"name" => "point", "value" => "weld_start"}], opts)
      {_id, args} = StubLink.last(pid)
      assert [%{"value" => "weld_start"}] = args["args"]
    end

    test "move carries seq and destination" do
      %{pid: pid, opts: opts} = link({:ok, %{}})
      Program.move("p", 4, 1, opts)
      assert {"program.move", %{"program" => "p", "seq" => 4, "to" => 1}} = StubLink.last(pid)
    end

    test "the run controls take no arguments" do
      for {fun, id} <- [hold: "program.hold", resume: "program.resume",
                        step: "program.step", stop: "program.stop"] do
        %{pid: pid, opts: opts} = link({:ok, %{}})
        apply(Program, fun, [opts])
        assert {^id, %{}} = StubLink.last(pid)
      end
    end

    test "status reads six properties in one round trip" do
      # Six reads would describe a program that was never in that state: a name
      # from one moment and a statement index from the next.
      %{pid: pid, opts: opts} = link({:ok, %{}})
      Program.status(opts)
      {:read, ids} = StubLink.last(pid)
      assert length(ids) == 6
      assert "program.state" in ids
      assert "program.statement" in ids
    end

    test "teach_point omits optional arguments rather than sending nil" do
      %{pid: pid, opts: opts} = link({:ok, %{}})
      Teach.teach_point("home", opts)
      assert {"cell.teach_point", args} = StubLink.last(pid)
      assert args == %{"name" => "home"}
    end

    test "teach_point includes a frame when given one" do
      %{pid: pid, opts: opts} = link({:ok, %{}})
      Teach.teach_point("home", Keyword.put(opts, :frame, "fixture"))
      {_id, args} = StubLink.last(pid)
      assert args["frame"] == "fixture"
    end

    test "master_axis omits `at` when it is not given" do
      %{pid: pid, opts: opts} = link({:ok, %{}})
      Teach.master_axis(:j3, nil, opts)
      assert {"cell.master_axis", %{"axis" => "j3"} = args} = StubLink.last(pid)
      refute Map.has_key?(args, "at")
    end
  end

  describe "results that are not the expected shape" do
    test "a missing field is an error, not a silently different success" do
      # The bug this exists to prevent: `with {:ok, %{"k" => v}} <- call()`
      # falls through unchanged when the pattern does not match, so the caller
      # gets {:ok, the_whole_envelope} and finds out three frames later.
      %{opts: opts} = link({:ok, %{"somethingElse" => []}})

      assert {:error, {:unexpected_result, "kinds", %{"somethingElse" => []}}} =
               Program.kinds(opts)
    end

    test "the same for every list accessor" do
      %{opts: opts} = link({:ok, %{}})
      assert {:error, {:unexpected_result, "programs", _}} = Program.list(opts)
      assert {:error, {:unexpected_result, "statements", _}} = Program.show("p", opts)
      assert {:error, {:unexpected_result, "points", _}} = Teach.list_points(opts)
      assert {:error, {:unexpected_result, "axes", _}} = Teach.mastering(opts)
    end

    test "an error from the controller passes straight through, undamaged" do
      # A refusal is information. "refused: the controller's mode selector is in
      # manual" is worth showing an operator verbatim; mapping it to :error
      # throws away the only useful part.
      refusal = {:error, %{"code" => -32014, "data" => %{"mode" => "manual"}}}
      %{opts: opts} = link(refusal)

      assert ^refusal = Program.start("loop", opts)
      assert ^refusal = Program.kinds(opts)
      assert ^refusal = Teach.mastering(opts)
    end
  end

  describe "validate" do
    test "answers the question rather than making the judgement" do
      # {:ok, _} means the question was answered, not that the statement is
      # valid. The caller reads "ok".
      %{opts: opts} =
        link({:ok, %{"ok" => false, "socket" => "point", "reason" => ~s(no point called "nope")}})

      assert {:ok, %{"ok" => false, "socket" => "point"}} =
               Program.validate("move_joint", [%{"name" => "point", "value" => "nope"}], opts)
    end
  end
end
