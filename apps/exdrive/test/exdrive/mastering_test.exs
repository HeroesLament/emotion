defmodule Exdrive.MasteringTest do
  @moduledoc """
  Mastering: what an axis knows about itself after a power cycle.

  Every test here is a power cycle. On a bench you get one per minute and you
  cannot choose where the axis stops; here you get hundreds and you can choose
  exactly — which is the only reason this behaviour can be trusted at all.

  The three states are not severity levels. They are different missing facts,
  and each owes the caller a different refusal:

    :unmastered   — no joint zero was ever declared
    :unreferenced — the zero is known, the turn count is not
    :referenced   — nothing is missing
  """

  use ExUnit.Case, async: false

  alias Exdrive.Drive
  alias Exdrive.Flash

  setup context do
    axis = :"m_#{:erlang.phash2(context.test)}"
    Flash.erase(axis)
    on_exit(fn -> Flash.erase(axis) end)
    {:ok, axis: axis}
  end

  # `master_on_first_boot: false` by default HERE, and only here: these tests
  # are about what an axis knows, so they need the real unmastered board rather
  # than the simulator's factory step. Everywhere else the default stands.
  defp start!(axis, opts \\ []) do
    opts =
      Keyword.merge([axis_id: axis, clock: :external, master_on_first_boot: false], opts)
    {:ok, pid} = Drive.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)
    pid
  end

  defp enabled!(axis) do
    start!(axis)
    enable!(axis)
  end

  # Enable a drive that is already up. Separate from enabled!/1 because half
  # these tests power-cycle mid-test and must not try to start it twice.
  defp enable!(axis) do
    Drive.enable(axis)
    %{state: :operation_enabled} = Drive.status(axis)
    axis
  end

  # A graceful power-down: terminate/3 runs, so the MASTER record is written.
  defp power_down(axis) do
    :gen_statem.stop(Process.whereis(:"exdrive_axis_#{axis}"))
  end

  # Yanking the plug: no terminate, so nothing is saved.
  defp power_cut(axis) do
    pid = Process.whereis(:"exdrive_axis_#{axis}")
    # Unlink first, or the kill propagates to the test process — start_link
    # linked them, and a :kill is not a signal anybody gets to trap.
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok), after: (1000 -> flunk("drive would not die"))
  end

  defp move_to(axis, position) do
    Drive.set_mode(axis, :profile_position)
    Drive.set_target_position(axis, position)
    # Kinematic follower, external clock: a few big steps get there.
    Enum.each(1..40, fn _ -> Drive.tick(axis, 0.05) end)
    Drive.status(axis)
  end

  # --- resolve/3, on its own ------------------------------------------------
  # The entire recovery decision is a function of (what flash said, where the
  # rotor is, how much slack). Worth being able to check without starting
  # anything, and worth keeping in step with resolve() in servo4257-rs.

  describe "resolve/3" do
    test "a blank page is a new board, not an error" do
      assert {:unmastered, 1.2, nil, nil} = Flash.resolve(nil, 1.2, 1.0e-3)
    end

    test "an untouched axis keeps its position and its zero" do
      rec = %Flash.Record{master_offset: 0.5, position: 2.0}
      assert {:referenced, 2.0, 0.5, drift} = Flash.resolve(rec, 2.0, 1.0e-3)
      assert drift == 0.0
    end

    test "the tolerance boundary is exact in both directions" do
      rec = %Flash.Record{master_offset: 0.0, position: 0.0}
      tol = 1.0e-3

      assert {:referenced, _, _, _} = Flash.resolve(rec, tol, tol)
      assert {:referenced, _, _, _} = Flash.resolve(rec, -tol, tol)
      assert {:unreferenced, _, _, _} = Flash.resolve(rec, tol * 1.001, tol)
      assert {:unreferenced, _, _, _} = Flash.resolve(rec, -tol * 1.001, tol)
    end

    test "a record with no offset restores position but grants nothing" do
      # The power-down save runs whether or not the axis was ever mastered. The
      # position comes back; permission does not.
      rec = %Flash.Record{master_offset: nil, position: 3.0}
      assert {:unmastered, 3.0, nil, _drift} = Flash.resolve(rec, 3.0, 1.0e-3)
    end

    test "losing the reference does not lose the zero" do
      rec = %Flash.Record{master_offset: 0.5, position: 2.0}
      assert {:unreferenced, 2.9, 0.5, drift} = Flash.resolve(rec, 2.9, 1.0e-3)
      assert_in_delta drift, 0.9, 1.0e-9
    end
  end

  test "a simulated axis ships mastered, because there is no witness mark to drive to",
       %{axis: axis} do
    # The one place the default applies. A real drive ships unmastered; this is
    # the simulator's factory step and it fires only on a blank page.
    {:ok, pid} = Drive.start_link(axis_id: axis, clock: :external)
    on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)

    status = Drive.status(axis)
    assert status.mastering == :referenced
    assert status.joint_position == 0.0
  end

  test "the factory step cannot re-master an axis that already has a record", %{axis: axis} do
    # If it could, every restart would silently re-zero a joint that had drifted
    # — which is the exact failure the drift check exists to catch.
    start!(axis)
    {:ok, _} = Drive.master(axis, 0.75)
    power_down(axis)

    {:ok, pid} = Drive.start_link(axis_id: axis, clock: :external)
    on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid) end)

    assert_in_delta Drive.status(axis).joint_position, 0.75, 1.0e-6
  end

  # --- A fresh board --------------------------------------------------------

  test "an axis nobody has mastered reports no joint position at all", %{axis: axis} do
    start!(axis)
    status = Drive.status(axis)

    assert status.mastering == :unmastered
    assert status.master_offset == nil

    # The accumulator is still a number — it has to be, or the axis could not
    # be jogged to the witness mark, and jogging there is the recovery.
    assert is_float(status.actual_position)
    # The joint angle is not, and that is the whole point.
    assert status.joint_position == nil
  end

  # --- Mastering ------------------------------------------------------------

  test "mastering at the witness mark makes the joint read zero there", %{axis: axis} do
    enabled!(axis)
    move_to(axis, 1.25)
    power_down(axis)

    start!(axis)
    assert {:ok, offset} = Drive.master(axis)
    assert_in_delta offset, 1.25, 1.0e-3

    status = Drive.status(axis)
    assert status.mastering == :referenced
    assert_in_delta status.joint_position, 0.0, 1.0e-3
  end

  test "a witness mark that is not at zero is supported", %{axis: axis} do
    # Some marks are at a hard stop deliberately outside the working range.
    # "This is minus ninety degrees" has to work as well as "this is zero".
    enabled!(axis)
    move_to(axis, 1.0)
    power_down(axis)

    start!(axis)
    assert {:ok, _} = Drive.master(axis, -1.5708)
    assert_in_delta Drive.status(axis).joint_position, -1.5708, 1.0e-3
  end

  test "mastering is refused while the output stage is on", %{axis: axis} do
    # Not fussiness. On real hardware a flash write stalls instruction fetch,
    # so committing with the coils energised stalls the current loop; and a
    # moving axis records a position that is stale by the time it lands.
    enabled!(axis)

    assert {:error, :output_enabled} = Drive.master(axis)
    assert Drive.status(axis).mastering == :unmastered
  end

  # --- Surviving a power cycle ---------------------------------------------

  test "a clean power-down comes back knowing where it is", %{axis: axis} do
    enabled!(axis)
    move_to(axis, 0.8)
    power_down(axis)
    start!(axis)
    {:ok, _} = Drive.master(axis)

    before = Drive.status(axis).joint_position

    power_down(axis)
    start!(axis)

    after_boot = Drive.status(axis)
    assert after_boot.mastering == :referenced
    assert_in_delta after_boot.joint_position, before, 1.0e-6
    assert after_boot.mastering_drift == 0.0
  end

  test "a joint moved while the power was off loses its reference, not its zero",
       %{axis: axis} do
    enabled!(axis)
    move_to(axis, 0.5)
    power_down(axis)
    start!(axis)
    {:ok, offset} = Drive.master(axis)
    power_down(axis)

    # Gravity, a person leaning on it, a rigging crew. Nothing told the drive.
    Flash.backdrive(axis, 0.3)
    start!(axis)

    status = Drive.status(axis)
    assert status.mastering == :unreferenced
    # The zero survives: it is a property of the machine, not of this boot.
    assert_in_delta status.master_offset, offset, 1.0e-9
    # The joint angle does not, and must not be guessable from the API.
    assert status.joint_position == nil
    assert_in_delta status.mastering_drift, 0.3, 1.0e-6
    # But the accumulator is still usable, because the recovery is a move.
    assert_in_delta status.actual_position, 0.8, 1.0e-3
  end

  test "noise below the tolerance does not cost a reference", %{axis: axis} do
    enabled!(axis)
    move_to(axis, 0.5)
    power_down(axis)
    start!(axis)
    {:ok, _} = Drive.master(axis)
    power_down(axis)

    # A tenth of the tolerance. The tolerance is a quantisation allowance, not
    # a movement allowance, so this must pass and 300 mrad must not.
    Flash.backdrive(axis, 1.0e-4)
    start!(axis)

    assert Drive.status(axis).mastering == :referenced
  end

  test "drift is reported even when it is inside tolerance", %{axis: axis} do
    # A drift that creeps toward the limit over months is a slipping coupling
    # or a loosening grub screw. Swallowing it because it passed is how that
    # finding is lost.
    enabled!(axis)
    power_down(axis)
    start!(axis)
    {:ok, _} = Drive.master(axis)
    power_down(axis)

    Flash.backdrive(axis, 5.0e-4)
    start!(axis)

    status = Drive.status(axis)
    assert status.mastering == :referenced
    assert_in_delta status.mastering_drift, 5.0e-4, 1.0e-9
  end

  test "a power cut after the axis moved loses the reference", %{axis: axis} do
    # The distinction the whole model turns on: terminate/3 runs on a graceful
    # stop and does not run on a kill. A drive that moved and then lost power
    # without saving comes back believing it is where it last saved.
    enabled!(axis)
    move_to(axis, 0.2)
    power_down(axis)
    start!(axis)
    {:ok, _} = Drive.master(axis)

    enable!(axis)
    move_to(axis, 1.4)
    power_cut(axis)

    start!(axis)
    assert Drive.status(axis).mastering == :unreferenced
  end

  # --- What a power-down may not do ----------------------------------------

  test "a power-down save cannot master an axis", %{axis: axis} do
    # If it could, a power cut at the wrong moment would declare a joint zero
    # wherever the arm happened to be hanging.
    enabled!(axis)
    move_to(axis, 0.7)
    power_down(axis)

    start!(axis)
    assert Drive.status(axis).mastering == :unmastered
    assert Drive.status(axis).master_offset == nil
  end

  test "a power-down save cannot unmaster an axis either", %{axis: axis} do
    enabled!(axis)
    power_down(axis)
    start!(axis)
    {:ok, offset} = Drive.master(axis, 0.25)

    enable!(axis)
    move_to(axis, 1.1)
    power_down(axis)
    start!(axis)

    status = Drive.status(axis)
    assert status.mastering == :referenced
    assert_in_delta status.master_offset, offset, 1.0e-9
  end

  # --- Erasing --------------------------------------------------------------

  test "erasing the page is a factory-fresh board, and the rotor does not move",
       %{axis: axis} do
    enabled!(axis)
    move_to(axis, 0.9)
    power_down(axis)
    start!(axis)
    {:ok, _} = Drive.master(axis)
    where = Drive.status(axis).actual_position
    power_down(axis)

    Flash.erase(axis)
    start!(axis)

    status = Drive.status(axis)
    assert status.mastering == :unmastered
    assert status.joint_position == nil
    # The metal did not move just because the flash was wiped.
    assert_in_delta status.actual_position, where, 1.0e-6
  end
end
