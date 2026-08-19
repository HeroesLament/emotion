defmodule ExProto.Source.ProgramEditTest do
  use ExUnit.Case, async: false

  alias ExProto.Source.Program, as: Source
  alias ExStore.{Points, Programs, Robots}

  @moduledoc """
  Editing a program over the protocol.

  Statement at a time, not whole-body, and that is the recorded decision rather
  than a shortcut — `protocol/README.md` puts bulk transfer on HTTP so it does
  not compete with live telemetry. What an editor does is small interactive
  edits, which is exactly what these are.

  The pairing worth understanding: **`program.validate` explains, the edit
  methods refuse.** `ExProto.Source`'s error vocabulary is a fixed set of
  atoms, so a `:rejected` cannot say which socket was wrong. Asking is a query
  that succeeds and describes; doing is a command that succeeds or does not.
  """

  setup do
    tag = System.unique_integer([:positive])

    # Not sandboxed — this app's tests run against the file, because the
    # processes under test are not descendants of the test process. So a robot
    # is established rather than assumed, and cleaned up below.
    robot =
      case Robots.active() do
        nil ->
          {:ok, fresh} =
            Robots.store(%{
              name: "bench#{tag}",
              urdf: "<robot/>",
              joints: Enum.map(1..6, &%{name: "joint#{&1}", lower: -3.05, upper: 3.05})
            })

          {:ok, active} = Robots.activate(fresh)
          active

        active ->
          active
      end

    {:ok, _point} =
      Points.teach(%{
        name: "p_t#{tag}",
        robot_id: robot.id,
        # Six either way: the shipped arctos and the bench robot above both
        # have six joints, and Points.teach refuses a vector of the wrong length.
        joints: List.duplicate(0.0, 6),
        x: 0.1,
        y: 0.0,
        z: 0.3
      })

    on_exit(fn ->
      for program <- Programs.list(), String.contains?(program.name, "t#{tag}") do
        Programs.delete(program)
      end

      case Points.by_name("p_t#{tag}") do
        nil -> :ok
        point -> Points.delete(point)
      end
    end)

    %{tag: tag, point: "p_t#{tag}", prog: "prog_t#{tag}"}
  end

  defp arg(name, value), do: %{"name" => name, "value" => value}

  defp create!(name) do
    assert :ok = Source.call("program.create", %{"name" => name}, [])
  end

  defp append!(prog, kind, args) do
    assert {:ok, %{"seq" => seq}} =
             Source.call("program.append", %{"program" => prog, "kind" => kind, "args" => args}, [])

    seq
  end

  defp body(prog) do
    {:ok, %{"statements" => statements}} = Source.call("program.show", %{"name" => prog}, [])
    statements
  end

  # ── The kind registry, which is what an editor is built from ─────────────

  describe "program.kinds" do
    test "every kind this build knows, with its sockets" do
      assert {:ok, %{"kinds" => kinds}} = Source.call("program.kinds", %{}, [])

      names = Enum.map(kinds, & &1["name"])
      assert "move_joint" in names
      assert "move_linear" in names
      assert "wait" in names
    end

    test "a socket carries its declared type, not a storage width" do
      # A block editor that knows a socket wants a :point can offer the points
      # that exist; one that sees "string" cannot.
      {:ok, %{"kinds" => kinds}} = Source.call("program.kinds", %{}, [])
      linear = Enum.find(kinds, &(&1["name"] == "move_linear"))

      point = Enum.find(linear["params"], &(&1["name"] == "point"))
      feed = Enum.find(linear["params"], &(&1["name"] == "feedrate"))

      assert point["type"] == "point"
      assert point["required"] == true
      assert feed["type"] == "velocity"
      assert feed["required"] == false
      assert feed["default"] != ""
    end

    test "motion is reported, because it is what decides a barrier" do
      {:ok, %{"kinds" => kinds}} = Source.call("program.kinds", %{}, [])

      assert Enum.find(kinds, &(&1["name"] == "move_linear"))["motion"] == true
      assert Enum.find(kinds, &(&1["name"] == "wait"))["motion"] == false
    end
  end

  # ── Validate explains; the edit methods refuse ───────────────────────────

  describe "program.validate" do
    test "a good statement validates", %{point: point} do
      assert {:ok, %{"ok" => true, "socket" => "", "reason" => ""}} =
               Source.call(
                 "program.validate",
                 %{"kind" => "move_linear", "args" => [arg("point", point)]},
                 []
               )
    end

    test "an unknown kind names no socket and lists what exists" do
      assert {:ok, %{"ok" => false, "socket" => "", "reason" => reason}} =
               Source.call("program.validate", %{"kind" => "teleport", "args" => []}, [])

      assert reason =~ "move_linear"
    end

    test "a missing required argument names the socket" do
      assert {:ok, %{"ok" => false, "socket" => "point", "reason" => reason}} =
               Source.call("program.validate", %{"kind" => "move_linear", "args" => []}, [])

      assert reason =~ "point"
    end

    test "an undeclared socket names itself and lists the real ones", %{point: point} do
      assert {:ok, %{"ok" => false, "socket" => "speed", "reason" => reason}} =
               Source.call(
                 "program.validate",
                 %{
                   "kind" => "move_linear",
                   "args" => [arg("point", point), arg("speed", "0.1")]
                 },
                 []
               )

      assert reason =~ "feedrate"
    end

    test "a value that will not parse names its socket", %{point: point} do
      assert {:ok, %{"ok" => false, "socket" => "feedrate", "reason" => reason}} =
               Source.call(
                 "program.validate",
                 %{
                   "kind" => "move_linear",
                   "args" => [arg("point", point), arg("feedrate", "quickly")]
                 },
                 []
               )

      assert reason =~ "number"
    end

    test "a point that does not exist is the failure an editor most wants inline" do
      assert {:ok, %{"ok" => false, "socket" => "point", "reason" => reason}} =
               Source.call(
                 "program.validate",
                 %{"kind" => "move_linear", "args" => [arg("point", "no_such_point")]},
                 []
               )

      assert reason =~ "no_such_point"
    end

    test "validating stores nothing", %{prog: prog, point: point} do
      create!(prog)

      Source.call(
        "program.validate",
        %{"kind" => "move_linear", "args" => [arg("point", point)]},
        []
      )

      assert body(prog) == []
    end
  end

  # ── Creating and deleting ────────────────────────────────────────────────

  test "a program is created empty", %{prog: prog} do
    create!(prog)
    assert Programs.by_name(prog)
    assert body(prog) == []
  end

  test "creating a name that exists is refused, not silently adopted", %{prog: prog} do
    # An editor that thinks it made a new program and is in fact appending to
    # an old one is the worst version of this call.
    create!(prog)
    assert {:error, :rejected} = Source.call("program.create", %{"name" => prog}, [])
  end

  test "a program with no name is refused" do
    assert {:error, :rejected} = Source.call("program.create", %{}, [])
  end

  test "deleting takes its statements and leaves the point alone", %{prog: prog, point: point} do
    create!(prog)
    append!(prog, "move_linear", [arg("point", point)])

    assert :ok = Source.call("program.delete", %{"name" => prog}, [])
    assert Programs.by_name(prog) == nil
    # The reference protected the POINT from deletion, not the other way round.
    assert Points.by_name(point)
  end

  test "deleting one that is not there is refused" do
    assert {:error, :rejected} = Source.call("program.delete", %{"name" => "nope"}, [])
  end

  # ── Appending ────────────────────────────────────────────────────────────

  test "statements land in order", %{prog: prog, point: point} do
    create!(prog)
    assert append!(prog, "move_joint", [arg("point", point)]) == 0
    assert append!(prog, "wait", [arg("seconds", "1.5")]) == 1
    assert append!(prog, "move_linear", [arg("point", point)]) == 2

    assert Enum.map(body(prog), & &1["kind"]) == ["move_joint", "wait", "move_linear"]
  end

  test "a reference given by name comes back rendered by name", %{prog: prog, point: point} do
    create!(prog)
    append!(prog, "move_linear", [arg("point", point)])

    assert [%{"refs" => refs}] = body(prog)
    assert refs =~ point
  end

  test "a literal is coerced by its declared type", %{prog: prog} do
    create!(prog)
    append!(prog, "wait", [arg("seconds", "2")])

    assert [%{"args" => args}] = body(prog)
    assert args =~ "2.0"
  end

  test "an unknown kind is refused", %{prog: prog} do
    create!(prog)

    assert {:error, :rejected} =
             Source.call("program.append", %{"program" => prog, "kind" => "teleport"}, [])
  end

  test "a point that does not exist is refused at store time, not at run time", %{prog: prog} do
    create!(prog)

    assert {:error, :rejected} =
             Source.call(
               "program.append",
               %{"program" => prog, "kind" => "move_linear", "args" => [arg("point", "nope")]},
               []
             )

    assert body(prog) == []
  end

  test "appending to a program that is not there is refused", %{point: point} do
    assert {:error, :rejected} =
             Source.call(
               "program.append",
               %{"program" => "nope", "kind" => "move_linear", "args" => [arg("point", point)]},
               []
             )
  end

  # ── Replacing, removing, moving ──────────────────────────────────────────

  test "replacing keeps the statement's place", %{prog: prog, point: point} do
    create!(prog)
    append!(prog, "move_joint", [arg("point", point)])
    append!(prog, "wait", [arg("seconds", "1.0")])

    assert :ok =
             Source.call(
               "program.replace",
               %{
                 "program" => prog,
                 "seq" => 0,
                 "kind" => "move_linear",
                 "args" => [arg("point", point)]
               },
               []
             )

    assert Enum.map(body(prog), & &1["kind"]) == ["move_linear", "wait"]
  end

  test "removing slides the rest up, so an editor never renders a hole",
       %{prog: prog, point: point} do
    create!(prog)
    append!(prog, "move_joint", [arg("point", point)])
    append!(prog, "wait", [arg("seconds", "1.0")])
    append!(prog, "move_linear", [arg("point", point)])

    assert :ok = Source.call("program.remove", %{"program" => prog, "seq" => 1}, [])

    assert Enum.map(body(prog), & &1["seq"]) == [0, 1]
    assert Enum.map(body(prog), & &1["kind"]) == ["move_joint", "move_linear"]
  end

  test "moving reorders and keeps sequence contiguous", %{prog: prog, point: point} do
    create!(prog)
    append!(prog, "move_joint", [arg("point", point)])
    append!(prog, "wait", [arg("seconds", "1.0")])
    append!(prog, "move_linear", [arg("point", point)])

    assert :ok = Source.call("program.move", %{"program" => prog, "seq" => 2, "to" => 0}, [])

    assert Enum.map(body(prog), & &1["kind"]) == ["move_linear", "move_joint", "wait"]
    assert Enum.map(body(prog), & &1["seq"]) == [0, 1, 2]
  end

  test "a statement that is not there is refused", %{prog: prog} do
    create!(prog)
    assert {:error, :rejected} = Source.call("program.remove", %{"program" => prog, "seq" => 7}, [])
  end

  test "a sequence that is not a number is refused", %{prog: prog} do
    create!(prog)

    assert {:error, :rejected} =
             Source.call("program.remove", %{"program" => prog, "seq" => "one"}, [])
  end
end
