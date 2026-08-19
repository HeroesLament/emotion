defmodule Exdrive.RestoreMasteringTest do
  @moduledoc """
  Giving a replacement board the number the old one knew.

  The interlock is the design: this may only write onto an axis that does not
  already know its zero. `MASTERING.md` explains what the alternative costs —
  "Nothing faults. You find out at the workpiece." — so the refusal exists to
  make that impossible rather than discouraged.
  """
  use ExUnit.Case, async: false

  alias Exdrive.{Drive, Flash}

  setup do
    axis = :"rm_#{System.unique_integer([:positive])}"
    Flash.erase(axis)

    {:ok, pid} =
      Drive.start_link(axis_id: axis, clock: :external, master_on_first_boot: false)

    on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)
    %{axis: axis, pid: pid}
  end

  describe "onto a fresh board" do
    test "an unmastered axis accepts the old board's number", %{axis: axis} do
      assert Drive.status(axis).mastering == :unmastered

      assert :ok = EMotion.Axis.restore_master_offset(axis, 0.125)

      status = Drive.status(axis)
      assert status.mastering == :referenced
      assert_in_delta status.master_offset, 0.125, 1.0e-9
    end

    test "the joint position becomes readable, which is the whole point", %{axis: axis} do
      # An unmastered axis has no joint position at all — that is what the
      # three states mean. Restoring one is what makes the arm usable again.
      assert Drive.status(axis).joint_position == nil
      assert :ok = EMotion.Axis.restore_master_offset(axis, 0.0)
      assert is_number(Drive.status(axis).joint_position)
    end
  end

  describe "the interlock" do
    test "an axis that already knows its zero refuses", %{axis: axis} do
      # The stale push, made impossible. This is the case where writing an
      # offset is exactly wrong, and it is the case a routine restore would hit.
      Drive.master(axis, 0.0)
      assert Drive.status(axis).mastering == :referenced

      assert {:error, :already_mastered} = EMotion.Axis.restore_master_offset(axis, 0.9)

      assert_in_delta Drive.status(axis).master_offset, 0.0, 1.0e-9,
                      "a refused restore must not have moved the zero"
    end

    test "refusing twice in a row leaves the first number alone", %{axis: axis} do
      Drive.master(axis, 0.25)
      before = Drive.status(axis).master_offset

      assert {:error, :already_mastered} = EMotion.Axis.restore_master_offset(axis, 1.0)
      assert {:error, :already_mastered} = EMotion.Axis.restore_master_offset(axis, 2.0)

      assert Drive.status(axis).master_offset == before
    end

    test "refused while the output is enabled", %{axis: axis} do
      # Same refusal mastering makes, for the same reason: an axis that could be
      # moving cannot truthfully be said to be anywhere.
      Drive.enable(axis)
      Process.sleep(20)
      assert Drive.status(axis).state == :operation_enabled

      assert {:error, :output_enabled} = EMotion.Axis.restore_master_offset(axis, 0.5)
    end
  end

  describe "it is not mastering" do
    test "mastering derives an offset; restoring is given one", %{axis: axis} do
      # master/2 says "the arm is at this angle, work out the offset".
      # restore says "your offset is this number".
      Flash.set_rotor(axis, 0.4)
      {:ok, pid} = Drive.start_link(axis_id: :"#{axis}_b", clock: :external, master_on_first_boot: false)
      on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)

      Drive.master(axis, 0.0)
      derived = Drive.status(axis).master_offset

      other = :"#{axis}_b"
      assert :ok = EMotion.Axis.restore_master_offset(other, 0.777)
      assert_in_delta Drive.status(other).master_offset, 0.777, 1.0e-9
      refute_in_delta derived, 0.777, 1.0e-6
    end

    test "the contract marks it optional, so a PWM axis need not pretend" do
      # A drive with no encoder has no zero to restore. Making this required
      # would force every implementation to grow a function that means nothing.
      assert {:restore_master_offset, 2} in EMotion.Drive.behaviour_info(:optional_callbacks)
      assert EMotion.Drive.supports?(:j1, {:restore_master_offset, 2})
    end
  end
end
