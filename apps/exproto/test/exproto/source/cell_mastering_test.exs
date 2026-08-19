defmodule ExProto.Source.CellMasteringTest do
  use ExUnit.Case, async: false

  alias Exdrive.Flash
  alias ExProto.Source.Cell, as: Source

  @moduledoc """
  Mastering, over the protocol.

  The interesting assertions are about what the wire says when an axis does NOT
  know where it is, because that is the case a pendant has to be able to render
  — and "not ready" without naming the joint or the missing fact sends somebody
  to check six of them.
  """

  setup do
    chain = EMotion.Schema.Registry.arm_chain()
    ExMove.CartesianStream.release(chain.name)

    # Adopt the arm's drives rather than insisting on starting them: sibling
    # files in this app start the same axes, and which of us gets there first
    # depends on the seed. What this file needs is not ownership, it is a known
    # starting state — so it establishes one instead of assuming one.
    for axis_id <- chain.axis_ids do
      case Exdrive.start_axis(axis_id, clock: :external) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      normalise(axis_id)
    end

    # And leaves one behind, for the same reason. An offset of zero is what
    # every other test in the umbrella has always assumed without saying so.
    on_exit(fn -> Enum.each(chain.axis_ids, &normalise/1) end)

    %{chain: chain}
  end

  # Power-cycle an axis into a known state: mastered, offset zero, referenced.
  # Done by writing the record and restarting rather than by calling master/2,
  # because master/2 zeroes the joint wherever the arm happens to be standing —
  # which would move every pose a later test computes.
  defp normalise(axis_id) do
    down(axis_id)
    rotor = Flash.rotor(axis_id) || 0.0
    Flash.master(axis_id, rotor, rotor)
    up(axis_id)
  end

  # A joint moved while the power was off.
  #
  # The record is written rather than the rotor moved, and the difference
  # matters: a supervisor shutdown does not run terminate/3, because the drive
  # deliberately does not trap exits — that is what lets a kill model a real
  # power cut. So there is no save to move the rotor away from. Writing the
  # record puts the disagreement there directly, and it is 0.4 whatever the arm
  # was doing when this file got the machine.
  defp lose_reference(axis_id) do
    down(axis_id)
    rotor = Flash.rotor(axis_id) || 0.0
    Flash.master(axis_id, rotor - 0.4, 0.0)
    up(axis_id)
  end

  # terminate_child stops without the supervisor restarting it, which is the
  # only way to open a window between the save and the boot.
  defp down(axis_id) do
    Supervisor.terminate_child(Exdrive.Supervisor, {Exdrive.Drive, axis_id})
  end

  defp up(axis_id) do
    case Supervisor.restart_child(Exdrive.Supervisor, {Exdrive.Drive, axis_id}) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  defp wait_until(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end

  test "the cell reports referenced when every joint knows where it is" do
    assert {:ok, true} = Source.read("cell.referenced", [])
  end

  test "the report has one entry per joint, in chain order", %{chain: chain} do
    assert {:ok, %{"axes" => axes}} = Source.call("cell.mastering", %{}, [])
    assert Enum.map(axes, & &1["axis"]) == Enum.map(chain.axis_ids, &to_string/1)
    assert Enum.all?(axes, &(&1["state"] == "referenced"))
  end

  test "a joint that lost its reference is named, with what it is missing",
       %{chain: chain} do
    axis = Enum.at(chain.axis_ids, 2)
    lose_reference(axis)

    assert {:ok, false} = Source.read("cell.referenced", [])

    {:ok, %{"axes" => axes}} = Source.call("cell.mastering", %{}, [])
    entry = Enum.find(axes, &(&1["axis"] == to_string(axis)))

    # The word, not a boolean. "unreferenced" and "unmastered" have different
    # recoveries and a pendant showing "not ready" for both is a pendant that
    # cannot tell an operator what to do next.
    assert entry["state"] == "unreferenced"
    assert_in_delta entry["drift"], 0.4, 1.0e-6
    # The zero survives — losing the turn count does not lose the joint zero.
    assert entry["offset"] != 0.0 or entry["drift"] != 0.0
  end

  test "mastering an axis over the wire recovers it", %{chain: chain} do
    axis = Enum.at(chain.axis_ids, 1)
    lose_reference(axis)

    assert {:ok, %{"offset" => offset}} =
             Source.call("cell.master_axis", %{"axis" => to_string(axis)}, [])

    assert is_float(offset)
    assert {:ok, true} = Source.read("cell.referenced", [])
  end

  test "a witness mark that is not at zero is carried through", %{chain: chain} do
    axis = Enum.at(chain.axis_ids, 1)
    lose_reference(axis)

    {:ok, _} = Source.call("cell.master_axis", %{"axis" => to_string(axis), "at" => -1.5708}, [])

    assert_in_delta Exdrive.Drive.status(axis).joint_position, -1.5708, 1.0e-3
  end

  test "mastering an axis that does not exist is a refusal, not a crash" do
    assert {:error, :rejected} = Source.call("cell.master_axis", %{"axis" => "no_such_axis"}, [])
  end

  test "mastering with no axis named is a refusal" do
    assert {:error, :rejected} = Source.call("cell.master_axis", %{}, [])
  end

  test "mastering is refused while the drive's output stage is on", %{chain: chain} do
    # The refusal lives in the drive rather than in a cell-level "is anything
    # moving" check, which would let you master a stationary-but-enabled axis —
    # exactly the case that stalls a current loop on real hardware.
    axis = hd(chain.axis_ids)
    Exdrive.Drive.enable(axis)
    wait_until(fn -> Exdrive.Drive.status(axis).state == :operation_enabled end)

    assert {:error, :rejected} =
             Source.call("cell.master_axis", %{"axis" => to_string(axis)}, [])
  end
end
