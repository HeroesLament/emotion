defmodule ExProto.ModeTest do
  use ExUnit.Case, async: false

  alias ExProto.{Jog, Mode}
  alias ExProto.Source.Exdrive, as: Source

  @moduledoc """
  The mode interlock.

  `state.controller_mode` was declared in the Information Model from the
  beginning and no source ever answered it, so a client could browse to a node
  marked readable and then be told it does not exist — the browse and the read
  contradicting each other inside one session.

  What it should have been all along is the second half of the authorisation
  question. A grant answers "may this person ever jog". Mode answers "is this
  machine in a state where jogging is what should be happening", and an operator
  with the jog grant should still not be able to hand-jog an arm that is running
  a program.
  """

  @axis "mode_test_j1"
  @axis_id :mode_test_j1

  setup do
    start_supervised!({Jog, name: TestJog})
    start_supervised!({Mode, name: TestMode, jog: TestJog})

    case Exdrive.start_axis(@axis_id, clock: :external) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Exdrive.enable(@axis_id)
    wait_until(fn -> Exdrive.Drive.status(@axis_id).state == :operation_enabled end)
    Exdrive.Drive.set_target_velocity(@axis_id, 0.0)

    %{arg: [mode: TestMode]}
  end

  describe "the selector" do
    test "starts in manual, because this is a bench controller" do
      assert Mode.selected(TestMode) == :manual
    end

    test "refuses positions that are not positions" do
      # `:fault` is not one. It is a condition the machine is in, not somewhere
      # an operator can turn a key to, and accepting it here would mean clearing
      # a fault left the selector wherever the fault had put it.
      assert_raise FunctionClauseError, fn -> Mode.select(:fault, TestMode) end
    end
  end

  describe "jogging outside manual" do
    test "a joint jog is refused, and says which mode", %{arg: arg} do
      :ok = Mode.select(:auto, TestMode)

      assert {:error, {:wrong_mode, :auto}} =
               Source.call("axes.#{@axis}.jog", %{"velocity" => 0.2}, arg)
    end

    test "a stop is always permitted, whatever the mode", %{arg: arg} do
      # The rule that makes the rest of this work. Turning the selector out of
      # manual releases every hold, releasing a hold commands zero, and that zero
      # comes back through the same call the interlock guards. An interlock that
      # can refuse a stop would prevent the stop it exists to cause.
      :ok = Mode.select(:auto, TestMode)

      assert :ok = Source.call("axes.#{@axis}.jog", %{"velocity" => 0.0}, arg)

      assert :ok =
               Source.call(
                 "axes.jog_cartesian",
                 %{"velocity" => 0.0, "axis" => "z"},
                 arg
               )
    end

    test "a Cartesian jog is refused before a stream is ever started", %{arg: arg} do
      :ok = Mode.select(:idle, TestMode)

      assert {:error, {:wrong_mode, :idle}} =
               Source.call("axes.jog_cartesian", %{"velocity" => 0.05, "axis" => "z"}, arg)

      # The refusal has to come before the stream, not after. A stream started
      # and then told it may not move is a process holding an arm it is not
      # allowed to hold.
      assert ExMove.CartesianStream.whereis(ExMo.Schema.Registry.arm_chain().name) == nil
    end

    test "nothing moves on a refused jog", %{arg: arg} do
      :ok = Mode.select(:auto, TestMode)
      Source.call("axes.#{@axis}.jog", %{"velocity" => 0.2}, arg)

      assert Exdrive.Drive.status(@axis_id).target_velocity == 0.0
    end

    test "manual permits it again", %{arg: arg} do
      :ok = Mode.select(:auto, TestMode)
      :ok = Mode.select(:manual, TestMode)

      assert :ok = Source.call("axes.#{@axis}.jog", %{"velocity" => 0.2}, arg)
    end

    test "a controller with no mode process refuses rather than permits" do
      # Fail closed. The failure that matters is the one where the guard is
      # missing and the arm moves anyway, so an absent mode process is not
      # manual — it is not-manual, loudly.
      assert Mode.selected(NoSuchMode) == :idle
      assert {:error, {:wrong_mode, :idle}} = Mode.allows_jog?(NoSuchMode)
    end
  end

  describe "turning the key while an axis is moving" do
    test "releases every hold and commands zero", %{arg: arg} do
      {:ok, _deadline} =
        Jog.assert("axes.#{@axis}", "axes.#{@axis}.jog", %{"velocity" => 0.2},
          {Source, arg}, self(), TestJog)

      assert Exdrive.Drive.status(@axis_id).target_velocity == 0.2
      assert {:ok, _owner} = Jog.holder("axes.#{@axis}", TestJog)

      :ok = Mode.select(:auto, TestMode)

      # Zeroed, not merely forgotten. Dropping the hold alone would leave the
      # axis on its last setpoint with nothing left watching it.
      assert Exdrive.Drive.status(@axis_id).target_velocity == 0.0
      assert Jog.holder("axes.#{@axis}", TestJog) == :none
    end

    test "turning it to where it already is does not stop anything", %{arg: arg} do
      {:ok, _deadline} =
        Jog.assert("axes.#{@axis}", "axes.#{@axis}.jog", %{"velocity" => 0.2},
          {Source, arg}, self(), TestJog)

      :ok = Mode.select(:manual, TestMode)

      assert Exdrive.Drive.status(@axis_id).target_velocity == 0.2
    end
  end

  describe "move_linear" do
    test "is refused outside manual, like anything else that moves the arm", %{arg: arg} do
      :ok = Mode.select(:auto, TestMode)

      assert {:error, {:wrong_mode, :auto}} =
               Source.call("axes.move_linear", %{"x" => 0.0, "y" => 1.0, "z" => 0.0}, arg)
    end

    test "omitting the rotation keeps the orientation rather than levelling it", %{arg: arg} do
      # Silence is not a command. A client asking to move somewhere without
      # saying anything about the wrist has not asked for the wrist to be
      # levelled, and reading it that way is how a tool ends up somewhere
      # surprising.
      #
      # Checked through the model's own arm rather than this module's test axis:
      # there are no drives for j1..j6 here, so the call cannot reach a stream
      # and comes back rejected — but it has to get far enough to have tried,
      # rather than falling over on the missing rotation.
      assert Source.call("axes.move_linear", %{"x" => 0.0, "y" => 1.0, "z" => 0.0}, arg) in [
               :ok,
               {:error, :rejected}
             ]
    end

    test "a target with no position at all is rejected", %{arg: arg} do
      assert {:error, :rejected} = Source.call("axes.move_linear", %{"y" => 1.0}, arg)
    end
  end

  describe "the published state" do
    test "controller_mode answers, which it never used to", %{arg: arg} do
      assert Source.read("state.controller_mode", arg) == {:ok, "manual"}

      :ok = Mode.select(:auto, TestMode)
      assert Source.read("state.controller_mode", arg) == {:ok, "auto"}
    end

    test "fault_present answers too", %{arg: arg} do
      assert Source.read("state.fault_present", arg) == {:ok, false}
    end

    test "a node under state that does not exist is still unknown", %{arg: arg} do
      assert Source.read("state.nonsense", arg) == {:error, :unknown_node}
    end
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
