defmodule ExMo.Program.EditorTest do
  use ExUnit.Case, async: false

  alias ExMo.Program.{Editor, Kinds}
  alias ExStore.Program.{Statement, StatementRef}
  alias ExStore.{Points, Programs, Robots}

  @moduledoc """
  A statement is refused when it is stored, not when it is reached.

  That is the whole return on typed parameters, and every test here is a
  refusal that would otherwise have become a program that loads, looks fine on
  a pendant, and stops the arm halfway down the list.
  """

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ExStore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, robot} =
      Robots.store(%{name: "arm", urdf: "<robot/>", joints: [%{name: "a", lower: -1.0, upper: 1.0}]})

    {:ok, point} = Points.teach(%{name: "weld_start", robot_id: robot.id, joints: [0.1]})
    {:ok, program} = Programs.create(%{name: "weld"})

    %{program: program, point: point}
  end

  describe "the registry" do
    test "knows four kinds, and three of them move the arm" do
      assert length(Kinds.all()) == 4
      assert Enum.count(Kinds.all(), & &1.motion?) == 3
      refute Kinds.motion?("wait")
    end

    test "an unknown kind names the ones that exist" do
      assert {:error, {:unknown_kind, message}} = Editor.append(%ExStore.Program.Program{id: 1}, "weld_on", %{})
      assert message =~ "move_joint"
      assert message =~ "wait"
    end
  end

  describe "references" do
    test "arrive as names and are stored as foreign keys", %{program: program, point: point} do
      assert {:ok, statement} = Editor.append(program, "move_linear", %{"point" => "weld_start"})

      assert [ref] = statement.refs
      assert StatementRef.referent(ref) == {:point, point.id}
    end

    test "a point that does not exist is refused, by name", %{program: program} do
      assert {:error, {:unknown_point, message}} =
               Editor.append(program, "move_linear", %{"point" => "weld_finish"})

      assert message =~ "weld_finish"
    end
  end

  describe "literals" do
    test "defaults are applied rather than left absent", %{program: program} do
      {:ok, statement} = Editor.append(program, "move_linear", %{"point" => "weld_start"})
      assert Statement.args(statement)["feedrate"] == 0.125
    end

    test "an integer is stored as a float, because the machine works in floats", %{program: program} do
      {:ok, statement} = Editor.append(program, "wait", %{"seconds" => 2})
      assert Statement.args(statement)["seconds"] === 2.0
    end

    test "a duration of zero is refused", %{program: program} do
      # Not pedantry: `wait 0` reads as a statement that does something and is a
      # statement that does nothing, which is worse than an error.
      assert {:error, {:wrong_value, _}} = Editor.append(program, "wait", %{"seconds" => 0})
      assert {:error, {:wrong_value, _}} = Editor.append(program, "move_linear",
               %{"point" => "weld_start", "feedrate" => -0.1})
    end

    test "a string where a number belongs is refused", %{program: program} do
      assert {:error, {:wrong_type, _}} = Editor.append(program, "wait", %{"seconds" => "two"})
    end
  end

  describe "arguments as a whole" do
    test "a missing required argument is refused, and says which", %{program: program} do
      assert {:error, {:missing_argument, message}} = Editor.append(program, "move_linear", %{})
      assert message =~ "point"
    end

    test "a socket that does not exist is refused rather than dropped", %{program: program} do
      # The most likely mistake a client makes, and ignoring it produces a
      # statement that is valid, stored, and not what anybody wrote.
      assert {:error, {:unknown_argument, message}} =
               Editor.append(program, "move_linear", %{"point" => "weld_start", "feedrat" => 0.05})

      assert message =~ "feedrat"
      assert message =~ "feedrate"
    end
  end

  describe "replacing" do
    test "validates the new kind the same way", %{program: program} do
      {:ok, statement} = Editor.append(program, "wait", %{"seconds" => 1})

      assert {:error, {:missing_argument, _}} = Editor.replace(statement, "move_linear", %{})
      assert {:ok, replaced} = Editor.replace(statement, "move_linear", %{"point" => "weld_start"})
      assert replaced.kind == "move_linear"
      assert replaced.seq == statement.seq
    end
  end
end
