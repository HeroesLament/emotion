defmodule ExStore.MasteringsTest do
  use ExStore.DataCase

  alias ExStore.{Masterings, Robots}

  @moduledoc """
  The shadow, and what it is for.

  The tests that earn their space are about `compare/3`, because that is the
  only place a re-mastered axis can be caught. Everything else about a
  re-mastered cell looks fine: every joint reports a plausible angle, every
  move executes cleanly, and the work lands in the wrong place.
  """

  @joints [
    %{name: "j_a", lower: -3.0, upper: 3.0, max_vel: 1.0},
    %{name: "j_b", lower: -3.0, upper: 3.0, max_vel: 1.0}
  ]

  setup do
    {:ok, robot} =
      Robots.store(%{
        name: "arm#{System.unique_integer([:positive])}",
        urdf: "<robot name=\"arm\"/>",
        joints: @joints
      })

    %{robot: robot}
  end

  defp observe(robot, axis, offset, state \\ "referenced", source \\ "observed") do
    {:ok, m} =
      Masterings.record(%{
        robot_id: robot.id,
        axis_id: axis,
        offset: offset,
        state: state,
        source: source
      })

    m
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # --- Recording ------------------------------------------------------------

  test "recording twice keeps both, because the old value is what you want on a bad day",
       %{robot: robot} do
    observe(robot, "j1", 0.25)
    observe(robot, "j1", 0.90)

    assert length(Masterings.history(robot.id, "j1")) == 2
    assert Masterings.current(robot.id)["j1"].offset == 0.90
  end

  test "the newest row wins even when two share a timestamp", %{robot: robot} do
    # Timestamps have second resolution and a restore writes every axis at
    # once, so ordering by time alone would make "newest" arbitrary on exactly
    # the operation that most needs to be reconstructable.
    a = observe(robot, "j1", 0.1)
    b = observe(robot, "j1", 0.2)
    assert a.inserted_at == b.inserted_at
    assert Masterings.current(robot.id)["j1"].offset == 0.2
  end

  test "an unmastered axis has no offset to record", %{robot: robot} do
    assert {:error, changeset} =
             Masterings.record(%{
               robot_id: robot.id,
               axis_id: "j1",
               offset: 0.0,
               state: "unmastered"
             })

    assert "an unmastered axis has no offset to record" in errors_on(changeset).state
  end

  test "a row for a robot that does not exist is refused" do
    # It RAISES rather than returning a changeset, and that is not an
    # oversight: SQLite reports a foreign-key violation with no constraint
    # name at all, so `foreign_key_constraint/3` has nothing to match on and
    # can never fire. Asserting the raise records the database's behaviour
    # instead of a changeset error that will never appear.
    assert_raise Ecto.ConstraintError, fn ->
      Masterings.record(%{
        robot_id: 999_999,
        axis_id: "j1",
        offset: 0.0,
        state: "referenced"
      })
    end
  end

  test "history is newest first and bounded", %{robot: robot} do
    for i <- 1..5, do: observe(robot, "j1", i / 10)
    history = Masterings.history(robot.id, "j1", 3)

    assert length(history) == 3
    assert Enum.map(history, & &1.offset) == [0.5, 0.4, 0.3]
  end

  test "history is per axis", %{robot: robot} do
    observe(robot, "j1", 0.1)
    observe(robot, "j2", 0.2)

    assert [%{offset: 0.1}] = Masterings.history(robot.id, "j1")
  end

  # --- Comparing: the reason this module exists ----------------------------

  test "a fleet that agrees with its shadow produces nothing to say", %{robot: robot} do
    observe(robot, "j1", 0.25)
    observe(robot, "j2", -1.5)

    assert Masterings.compare(robot.id, %{"j1" => 0.25, "j2" => -1.5}) == []
  end

  test "an axis re-mastered underneath the cell is reported", %{robot: robot} do
    # This is the finding. Every taught point on this robot has just moved by
    # the difference, and nothing else in the system will notice.
    observe(robot, "j1", 0.25)

    assert [{:changed, "j1", was, now}] = Masterings.compare(robot.id, %{"j1" => 0.31})
    assert was == 0.25
    assert now == 0.31
  end

  test "an axis that lost its zero is reported separately from one that changed it",
       %{robot: robot} do
    # A replaced board and a re-mastered one are different events with
    # different recoveries, and collapsing them into "mismatch" would lose
    # the one piece of information the operator needs.
    observe(robot, "j1", 0.25)
    observe(robot, "j2", 0.40)

    assert [{:lost, "j1", 0.25}, {:changed, "j2", 0.40, 0.9}] =
             Masterings.compare(robot.id, %{"j1" => nil, "j2" => 0.9})
  end

  test "an axis reporting a zero for the first time is new, not changed", %{robot: robot} do
    assert [{:new, "j1", 0.25}] = Masterings.compare(robot.id, %{"j1" => 0.25})
  end

  test "an axis that has never had a zero and still has none says nothing", %{robot: robot} do
    assert Masterings.compare(robot.id, %{"j1" => nil}) == []
  end

  test "float noise is not a change", %{robot: robot} do
    observe(robot, "j1", 0.1 + 0.2)
    assert Masterings.compare(robot.id, %{"j1" => 0.30000000000000004}) == []
  end

  test "findings come back in a stable order", %{robot: robot} do
    # An operator comparing two boot logs should be diffing content, not
    # re-reading a map's iteration order.
    for axis <- ["j3", "j1", "j2"], do: observe(robot, axis, 0.0)
    observed = %{"j3" => 1.0, "j1" => 1.0, "j2" => 1.0}

    assert [{:changed, "j1", _, _}, {:changed, "j2", _, _}, {:changed, "j3", _, _}] =
             Masterings.compare(robot.id, observed)
  end

  test "one robot's shadow is not another's", %{robot: robot} do
    {:ok, other} =
      Robots.store(%{name: "other", urdf: "<robot name=\"o\"/>", joints: @joints})

    observe(robot, "j1", 0.25)

    assert Masterings.compare(other.id, %{"j1" => 0.25}) == [{:new, "j1", 0.25}]
  end

  # --- Snapshotting ---------------------------------------------------------

  test "a snapshot records what the fleet says and skips what it does not",
       %{robot: robot} do
    # "No joint zero" is not an offset of nought. A row saying otherwise is a
    # fabricated fact that outlives the boot that invented it.
    Masterings.snapshot(robot.id, %{
      "j1" => %{offset: 0.25, state: "referenced"},
      "j2" => %{offset: nil, state: "unmastered"}
    })

    current = Masterings.current(robot.id)
    assert current["j1"].offset == 0.25
    refute Map.has_key?(current, "j2")
  end

  test "a snapshot can say where it came from", %{robot: robot} do
    Masterings.snapshot(
      robot.id,
      %{"j1" => %{offset: 0.25, state: "referenced"}},
      source: "restored",
      note: "board swap, j1"
    )

    row = Masterings.current(robot.id)["j1"]
    assert row.source == "restored"
    assert row.note == "board swap, j1"
  end

  test "a snapshot round-trips through compare with nothing to say", %{robot: robot} do
    fleet = %{"j1" => %{offset: 0.25, state: "referenced"}, "j2" => %{offset: -1.0, state: "referenced"}}
    Masterings.snapshot(robot.id, fleet)

    observed = Map.new(fleet, fn {axis, %{offset: o}} -> {axis, o} end)
    assert Masterings.compare(robot.id, observed) == []
  end
end
