defmodule EMotion.Workbench.RegistryTest do
  use ExUnit.Case, async: false

  alias EMotion.Workbench
  alias EMotion.Workbench.{Command, Registry}

  defmodule Alpha do
    @behaviour Workbench
    @impl true
    def name, do: "Alpha"
    @impl true
    def description, do: "First"
    @impl true
    def init(_cell), do: {:ok, %{}}

    @impl true
    def commands do
      [
        %Command{id: :go, label: "Go", group: :run},
        %Command{id: :stop, label: "Stop", group: :run},
        %Command{id: :setup, label: "Setup", group: :config}
      ]
    end
  end

  defmodule Zulu do
    @behaviour Workbench
    @impl true
    def name, do: "Zulu"
    @impl true
    def init(_cell), do: {:ok, %{}}
  end

  defmodule NotAWorkbench do
    def name, do: "Impostor"
  end

  setup do
    original = Application.get_env(:emotion_studio, :workbenches)

    on_exit(fn ->
      if original do
        Application.put_env(:emotion_studio, :workbenches, original)
      else
        Application.delete_env(:emotion_studio, :workbenches)
      end

      Application.delete_env(:emotion_studio, :exclude_workbenches)
      Registry.refresh()
    end)

    :ok
  end

  describe "explicit configuration" do
    test "fixes the set and the order" do
      # What a shipped machine wants: no surprises from whatever happens to be
      # on the code path.
      Application.put_env(:emotion_studio, :workbenches, [Zulu, Alpha])
      Registry.refresh()

      assert Registry.all() == [Zulu, Alpha]
      assert Registry.default() == Zulu
    end

    test "filters out anything that is not a workbench" do
      Application.put_env(:emotion_studio, :workbenches, [Alpha, NotAWorkbench])
      Registry.refresh()

      assert Registry.all() == [Alpha]
    end
  end

  describe "discovery" do
    setup do
      Application.delete_env(:emotion_studio, :workbenches)
      Registry.refresh()
      :ok
    end

    # Discovery reads each loaded application's module list, which is what
    # makes "be a dependency" the whole registration step - and also means the
    # Alpha and Zulu modules defined in this file are invisible to it, because
    # a module compiled by a test file belongs to no application. So the real
    # mechanism is proven against a workbench that genuinely ships inside an
    # application: the built-in one.

    test "finds workbenches that ship inside an application" do
      assert EMotion.Workbenches.Cell in Registry.all()
    end

    test "does not find modules that belong to no application" do
      # Documenting the boundary rather than working around it. A workbench
      # has to live in an app to be found, which is the property that keeps
      # discovery from having to scan the whole code path.
      refute Alpha in Registry.all()
    end

    test "ignores modules that merely look like one" do
      refute NotAWorkbench in Registry.all()
    end

    test "sorts by display name, not by load order" do
      names = Enum.map(Registry.all(), & &1.name())
      assert names == Enum.sort(names)
    end

    test "exclusions are honoured" do
      assert EMotion.Workbenches.Cell in Registry.all()

      Application.put_env(:emotion_studio, :exclude_workbenches, [EMotion.Workbenches.Cell])
      Registry.refresh()

      refute EMotion.Workbenches.Cell in Registry.all()
    end
  end

  describe "the built-in workbench" do
    setup do
      Application.delete_env(:emotion_studio, :workbenches)
      Registry.refresh()
      :ok
    end

    alias EMotion.Cell, as: Doc
    alias EMotion.Workbenches.Cell, as: Bench

    test "initialises against an empty cell" do
      assert {:ok, %{selected: nil}} = Bench.init(Doc.new())
    end

    test "selects the first robot when there is one" do
      robot = %Doc.Robot{id: :arm_a, name: "Arm", joints: [0.0, 0.0]}
      {:ok, cell} = Doc.apply_change(Doc.new(), {:add_robot, robot})

      assert {:ok, %{selected: :arm_a}} = Bench.init(cell)
    end

    test "homing returns a change rather than mutating the document" do
      # A workbench never edits the cell itself, so every edit funnels through
      # one path and can be undone.
      robot = %Doc.Robot{id: :arm_a, name: "Arm", joints: [0.3, -0.2, 1.0]}
      {:ok, cell} = Doc.apply_change(Doc.new(), {:add_robot, robot})
      {:ok, state} = Bench.init(cell)

      assert {:ok, ^state, [{:set_joints, :arm_a, [0.0, 0.0, 0.0]}]} =
               Bench.handle_event({:command, :home}, state, %{cell: cell})
    end

    test "homing a robot that vanished clears the selection instead of failing" do
      robot = %Doc.Robot{id: :arm_a, name: "Arm", joints: [0.0]}
      {:ok, cell} = Doc.apply_change(Doc.new(), {:add_robot, robot})
      {:ok, state} = Bench.init(cell)
      {:ok, empty} = Doc.apply_change(cell, {:remove_robot, :arm_a})

      assert {:ok, %{selected: nil}} =
               Bench.handle_event({:command, :home}, state, %{cell: empty})
    end

    test "commands that need a robot are disabled without one" do
      commands = Map.new(Bench.commands(), &{&1.id, &1})

      refute Command.enabled?(commands[:home], %{cell: Doc.new()})
      assert Command.enabled?(commands[:add_robot], %{cell: Doc.new()})
    end

    test "an unknown event is ignored rather than crashing the shell" do
      {:ok, state} = Bench.init(Doc.new())

      assert {:ok, ^state} =
               Bench.handle_event({:command, :nonexistent}, state, %{cell: Doc.new()})
    end
  end

  describe "fetch/1" do
    setup do
      Application.put_env(:emotion_studio, :workbenches, [Alpha, Zulu])
      Registry.refresh()
      :ok
    end

    test "by module" do
      assert Registry.fetch(Alpha) == {:ok, Alpha}
      assert Registry.fetch(NotAWorkbench) == :error
    end

    test "by name, which is what a saved cell stores" do
      # Storing a module name in a document means renaming a module breaks
      # every file that used it.
      assert Registry.fetch("Alpha") == {:ok, Alpha}
      assert Registry.fetch("Nonexistent") == :error
    end

    test "listing carries name and description for a switcher" do
      assert {Alpha, "Alpha", "First"} in Registry.listing()
      # description/0 is optional, and its absence is not a crash.
      assert {Zulu, "Zulu", ""} in Registry.listing()
    end
  end

  describe "scoping" do
    test "ids are namespaced to their workbench" do
      # Two benches with a :speed slider would otherwise collide, and the
      # symptom would be a control that drives the wrong thing.
      assert Workbench.scope(Alpha, :speed) != Workbench.scope(Zulu, :speed)
      assert Workbench.owner(Workbench.scope(Alpha, :speed)) == Alpha
    end

    test "shell-owned ids have no workbench" do
      assert Workbench.owner(:save_btn) == nil
      assert Workbench.owner({:some, :tuple}) == nil
    end
  end

  describe "commands" do
    test "group in a stable order" do
      assert [{:config, [setup]}, {:run, [go, stop]}] = Command.by_group(Alpha.commands())
      assert setup.id == :setup
      assert [go.id, stop.id] == [:go, :stop]
    end

    test "are enabled by default" do
      assert Command.enabled?(%Command{id: :x, label: "X"}, %{})
    end

    test "a predicate decides against the context" do
      command = %Command{id: :sim, label: "Simulate", enabled?: &(&1.cell != nil)}

      assert Command.enabled?(command, %{cell: :something})
      refute Command.enabled?(command, %{cell: nil})
    end

    test "a broken predicate greys the button out instead of taking the window down" do
      # It runs inside view/1. A third-party bench with a buggy predicate
      # should disable its own control, not crash the scene.
      command = %Command{id: :bad, label: "Bad", enabled?: fn _ -> raise "oops" end}

      refute Command.enabled?(command, %{})
    end

    test "a predicate returning a non-boolean is not truthy by accident" do
      command = %Command{id: :odd, label: "Odd", enabled?: fn _ -> :maybe end}

      refute Command.enabled?(command, %{})
    end
  end
end
