defmodule EMotion.Cell.ServerTest do
  @moduledoc """
  The document process, with the emphasis on the property the UI depends on:
  subscribers are told, they never ask.
  """

  use ExUnit.Case, async: true

  alias EMotion.Cell
  alias EMotion.Cell.{Robot, Server}

  setup do
    {:ok, pid} = Server.start_link(name: nil, cell: Cell.new(name: "Test cell"))
    %{server: pid}
  end

  defp arm(id \\ :arm_a), do: %Robot{id: id, name: "Arm", joints: [0.0, 0.0, 0.0]}

  describe "subscribe/1" do
    test "returns the cell as it stands", %{server: server} do
      assert %Cell{name: "Test cell"} = Server.subscribe(server)
    end

    test "a change reaches every subscriber", %{server: server} do
      Server.subscribe(server)

      test_pid = self()

      other =
        spawn_link(fn ->
          Server.subscribe(server)
          send(test_pid, :ready)
          receive do: ({:cell, cell} -> send(test_pid, {:other_saw, cell.name}))
        end)

      assert_receive :ready
      Server.change({:rename, "Renamed"}, server)

      assert_receive {:cell, %Cell{name: "Renamed"}}
      assert_receive {:other_saw, "Renamed"}

      Process.exit(other, :kill)
    end

    test "unsubscribing stops the updates", %{server: server} do
      Server.subscribe(server)
      Server.unsubscribe(server)

      Server.change({:rename, "Renamed"}, server)

      refute_receive {:cell, _}, 120
    end
  end

  describe "change/2" do
    test "broadcasts the new cell rather than replying", %{server: server} do
      # The property the UI leans on: an edit is a cast, and the answer comes
      # back the same way it would to anyone else. Making this a call would
      # put a synchronous wait on the hot path of dragging a joint.
      Server.subscribe(server)

      assert Server.change({:add_robot, arm()}, server) == :ok
      assert_receive {:cell, cell}
      assert {:ok, %Robot{id: :arm_a}} = Cell.robot(cell, :arm_a)
    end

    test "a refusal goes only to whoever proposed it", %{server: server} do
      # Other workbenches do not need to hear about a change one of them got
      # wrong, and a broadcast error would have every panel showing it.
      Server.subscribe(server)

      test_pid = self()

      spawn_link(fn ->
        Server.subscribe(server)
        receive do: (msg -> send(test_pid, {:other_got, msg}))
      end)

      Process.sleep(20)
      Server.change({:set_joints, :ghost, [0.0]}, server)

      assert_receive {:cell_error, {:no_such_robot, :ghost}}
      refute_receive {:other_got, {:cell_error, _}}, 120
    end

    test "a refused change does not bump the version", %{server: server} do
      before = Server.snapshot(server).version
      Server.change({:set_joints, :ghost, [0.0]}, server)
      assert_receive {:cell_error, _}

      assert Server.snapshot(server).version == before
    end

    test "a list of changes is applied atomically", %{server: server} do
      Server.subscribe(server)

      Server.change([{:add_robot, arm()}, {:set_joints, :arm_a, [0.1, 0.2, 0.3]}], server)

      assert_receive {:cell, cell}
      {:ok, robot} = Cell.robot(cell, :arm_a)
      assert robot.joints == [0.1, 0.2, 0.3]
      # One broadcast for the batch, not one per change.
      refute_receive {:cell, _}, 80
    end
  end

  describe "replace/2" do
    test "swaps the whole document, for opening a file", %{server: server} do
      Server.subscribe(server)
      Server.replace(Cell.new(name: "Opened"), server)

      assert_receive {:cell, %Cell{name: "Opened"}}
    end
  end

  describe "resilience" do
    test "a subscriber crashing does not take the document with it", %{server: server} do
      # A document outlives its windows. A rendering bug must not lose an
      # afternoon of work.
      doomed = spawn(fn -> Server.subscribe(server) end)
      Process.sleep(20)
      Process.exit(doomed, :kill)
      Process.sleep(20)

      assert Process.alive?(server)
      assert %Cell{name: "Test cell"} = Server.snapshot(server)
    end

    test "a dead subscriber is forgotten", %{server: server} do
      doomed = spawn(fn -> Server.subscribe(server) end)
      Process.sleep(20)
      Process.exit(doomed, :kill)
      Process.sleep(20)

      Server.subscribe(server)
      Server.change({:rename, "Still working"}, server)

      assert_receive {:cell, %Cell{name: "Still working"}}
    end
  end
end
