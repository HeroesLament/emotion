defmodule ExStore.ProgramsTest do
  use ExStore.DataCase

  alias ExStore.Program.{Statement, StatementRef}
  alias ExStore.{Points, Programs, Robots}

  @moduledoc """
  A program body is rows in order, and the order is the part worth testing.

  Sequence numbers are dense and start at zero after every edit, because sparse
  or duplicated ones work perfectly until somebody inserts a line at the top —
  and the identity a jump will use is the row's id, which never moves.
  """

  setup do
    {:ok, robot} =
      Robots.store(%{
        name: "arm#{System.unique_integer([:positive])}",
        urdf: "<robot/>",
        joints: [%{name: "a", lower: -1.0, upper: 1.0, max_vel: 1.0}]
      })

    {:ok, program} = Programs.create(%{name: "weld#{System.unique_integer([:positive])}"})
    %{program: program, robot: robot}
  end

  defp point_fixture(robot) do
    {:ok, point} =
      Points.teach(%{
        name: "p#{System.unique_integer([:positive])}",
        robot_id: robot.id,
        joints: [0.1]
      })

    point
  end

  describe "the body" do
    test "appends in order, from zero", %{program: program} do
      {:ok, _} = Programs.append(program, "wait", %{"seconds" => 1.0})
      {:ok, _} = Programs.append(program, "wait", %{"seconds" => 2.0})
      {:ok, _} = Programs.append(program, "wait", %{"seconds" => 3.0})

      assert [0, 1, 2] = Enum.map(Programs.body(program), & &1.seq)
      assert [1.0, 2.0, 3.0] = Enum.map(Programs.body(program), &Statement.args(&1)["seconds"])
    end

    test "literals round-trip as literals", %{program: program} do
      {:ok, _} = Programs.append(program, "move_linear", %{"feedrate" => 0.05, "blend" => 0.01})

      assert [statement] = Programs.body(program)
      assert Statement.args(statement) == %{"feedrate" => 0.05, "blend" => 0.01}
    end

    test "references are rows, not literals", %{program: program, robot: robot} do
      point = point_fixture(robot)

      {:ok, statement} =
        Programs.append(program, "move_linear", %{"feedrate" => 0.05}, %{"point" => {:point, point.id}})

      assert [ref] = statement.refs
      assert ref.arg_name == "point"
      assert StatementRef.referent(ref) == {:point, point.id}
      # And not smuggled into the literals, where the foreign key would be a comment.
      refute Map.has_key?(Statement.args(statement), "point")
    end

    test "removing a statement closes the gap", %{program: program} do
      for n <- 1..4, do: {:ok, _} = Programs.append(program, "wait", %{"seconds" => n / 1})

      [_first, second | _rest] = Programs.body(program)
      {:ok, :ok} = Programs.remove(second)

      body = Programs.body(program)
      assert Enum.map(body, & &1.seq) == [0, 1, 2]
      assert Enum.map(body, &Statement.args(&1)["seconds"]) == [1.0, 3.0, 4.0]
    end

    test "moving a statement slides the rest along", %{program: program} do
      for n <- 1..4, do: {:ok, _} = Programs.append(program, "wait", %{"seconds" => n / 1})

      [_a, _b, c, _d] = Programs.body(program)
      {:ok, :ok} = Programs.move(c, 0)

      assert Enum.map(Programs.body(program), &Statement.args(&1)["seconds"]) == [3.0, 1.0, 2.0, 4.0]
      assert Enum.map(Programs.body(program), & &1.seq) == [0, 1, 2, 3]
    end

    test "an id survives a renumbering, because a jump will use it", %{program: program} do
      for n <- 1..3, do: {:ok, _} = Programs.append(program, "wait", %{"seconds" => n / 1})

      [first, second, third] = Programs.body(program)
      {:ok, :ok} = Programs.move(third, 0)

      assert Enum.map(Programs.body(program), & &1.id) == [third.id, first.id, second.id]
    end

    test "replacing keeps the place and swaps the references", %{program: program, robot: robot} do
      a = point_fixture(robot)
      b = point_fixture(robot)

      {:ok, _} = Programs.append(program, "wait", %{"seconds" => 1.0})
      {:ok, statement} = Programs.append(program, "move_linear", %{}, %{"point" => {:point, a.id}})

      {:ok, _} = Programs.replace(statement, "move_joint", %{"speed" => 0.5}, %{"point" => {:point, b.id}})

      assert [_wait, moved] = Programs.body(program)
      assert moved.seq == 1
      assert moved.kind == "move_joint"
      assert [ref] = moved.refs
      assert StatementRef.referent(ref) == {:point, b.id}
    end
  end

  describe "what a program holds onto" do
    test "a point it moves to cannot be deleted", %{program: program, robot: robot} do
      point = point_fixture(robot)
      {:ok, _} = Programs.append(program, "move_linear", %{}, %{"point" => {:point, point.id}})

      assert {:error, changeset} = Points.delete(point)
      assert [message] = errors_on(changeset).id
      assert message =~ "used by a program"
    end

    test "and deleting the program releases it", %{program: program, robot: robot} do
      point = point_fixture(robot)
      {:ok, _} = Programs.append(program, "move_linear", %{}, %{"point" => {:point, point.id}})

      {:ok, _} = Programs.delete(program)
      assert {:ok, _} = Points.delete(point)
    end

    test "deleting a program takes its body with it", %{program: program} do
      {:ok, _} = Programs.append(program, "wait", %{"seconds" => 1.0})
      {:ok, _} = Programs.delete(program)

      assert Repo.aggregate(Statement, :count) == 0
      assert Repo.aggregate(StatementRef, :count) == 0
    end
  end

  describe "references point at exactly one thing" do
    test "and the database says so, not just the changeset", %{program: program, robot: robot} do
      point = point_fixture(robot)
      {:ok, statement} = Programs.append(program, "move_linear", %{}, %{"point" => {:point, point.id}})

      # Straight at the repo, bypassing the changeset that is careful to be
      # right — the constraint is what a future importer will meet, and what it
      # meets is a raise rather than a tuple, because a bare struct declares no
      # constraint for Ecto to convert.
      assert_raise Ecto.ConstraintError, ~r/exactly_one_referent/, fn ->
        Repo.insert(%StatementRef{
          statement_id: statement.id,
          arg_name: "sneaky",
          point_id: point.id,
          frame_id: 1
        })
      end
    end

    test "a reference to nothing at all is refused", %{program: program} do
      {:ok, statement} = Programs.append(program, "wait", %{"seconds" => 1.0})

      assert_raise Ecto.ConstraintError, ~r/exactly_one_referent/, fn ->
        Repo.insert(%StatementRef{statement_id: statement.id, arg_name: "empty"})
      end
    end
  end

  describe "programs" do
    test "are named like everything else" do
      assert {:error, _} = Programs.create(%{name: "Weld Cell"})
      assert {:ok, _} = Programs.create(%{name: "weld_cell"})
    end

    test "names are unique" do
      {:ok, _} = Programs.create(%{name: "pick"})
      assert {:error, _} = Programs.create(%{name: "pick"})
    end
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
