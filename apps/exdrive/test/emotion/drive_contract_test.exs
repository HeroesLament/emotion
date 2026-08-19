defmodule EMotion.DriveContractTest do
  use ExUnit.Case, async: false

  alias EMotion.Drive

  defmodule Stub do
    @behaviour EMotion.Drive

    @impl true
    def status(axis_id),
      do: %{
        state: :switch_on_disabled,
        axis_id: axis_id,
        mode: :profile_position,
        actual_position: 0.0,
        actual_velocity: 0.0,
        joint_position: nil,
        mastering: :unmastered,
        stub: true
      }

    @impl true
    def set_target_position(_axis_id, _pos), do: :ok
    @impl true
    def set_target_velocity(_axis_id, _vel), do: :ok
    @impl true
    def set_mode(_axis_id, _mode), do: :ok
    @impl true
    def enable(_axis_id), do: :ok
    @impl true
    def control_word(_axis_id, _cw), do: :ok
    @impl true
    def quick_stop(_axis_id), do: :ok
    @impl true
    def fault_reset(_axis_id), do: :ok
    @impl true
    def master(_axis_id, _at), do: {:ok, 0.0}
  end

  defmodule OdStub do
    @behaviour EMotion.Drive.ObjectDictionary
    @impl true
    def read(_axis_id, _index, _sub), do: {:ok, 42}
    @impl true
    def write(_axis_id, _index, _sub, _value), do: :ok
  end

  setup do
    on_exit(fn -> Application.delete_env(:exdrive, :drives) end)
    :ok
  end

  describe "resolution" do
    test "an unconfigured axis gets the simulator" do
      # The right default: a controller with no configuration comes up
      # simulated rather than reaching for a bus that is not there.
      assert Drive.for(:j1) == Exdrive.Drive
    end

    test "a configured axis gets its own module" do
      Application.put_env(:exdrive, :drives, %{gripper: Stub})
      assert Drive.for(:gripper) == Stub
      assert Drive.for(:j1) == Exdrive.Drive
    end

    test "resolution is per axis, so a cell may mix drive types" do
      Application.put_env(:exdrive, :drives, %{gripper: Stub, j6: OdStub})
      assert Drive.for(:gripper) == Stub
      assert Drive.for(:j6) == OdStub
      assert Drive.for(:j1) == Exdrive.Drive
    end

    test "a binary axis id resolves the same as its atom" do
      # This is the bug class that hit Exdrive.Flash live and that no test
      # could see, because every test started drives the same way it looked
      # them up. Ask both ways on purpose.
      Application.put_env(:exdrive, :drives, %{gripper: Stub})
      assert Drive.for("gripper") == Drive.for(:gripper)
    end
  end

  describe "normalize_id/1" do
    test "an atom is already canonical" do
      assert Drive.normalize_id(:j1) == :j1
    end

    test "a binary becomes its atom" do
      assert Drive.normalize_id("j1") == :j1
    end

    test "an unknown binary raises rather than growing the atom table" do
      assert_raise ArgumentError, fn ->
        Drive.normalize_id("no_such_axis_#{System.unique_integer([:positive])}")
      end
    end
  end

  describe "optional capabilities" do
    test "the simulator does torque" do
      assert Drive.supports?(:j1, {:set_target_torque, 2})
    end

    test "a drive that omits an optional callback reports so" do
      Application.put_env(:exdrive, :drives, %{gripper: Stub})
      refute Drive.supports?(:gripper, {:set_target_torque, 2})
    end

    test "EMotion.Axis raises rather than silently dropping a torque command" do
      # A gripper that quietly ignores a torque command is a gripper that
      # crushes something once and is never suspected.
      Application.put_env(:exdrive, :drives, %{gripper: Stub})

      assert_raise ArgumentError, ~r/does not implement torque control/, fn ->
        EMotion.Axis.set_target_torque(:gripper, 1.0)
      end
    end
  end

  describe "object dictionary is optional and detectable" do
    test "the simulator has none" do
      # It is not a lie that has to be maintained: the simulator has no bus,
      # so it has no objects, so it does not claim to.
      refute Drive.object_dictionary?(:j1)
    end

    test "a drive that declares the behaviour reports true" do
      Application.put_env(:exdrive, :drives, %{j6: OdStub})
      assert Drive.object_dictionary?(:j6)
    end

    test "implementing EMotion.Drive does not imply an object dictionary" do
      Application.put_env(:exdrive, :drives, %{gripper: Stub})
      refute Drive.object_dictionary?(:gripper)
    end
  end

  describe "the simulator satisfies the contract" do
    test "it declares the behaviour" do
      assert Drive.implements?(Exdrive.Drive, EMotion.Drive)
      assert Drive.implements?(Exdrive.Drive, :gen_statem)
    end

    test "implements?/2 finds a behaviour that is not the first one declared" do
      # module_info(:attributes) emits one :behaviour entry per declaration, so
      # keyword access returns only the first. Exdrive.Drive declares
      # :gen_statem before EMotion.Drive, which is precisely the case the
      # obvious implementation gets wrong.
      entries = Keyword.get_values(Exdrive.Drive.module_info(:attributes), :behaviour)
      assert length(entries) > 1, "expected separate :behaviour entries"
      refute EMotion.Drive in List.first(entries)
      assert Drive.implements?(Exdrive.Drive, EMotion.Drive)
    end

    test "every required callback is exported" do
      for {fun, arity} <- [
            status: 1,
            set_target_position: 2,
            set_target_velocity: 2,
            set_mode: 2,
            enable: 1,
            control_word: 2,
            quick_stop: 1,
            fault_reset: 1,
            master: 2
          ] do
        assert function_exported?(Exdrive.Drive, fun, arity),
               "Exdrive.Drive is missing #{fun}/#{arity}"
      end
    end

    test "tick/2 is NOT in the contract" do
      # A real drive has its own clock. `tick/2` is how the simulator is told
      # time passed, and putting it in the contract would force every hardware
      # implementation to grow a function that means nothing.
      refute {:tick, 2} in EMotion.Drive.behaviour_info(:callbacks)
      assert function_exported?(Exdrive.Drive, :tick, 2)
    end
  end

  describe "EMotion.Axis delegates" do
    test "it routes to the configured drive, not the simulator" do
      Application.put_env(:exdrive, :drives, %{gripper: Stub})
      assert %{stub: true} = EMotion.Axis.status(:gripper)
    end

    test "an unconfigured axis still reaches a live simulated drive" do
      axis = :contract_test_j1
      {:ok, pid} = Exdrive.Drive.start_link(axis_id: axis, clock: :external)
      on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)

      status = EMotion.Axis.status(axis)
      refute Map.has_key?(status, :stub)
      assert status.axis_id == axis
    end
  end
end
