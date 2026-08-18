defmodule ExMove.MasteringTest do
  use ExUnit.Case, async: false

  alias Exdrive.Flash
  alias ExMove.{CartesianStream, Frame, JointState, Library, Mastering}

  @moduledoc """
  What an axis that does not know where it is is allowed to do.

  The interlock is not "the arm is broken, refuse everything". It is narrower
  and more useful than that: an unreferenced axis still has an accumulator, so
  it can still be jogged — **because driving to the witness mark is how it is
  recovered**. What it cannot do is contribute to a POSE. Forward kinematics,
  teaching, and Cartesian motion all build one, and a pose assembled from a
  guess does not look like a fault. It looks like a plausible position, and it
  is discovered at the workpiece.
  """

  setup context do
    axis_ids = for i <- 1..6, do: :"mst_#{:erlang.phash2(context.test)}_j#{i}"
    chain = %{Library.demo() | name: :"mastering_test_#{:erlang.phash2(context.test)}",
              axis_ids: axis_ids}

    for axis_id <- axis_ids do
      Flash.erase(axis_id)
      boot(axis_id)
    end

    on_exit(fn ->
      CartesianStream.release(chain.name)

      for axis_id <- axis_ids do
        halt(axis_id)
        Flash.erase(axis_id)
      end
    end)

    %{chain: chain, axis_ids: axis_ids}
  end

  # Started directly rather than through Exdrive.Supervisor, because these
  # tests power-cycle axes on purpose and a :permanent child would be restarted
  # underneath them — the backdrive would land after the drive had already come
  # back up, and enough stops would trip the supervisor's restart intensity and
  # take the whole app down with it.
  defp boot(axis_id, opts \\ []) do
    {:ok, pid} =
      Exdrive.Drive.start_link(Keyword.merge([axis_id: axis_id, clock: :external], opts))

    pid
  end

  # Tolerant on purpose. Between the lookup and the stop the drive can already
  # be gone — it is linked to the test process, and cleanup runs after that
  # process has exited. A cleanup helper that raises turns a passing test into
  # a failing one for a reason that has nothing to do with what it asserted.
  defp halt(axis_id) do
    case Process.whereis(:"exdrive_axis_#{axis_id}") do
      nil -> :ok
      pid -> :gen_statem.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  # Power-cycle one axis with the joint having been moved while it was off.
  defp lose_reference(axis_id) do
    halt(axis_id)
    Flash.backdrive(axis_id, 0.4)
    boot(axis_id)
    :ok
  end

  # --- The report -----------------------------------------------------------

  test "a freshly started simulated cell is referenced everywhere", %{chain: chain} do
    assert Mastering.check(chain) == :ok
    assert Enum.all?(Mastering.report(chain), &(&1.state == :referenced))
  end

  test "the report names every axis that is not ready, not just the first",
       %{chain: chain, axis_ids: axis_ids} do
    # An operator who has to power-cycle a cell wants the list. A sequence of
    # one-at-a-time refusals is six trips to the machine.
    [a, _, c | _] = axis_ids
    lose_reference(a)
    lose_reference(c)

    assert {:error, {:not_referenced, bad}} = Mastering.check(chain)
    assert Enum.map(bad, &elem(&1, 0)) == [a, c]
    assert Enum.all?(bad, fn {_axis, state} -> state == :unreferenced end)
  end

  test "the report carries drift even when it passed", %{chain: chain, axis_ids: [a | _]} do
    # A drift that creeps toward the limit over months is a slipping coupling.
    halt(a)
    Flash.backdrive(a, 5.0e-4)
    boot(a)

    assert Mastering.check(chain) == :ok
    entry = Enum.find(Mastering.report(chain), &(&1.axis_id == a))
    assert_in_delta entry.drift, 5.0e-4, 1.0e-9
  end

  # --- Reading a pose -------------------------------------------------------

  test "reading the joints refuses, and names the joint", %{chain: chain, axis_ids: axis_ids} do
    assert {:ok, %JointState{}} = JointState.read(chain)

    [_, b | _] = axis_ids
    lose_reference(b)

    assert {:error, {:unreferenced, ^b}} = JointState.read(chain)
  end

  test "an unmastered axis is refused differently from an unreferenced one",
       %{chain: chain, axis_ids: [a | _]} do
    # Different missing facts, different recoveries. An operator told only
    # "not ready" has to go and find out which.
    halt(a)
    Flash.erase(a)
    boot(a, master_on_first_boot: false)

    assert {:error, {:unmastered, ^a}} = JointState.read(chain)
  end

  # --- Cartesian motion -----------------------------------------------------

  test "a Cartesian move refuses at admission when a joint does not know where it is",
       %{chain: chain, axis_ids: axis_ids} do
    for axis_id <- axis_ids, do: Exdrive.Drive.enable(axis_id)
    wait_for_enabled(axis_ids)

    [_, _, c | _] = axis_ids
    lose_reference(c)
    Exdrive.Drive.enable(c)

    # The solver would happily produce a joint vector from a pose built on a
    # guess, and every number downstream of it would look reasonable.
    assert {:error, {:not_referenced, [{^c, :unreferenced}]}} =
             CartesianStream.hold(chain, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0], clock: :external)

    # And it refused at admission rather than starting a stream that quietly
    # never moves — which is what the caller would otherwise have to notice.
    assert CartesianStream.whereis(chain.name) == nil
  end

  test "the same jog is accepted once the axis is referenced again",
       %{chain: chain, axis_ids: axis_ids} do
    # The refusal has to be about the missing fact, not about the stream having
    # been poisoned by having once seen a bad axis.
    for axis_id <- axis_ids, do: Exdrive.Drive.enable(axis_id)
    wait_for_enabled(axis_ids)

    [_, _, c | _] = axis_ids
    lose_reference(c)
    Exdrive.Drive.enable(c)

    assert {:error, {:not_referenced, [{^c, :unreferenced}]}} =
             CartesianStream.hold(chain, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0], clock: :external)

    # Re-master where it is. This is exactly the recovery: jog to the witness
    # mark, declare it.
    Exdrive.Drive.control_word(c, 0x0006)
    wait_until(fn -> Exdrive.Drive.status(c).state != :operation_enabled end)
    {:ok, _} = Exdrive.Drive.master(c)
    Exdrive.Drive.enable(c)
    wait_for_enabled(axis_ids)

    assert :ok = CartesianStream.hold(chain, [0.05, 0.0, 0.0, 0.0, 0.0, 0.0], clock: :external)
  end

  defp wait_for_enabled(axis_ids), do: Enum.each(axis_ids, &wait_enabled/1)

  defp wait_enabled(axis_id) do
    wait_until(fn -> Exdrive.Drive.status(axis_id).state == :operation_enabled end)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end
end
