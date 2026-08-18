defmodule ExProto.Source.CellTest do
  use ExUnit.Case, async: false

  alias ExProto.Source.Cell, as: Source
  alias ExStore.{Frames, Tools}

  @moduledoc """
  Teaching a frame and fitting a tool, over the protocol's own vocabulary.

  Every refusal here is one a client can act on — a name that is taken, a
  parent that is not there, a frame something else depends on. What must never
  happen is a changeset crossing the wire as a term nobody can match on, which
  is why every failing case asserts `{:error, :rejected}` rather than merely
  that it did not succeed.
  """

  setup do
    tag = System.unique_integer([:positive])

    # Fitting is refused while the arm is moving, so "the arm is not moving" is
    # this file's precondition and it is established rather than assumed. The
    # same lesson as ModeTest: a test that depends on machine state and does
    # not set it passes for as long as nothing else in the VM has moved the arm.
    ExMove.CartesianStream.release(ExMo.Schema.Registry.arm_chain().name)

    on_exit(fn ->
      # Children first: the database refuses to orphan one, which is the point.
      for frame <- Enum.reverse(Frames.list()), String.contains?(frame.name, "t#{tag}") do
        Frames.delete(frame)
      end

      for tool <- Tools.list(), String.contains?(tool.name, "t#{tag}"), do: Tools.delete(tool)
      Tools.unfit()
    end)

    %{tag: tag}
  end

  describe "teaching a frame" do
    test "creates it, and says that it did", %{tag: tag} do
      assert {:ok, %{"name" => name, "created" => true}} =
               Source.call("cell.teach_frame", %{"name" => "fixture_t#{tag}", "x" => 0.4}, [])

      assert Frames.by_name(name).x == 0.4
    end

    test "re-teaching the same name moves it rather than failing", %{tag: tag} do
      name = "fixture_t#{tag}"
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => name, "x" => 0.4}, [])

      assert {:ok, %{"created" => false}} =
               Source.call("cell.teach_frame", %{"name" => name, "x" => 0.5}, [])

      assert Frames.by_name(name).x == 0.5
    end

    test "an omitted axis is zero, not unchanged", %{tag: tag} do
      # A partial re-teach that silently kept five of the six numbers could not
      # be told apart from a full one, and a frame's six numbers were measured
      # together.
      name = "fixture_t#{tag}"
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => name, "x" => 0.4, "rz" => 1.0}, [])
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => name, "x" => 0.4}, [])

      assert Frames.by_name(name).rz == 0.0
    end

    test "a reserved name is refused", %{tag: _tag} do
      for name <- ~w(base tool) do
        assert {:error, :rejected} = Source.call("cell.teach_frame", %{"name" => name}, [])
      end
    end

    test "a parent that is not there is refused", %{tag: tag} do
      assert {:error, :rejected} =
               Source.call(
                 "cell.teach_frame",
                 %{"name" => "jig_t#{tag}", "parent" => "no_such_table"},
                 []
               )
    end

    test "a cycle is refused", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => "a_t#{tag}"}, [])
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => "b_t#{tag}", "parent" => "a_t#{tag}"}, [])

      assert {:error, :rejected} =
               Source.call("cell.teach_frame", %{"name" => "a_t#{tag}", "parent" => "b_t#{tag}"}, [])
    end

    test "no name at all is refused rather than crashing" do
      assert {:error, :rejected} = Source.call("cell.teach_frame", %{}, [])
    end
  end

  describe "listing" do
    test "reports the parent by name, because an id means nothing to a pendant", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => "table_t#{tag}"}, [])

      {:ok, _} =
        Source.call("cell.teach_frame", %{"name" => "jig_t#{tag}", "parent" => "table_t#{tag}"}, [])

      assert {:ok, %{"frames" => frames}} = Source.call("cell.list_frames", %{}, [])

      jig = Enum.find(frames, &(&1["name"] == "jig_t#{tag}"))
      table = Enum.find(frames, &(&1["name"] == "table_t#{tag}"))

      assert jig["parent"] == "table_t#{tag}"
      assert table["parent"] == ""
      assert jig["mutable"] == false
    end
  end

  describe "forgetting a frame" do
    test "deletes it", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => "gone_t#{tag}"}, [])
      assert :ok = Source.call("cell.forget_frame", %{"name" => "gone_t#{tag}"}, [])
      refute Frames.by_name("gone_t#{tag}")
    end

    test "is refused while another frame is defined relative to it", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_frame", %{"name" => "table_t#{tag}"}, [])

      {:ok, _} =
        Source.call("cell.teach_frame", %{"name" => "jig_t#{tag}", "parent" => "table_t#{tag}"}, [])

      assert {:error, :rejected} = Source.call("cell.forget_frame", %{"name" => "table_t#{tag}"}, [])
      assert Frames.by_name("table_t#{tag}")
    end

    test "a frame that is not there is refused, not silently accepted" do
      assert {:error, :rejected} = Source.call("cell.forget_frame", %{"name" => "never_existed"}, [])
    end
  end

  describe "tools" do
    test "teaching one does not fit it", %{tag: tag} do
      assert {:ok, %{"created" => true}} =
               Source.call("cell.teach_tool", %{"name" => "gripper_t#{tag}", "z" => 0.15}, [])

      assert Source.read("cell.tool", []) == {:ok, ""}
    end

    test "fitting one shows up on the node a pendant reads", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_tool", %{"name" => "gripper_t#{tag}", "z" => 0.15}, [])

      assert :ok = Source.call("cell.fit_tool", %{"name" => "gripper_t#{tag}"}, [])
      assert Source.read("cell.tool", []) == {:ok, "gripper_t#{tag}"}

      # And the arm's own geometry moved with it, without the arm moving.
      assert ExMo.Cell.chain().tool.z == 0.15
    end

    test "fitting a second one unfits the first", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_tool", %{"name" => "gripper_t#{tag}", "z" => 0.15}, [])
      {:ok, _} = Source.call("cell.teach_tool", %{"name" => "welder_t#{tag}", "z" => 0.35}, [])

      :ok = Source.call("cell.fit_tool", %{"name" => "gripper_t#{tag}"}, [])
      :ok = Source.call("cell.fit_tool", %{"name" => "welder_t#{tag}"}, [])

      assert Source.read("cell.tool", []) == {:ok, "welder_t#{tag}"}
      refute Tools.by_name("gripper_t#{tag}").fitted
    end

    test "releasing leaves a bare flange, which is a state", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_tool", %{"name" => "gripper_t#{tag}"}, [])
      :ok = Source.call("cell.fit_tool", %{"name" => "gripper_t#{tag}"}, [])

      assert :ok = Source.call("cell.release_tool", %{}, [])
      assert Source.read("cell.tool", []) == {:ok, ""}
    end

    test "fitting a tool that is not there is refused" do
      assert {:error, :rejected} = Source.call("cell.fit_tool", %{"name" => "in_the_drawer"}, [])
    end

    test "listing says which one is fitted", %{tag: tag} do
      {:ok, _} = Source.call("cell.teach_tool", %{"name" => "gripper_t#{tag}", "z" => 0.15}, [])
      :ok = Source.call("cell.fit_tool", %{"name" => "gripper_t#{tag}"}, [])

      assert {:ok, %{"tools" => tools}} = Source.call("cell.list_tools", %{}, [])
      assert %{"z" => 0.15, "fitted" => true} = Enum.find(tools, &(&1["name"] == "gripper_t#{tag}"))
    end
  end

  describe "the node surface" do
    test "nothing here is writable — fitting is something somebody did" do
      assert Source.write("cell.tool", "gripper", []) == {:error, :not_writable}
    end

    test "an unknown node is unknown, not empty" do
      assert Source.read("cell.frames", []) == {:error, :unknown_node}
      assert Source.call("cell.invent_a_frame", %{}, []) == {:error, :not_callable}
    end
  end
end
