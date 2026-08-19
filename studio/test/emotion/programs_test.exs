defmodule EMotion.ProgramsTest do
  @moduledoc """
  The Programs tab, with no window and no controller.

  Which buttons are live in which run state is the part of this tab most likely
  to be wrong and the part an operator notices first, so it is tested directly
  rather than through a socket.
  """
  use ExUnit.Case, async: true

  alias EMotion.Programs

  defp kinds do
    [
      %{
        "name" => "move_joint",
        "label" => "Move Joint",
        "motion" => true,
        "params" => [%{"name" => "point", "type" => "point", "required" => true}]
      },
      %{
        "name" => "wait",
        "label" => "Wait",
        "motion" => false,
        "params" => [
          %{"name" => "seconds", "type" => "duration", "required" => true, "default" => 1.0}
        ]
      }
    ]
  end

  defp loaded do
    Programs.new()
    |> Programs.connected()
    |> Programs.kinds_loaded(kinds())
    |> Programs.points_loaded([%{"name" => "home"}, %{"name" => "away"}])
    |> Programs.loaded([%{"name" => "pick", "statements" => 2}, %{"name" => "place"}])
  end

  defp with_statements(state) do
    {state, _} = Programs.select(state, 0)

    Programs.shown(state, [
      %{"seq" => 0, "kind" => "move_joint", "refs" => "point=home", "args" => ""},
      %{"seq" => 1, "kind" => "wait", "refs" => "", "args" => "seconds=1.0"}
    ])
  end

  describe "before a controller" do
    test "nothing but nothing is offered" do
      e = Programs.enabled(Programs.new())
      refute e.new
      refute e.refresh
      refute e.start
      refute e.append
    end

    test "disconnecting forgets what it was showing" do
      # A list of programs from a controller that is no longer there is the
      # most confident kind of wrong.
      state = with_statements(loaded()) |> Programs.disconnected()
      assert state.programs == []
      assert state.statements == []
      assert state.kinds == []
      assert state.selected == nil
      assert state.status == "Not connected"
    end
  end

  describe "selection" do
    test "choosing a program asks for its statements" do
      {state, effects} = Programs.select(loaded(), 0)
      assert state.selected == "pick"
      assert :refresh in effects
    end

    test "choosing a program drops the old statements rather than showing them" do
      state = with_statements(loaded())
      {state, _} = Programs.select(state, 1)
      assert state.selected == "place"
      assert state.statements == []
    end

    test "a selection that no longer exists is dropped on reload" do
      state = with_statements(loaded()) |> Programs.loaded([%{"name" => "place"}])
      assert state.selected == nil
    end

    test "a statement selection that no longer exists is dropped" do
      state = with_statements(loaded()) |> Programs.select_statement(1)
      assert state.statement == 1
      state = Programs.shown(state, [%{"seq" => 0, "kind" => "wait"}])
      assert state.statement == nil
    end
  end

  describe "which buttons are live" do
    test "editing needs a program" do
      e = Programs.enabled(loaded())
      assert e.new
      refute e.delete
      refute e.append
      refute e.start
    end

    test "with a program chosen, editing and starting are offered" do
      state = with_statements(loaded())
      e = Programs.enabled(state)
      assert e.delete
      assert e.append
      assert e.start
      refute e.hold
      refute e.stop
    end

    test "remove and reorder need a statement" do
      state = with_statements(loaded())
      refute Programs.enabled(state).remove

      state = Programs.select_statement(state, 0)
      e = Programs.enabled(state)
      assert e.remove
      refute e.up, "the first statement cannot move up"
      assert e.down
    end

    test "the last statement cannot move down" do
      state = with_statements(loaded()) |> Programs.select_statement(1)
      e = Programs.enabled(state)
      assert e.up
      refute e.down
    end

    test "while running: hold and stop, nothing else" do
      state =
        with_statements(loaded())
        |> Programs.select_statement(0)
        |> Programs.ran(%{name: "pick", state: "running", statement: 0, statements: 2})

      e = Programs.enabled(state)
      assert e.hold
      assert e.stop
      refute e.start
      refute e.resume
      refute e.step
      refute e.append, "the running program may not be edited"
      refute e.remove
      refute e.delete
    end

    test "while held: resume, step and stop" do
      state =
        with_statements(loaded())
        |> Programs.ran(%{name: "pick", state: "held", statement: 1, statements: 2})

      e = Programs.enabled(state)
      assert e.resume
      assert e.step
      assert e.stop
      refute e.hold
      refute e.start
    end

    test "a different program stays editable while this one runs" do
      # Fixing the next job while the current one runs is most of what a shift
      # looks like, and the controller only refuses edits to the running one.
      state = loaded() |> Programs.ran(%{name: "pick", state: "running", statement: 0})
      {state, _} = Programs.select(state, 1)
      state = Programs.shown(state, [%{"seq" => 0, "kind" => "wait"}])

      e = Programs.enabled(state)
      assert e.append
      assert e.delete
      refute e.start, "still refused while something else runs"
    end
  end

  describe "the statement list" do
    test "marks where the run is" do
      state =
        with_statements(loaded())
        |> Programs.ran(%{name: "pick", state: "running", statement: 1, statements: 2})

      [first, second] = Programs.statement_labels(state)
      refute String.starts_with?(first, "▶")
      assert String.starts_with?(second, "▶")
    end

    test "marks nothing when the run is a different program" do
      state =
        with_statements(loaded())
        |> Programs.ran(%{name: "place", state: "running", statement: 1})

      refute Enum.any?(Programs.statement_labels(state), &String.starts_with?(&1, "▶"))
    end
  end

  describe "adding a statement takes two dialogs" do
    test "the first offers the kinds the controller declared" do
      state = with_statements(loaded())
      {_state, [{:dialog, :program_kind, opts}]} = Programs.action(state, :append)
      [{:kind, :choice, kind_opts}] = opts[:fields]
      assert kind_opts[:choices] == ["Move Joint", "Wait"]
    end

    test "the second is built from that kind's own parameters" do
      state = with_statements(loaded())
      {state, _} = Programs.action(state, :append)
      {state, [{:dialog, :program_args, opts}]} = Programs.dialog(state, :program_kind, {:ok, %{"kind" => 0}})

      assert state.pending_kind == "move_joint"
      # A point is a choice of taught points, not a spelling test.
      assert [{:point, :choice, point_opts}] = opts[:fields]
      assert point_opts[:choices] == ["home", "away"]
    end

    test "a duration gets a text field carrying the kind's default" do
      state = with_statements(loaded())

      {_state, [{:dialog, :program_args, opts}]} =
        Programs.dialog(state, :program_kind, {:ok, %{"kind" => 1}})

      assert [{:seconds, :text, seconds_opts}] = opts[:fields]
      assert seconds_opts[:value] == "1.0"
    end

    test "the answers become an append" do
      state = with_statements(loaded())
      {state, _} = Programs.dialog(state, :program_kind, {:ok, %{"kind" => 0}})
      {state, effects} = Programs.dialog(state, :program_args, {:ok, %{"point" => "away"}})

      assert [{:program, {:append, "pick", "move_joint", args}}, :refresh] = effects
      assert args == [%{"name" => "point", "value" => "away"}]
      assert state.pending_kind == nil
    end

    test "an optional field left empty is omitted, not sent as empty string" do
      # A socket the user left alone is one the controller should fill with its
      # own default. "" is a value, and it means something different.
      state =
        loaded()
        |> Programs.kinds_loaded([
          %{"name" => "move_linear", "label" => "Move Linear",
            "params" => [
              %{"name" => "point", "type" => "point", "required" => true},
              %{"name" => "feedrate", "type" => "velocity", "required" => false}
            ]}
        ])

      {state, _} = Programs.select(state, 0)
      {state, _} = Programs.dialog(state, :program_kind, {:ok, %{"kind" => 0}})
      {_state, effects} = Programs.dialog(state, :program_args, {:ok, %{"point" => "home", "feedrate" => "  "}})

      assert [{:program, {:append, _, _, args}}, :refresh] = effects
      assert args == [%{"name" => "point", "value" => "home"}]
    end

    test "cancelling forgets the pending kind" do
      state = with_statements(loaded())
      {state, _} = Programs.dialog(state, :program_kind, {:ok, %{"kind" => 0}})
      {state, effects} = Programs.dialog(state, :program_args, :cancel)
      assert state.pending_kind == nil
      assert effects == []
    end
  end

  describe "reordering" do
    test "the selection follows the statement, not the row" do
      # Moving something and then finding the next click acts on its neighbour
      # is how a wrong statement gets deleted.
      state = with_statements(loaded()) |> Programs.select_statement(1)
      {state, effects} = Programs.action(state, :up)

      assert [{:program, {:move, "pick", 1, 0}}, :refresh] = effects
      assert state.statement == 0
    end

    test "moving past either end does nothing" do
      state = with_statements(loaded()) |> Programs.select_statement(0)
      assert {_state, []} = Programs.action(state, :up)

      state = Programs.select_statement(state, 1)
      assert {_state, []} = Programs.action(state, :down)
    end
  end

  describe "what it says" do
    test "a refusal keeps the controller's own words and its detail" do
      state =
        Programs.failed(loaded(), %{
          "message" => "The controller's mode selector refuses this",
          "data" => %{"mode" => "manual"}
        })

      assert state.status =~ "mode selector"
      assert state.status =~ "manual"
    end

    test "a run describes itself with position" do
      state = Programs.ran(loaded(), %{name: "pick", state: "running", statement: 1, statements: 3})
      assert state.status == "pick: running at 1/3"
    end

    test "with no program loaded it says so rather than showing nils" do
      assert Programs.ran(loaded(), %{name: "", state: "", statement: 0}).status ==
               "No program loaded"
    end
  end

  describe "polling" do
    test "only while there is something to poll" do
      # A studio that asks a controller what it is doing twice a second forever
      # shows up in someone's bus trace as the reason a cycle is late.
      refute Programs.active?(loaded())
      assert Programs.active?(Programs.ran(loaded(), %{state: "running"}))
      assert Programs.active?(Programs.ran(loaded(), %{state: "held"}))
      refute Programs.active?(Programs.ran(loaded(), %{state: "done"}))
    end
  end
end
