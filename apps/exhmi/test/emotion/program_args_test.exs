defmodule EMotion.Program.ArgsTest do
  use ExUnit.Case, async: true

  alias EMotion.Program.{Args, Kinds}

  @moduledoc """
  Coercion is driven by the declared type, never by guessing at the string.

  The test that earns its place is the one about a point named "12": the mix
  task guesses with `Float.parse/1`, which is fine in a shell where a person
  sees what they typed, and silently wrong on a wire.
  """

  defp kind(name), do: Kinds.get(name)
  defp arg(name, value), do: %{"name" => name, "value" => value}

  test "a numeric socket parses its value" do
    assert {:ok, %{"feedrate" => 0.05}} =
             Args.coerce(kind("move_linear"), [arg("feedrate", "0.05")])
  end

  test "an integer-looking value still becomes a float" do
    # Every numeric parameter carries a physical dimension, and a feedrate of 1
    # is the same speed as a feedrate of 1.0. Storing one as an integer would
    # make the stored args differ by how somebody typed them.
    assert {:ok, %{"feedrate" => 1.0}} = Args.coerce(kind("move_linear"), [arg("feedrate", "1")])
  end

  test "a reference socket keeps its value as a name" do
    assert {:ok, %{"point" => "weld_start"}} =
             Args.coerce(kind("move_linear"), [arg("point", "weld_start")])
  end

  test "a point named like a number stays a name" do
    # The whole reason this module exists rather than reusing the mix task's
    # Float.parse guess. A point legitimately called "12" must not become 12.0
    # and then fail to resolve as a reference.
    assert {:ok, %{"point" => "12"}} = Args.coerce(kind("move_linear"), [arg("point", "12")])
  end

  test "a reference given as a number is refused, naming the socket" do
    assert {:error, {:bad_argument, "point", why}} =
             Args.coerce(kind("move_linear"), [%{"name" => "point", "value" => 12}])

    assert why =~ "named"
  end

  test "a numeric socket given something unreadable is refused, naming the socket" do
    assert {:error, {:bad_argument, "feedrate", why}} =
             Args.coerce(kind("move_linear"), [arg("feedrate", "quickly")])

    assert why =~ "number"
  end

  test "a client that sends a JSON number for a numeric socket is not wrong" do
    assert {:ok, %{"feedrate" => 0.05}} =
             Args.coerce(kind("move_linear"), [%{"name" => "feedrate", "value" => 0.05}])
  end

  test "a duration parses like any other number" do
    assert {:ok, %{"seconds" => 2.5}} = Args.coerce(kind("wait"), [arg("seconds", "2.5")])
  end

  test "an undeclared socket is passed through, not refused here" do
    # Editor refuses it, and says which sockets exist. Two layers refusing the
    # same thing differently is how error text drifts.
    assert {:ok, %{"nonsense" => "x"}} = Args.coerce(kind("wait"), [arg("nonsense", "x")])
  end

  test "an argument with no name is refused" do
    assert {:error, {:bad_argument, "args", _}} =
             Args.coerce(kind("wait"), [%{"value" => "2.0"}])
  end

  test "an empty reference is refused" do
    assert {:error, {:bad_argument, "point", _}} =
             Args.coerce(kind("move_joint"), [arg("point", "")])
  end

  test "no arguments is not an error" do
    assert {:ok, %{}} = Args.coerce(kind("wait"), [])
  end

  test "the first bad argument wins, so an editor gets one cursor position" do
    assert {:error, {:bad_argument, "feedrate", _}} =
             Args.coerce(kind("move_linear"), [
               arg("feedrate", "fast"),
               arg("point", "")
             ])
  end
end
