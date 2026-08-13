defmodule EMotion.Workbench do
  @moduledoc """
  A mode of working: the tools, panels and viewport overlays for one kind of
  job.

  Borrowed from FreeCAD, and for the same reason. A robot cell is one document,
  but programming a welding path, planning a scan sweep and calibrating a tool
  frame want completely different controls in front of them. Cramming all of
  them into one interface produces a wall of buttons where nothing is findable;
  splitting them into applications means the cell has to be exported between
  them. A workbench swaps the interface while the document stays put.

  Crucially they are **third-party extensible**. A welding integrator should be
  able to ship `my_welding_bench` as a dependency, have it appear in the
  switcher, and never touch the studio's source. That constrains the design:
  a workbench declares what it contributes rather than reaching into the shell,
  and the shell composes.

  ## Writing one

      defmodule Welding.Workbench do
        @behaviour EMotion.Workbench

        @impl true
        def name, do: "Welding"

        @impl true
        def description, do: "Seam paths, torch angles and weave patterns"

        @impl true
        def init(_cell), do: {:ok, %{weave: :none, travel_speed: EMotion.Units.mm_s(8)}}

        @impl true
        def commands do
          [
            %EMotion.Workbench.Command{id: :add_seam, label: "Add Seam", group: :path},
            %EMotion.Workbench.Command{id: :simulate, label: "Simulate", group: :run}
          ]
        end

        @impl true
        def view(state, ctx) do
          [
            {:ensure_widget, id(:speed_label), :static_text, :root,
             label: "Travel: " <> EMotion.Units.show(state.travel_speed, :linear_velocity, ctx.display)}
          ]
        end

        defp id(name), do: EMotion.Workbench.scope(__MODULE__, name)
      end

  ## Identifiers must be scoped

  Two workbenches that both call a slider `:speed` would collide in the widget
  tree, and the failure would be a control that mysteriously drives the wrong
  thing. `scope/2` namespaces an id to its workbench; use it for every widget
  and visual a workbench declares. The shell cannot do this for you, because
  ids also appear inside layout intents where they are values rather than
  positions.

  ## Nothing here may block

  `view/2` runs in the scene process on every model change, and
  `handle_event/3` runs there too. Both must be fast and pure. A workbench that
  needs to load a file, solve IK, plan a path or talk to a drive uses
  `EMotion.Job` and receives the answer in `handle_info/3` — see that module
  for why this is a rule rather than a preference.

  ## Callbacks

  Only `name/0` and `init/1` are required. A workbench that contributes only
  commands needs nothing else; one that draws in the viewport implements
  `layers/2`.
  """

  alias EMotion.Workbench.Command

  @typedoc "Whatever the workbench keeps between events. Opaque to the shell."
  @type state :: term()

  @typedoc """
  What a workbench is allowed to know about the world around it.

  A snapshot, passed in rather than fetched, so a workbench never calls into
  another process to render itself.
  """
  @type context :: %{
          cell: EMotion.Cell.t(),
          display: EMotion.Units.Display.t(),
          selection: [term()]
        }

  @doc "Shown in the workbench switcher."
  @callback name() :: String.t()

  @doc "One line, shown as a tooltip or beneath the name."
  @callback description() :: String.t()

  @doc """
  Builds initial state from the cell as it stands.

  Called when the workbench is first activated, not at boot, so a workbench
  nobody switches to costs nothing.
  """
  @callback init(EMotion.Cell.t()) :: {:ok, state()} | {:error, term()}

  @doc "Toolbar and menu entries this workbench offers."
  @callback commands() :: [Command.t()]

  @doc """
  Widget intents for this workbench's panel.

  Composed into the shell's declaration, so the same rules apply as any
  `cedar` scene: pure, cheap, and a function of state.
  """
  @callback view(state(), context()) :: [tuple()]

  @doc """
  Layers this workbench contributes to the 3D viewport.

  A keyword list in `Cedar.Visual.Layers` form, appended after the shell's own,
  so a welding bench can draw its seam path over the cell without owning the
  viewport.
  """
  @callback layers(state(), context()) :: keyword()

  @doc """
  Handles an event addressed to this workbench.

  Returning `{:ok, state, commands}` asks the shell to apply changes to the
  cell; a workbench never mutates the document itself, so that edits go through
  one path and can be undone.
  """
  @callback handle_event(term(), state(), context()) ::
              {:ok, state()} | {:ok, state(), [EMotion.Cell.change()]}

  @doc "Handles an async message, typically an `EMotion.Job` result."
  @callback handle_info(term(), state(), context()) ::
              {:ok, state()} | {:ok, state(), [EMotion.Cell.change()]}

  @doc "Released when the workbench is switched away from."
  @callback terminate(state()) :: :ok

  @optional_callbacks description: 0,
                      commands: 0,
                      view: 2,
                      layers: 2,
                      handle_event: 3,
                      handle_info: 3,
                      terminate: 1

  @doc """
  Namespaces an id to its workbench.

      iex> EMotion.Workbench.scope(Welding.Workbench, :speed)
      {:wb, Welding.Workbench, :speed}

  Every widget and visual a workbench declares should be scoped, or two
  workbenches with a `:speed` slider collide and one of them silently drives
  the other's value.
  """
  @spec scope(module(), term()) :: {:wb, module(), term()}
  def scope(module, id), do: {:wb, module, id}

  @doc """
  The workbench an id belongs to, or `nil` for anything the shell owns.

      iex> EMotion.Workbench.owner({:wb, Welding.Workbench, :speed})
      Welding.Workbench

      iex> EMotion.Workbench.owner(:save_btn)
      nil
  """
  @spec owner(term()) :: module() | nil
  def owner({:wb, module, _id}), do: module
  def owner(_other), do: nil

  @doc false
  def behaviour?(module) do
    attributes = module.module_info(:attributes)

    __MODULE__ in List.wrap(attributes[:behaviour])
  rescue
    # An unloadable module is not a workbench, and discovery should not care.
    _ -> false
  end
end
