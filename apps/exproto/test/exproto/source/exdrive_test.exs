defmodule ExProto.Source.ExdriveTest do
  use ExUnit.Case, async: false

  alias ExProto.Source.Exdrive, as: Source

  @moduledoc """
  The source's writes, against a real drive.

  These exist because of one bug, found by hand and not by anything here: after a
  Cartesian jog the drives are left in `profile_velocity`, and a drive in that
  mode discards a position setpoint. Writing `target_position` stored the number,
  read it back, and told the client the write had succeeded — to an arm that had
  not moved and was never going to.

  Which is precisely the failure this module's docstring already describes for
  the PDS state, arrived at through the mode instead. Both have the same shape:
  the value the client is shown comes back from the drive, so it looks like
  evidence, and it is evidence of storage rather than of motion.
  """

  @axis "src_test_j1"
  @axis_id :src_test_j1

  setup do
    # The source refuses a jog when it cannot find a mode process, which is the
    # right way round — an absent interlock is not permission — and means a test
    # that jogs has to supply one.
    start_supervised!({ExProto.Jog, name: SourceTestJog})
    start_supervised!({ExProto.Mode, name: SourceTestMode, jog: SourceTestJog})

    case Exdrive.start_axis(@axis_id, clock: :external) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Exdrive.enable(@axis_id)
    wait_until(fn -> Exdrive.Drive.status(@axis_id).state == :operation_enabled end)

    Exdrive.Drive.set_mode(@axis_id, :profile_position)
    Exdrive.Drive.set_target_position(@axis_id, 0.0)
    settle()

    %{arg: [mode: SourceTestMode]}
  end

  describe "writing a position" do
    test "moves the axis" do
      assert {:ok, 0.5} = Source.write("axes.#{@axis}.target_position", 0.5, nil)

      settle()
      assert_in_delta Exdrive.Drive.status(@axis_id).actual_position, 0.5, 1.0e-3
    end

    test "moves the axis after a jog has left it in velocity mode", %{arg: arg} do
      # What a client does: jog, let go, then type a position in.
      assert :ok = Source.call("axes.#{@axis}.jog", %{"velocity" => 0.2}, arg)
      assert Exdrive.Drive.status(@axis_id).mode == :profile_velocity

      assert :ok = Source.call("axes.#{@axis}.jog", %{"velocity" => 0.0}, arg)
      settle()

      from = Exdrive.Drive.status(@axis_id).actual_position

      assert {:ok, _} = Source.write("axes.#{@axis}.target_position", from + 0.4, nil)
      settle()

      assert_in_delta Exdrive.Drive.status(@axis_id).actual_position, from + 0.4, 1.0e-3
    end

    test "is refused rather than stored when the drive cannot accept it" do
      Exdrive.Drive.control_word(@axis_id, 0x0000)
      wait_until(fn -> Exdrive.Drive.status(@axis_id).state != :operation_enabled end)

      assert {:error, :rejected} = Source.write("axes.#{@axis}.target_position", 1.0, nil)
    end
  end

  defp settle do
    for _ <- 1..300, do: Exdrive.Drive.tick(@axis_id, 0.01)
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end
end
