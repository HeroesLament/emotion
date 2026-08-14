defmodule EMotion.Shell do
  @moduledoc """
  The window: a splash while starting, then the workspace.

  Both are declarations, and the model decides which exists. Nothing here opens
  or closes a window imperatively — `phase` moves from `:booting` to `:ready`
  and the differ works out that one frame should go and another should arrive.
  That is the whole transition.

  ## What is in the workspace

  A workbench switcher and view buttons across the top, the 3D viewport filling
  the middle, the active workbench's panel down the side, and a status line.
  The viewport is a `Cedar.Visual.Viewport` fed by `EMotion.Scene`, which is a
  pure function of the cell — so an arm moves because the document changed, not
  because anything told the viewport to redraw.

  ## Nothing in here blocks

  The scene subscribes to `EMotion.Boot` and `EMotion.Cell.Server` and keeps
  replicas. It never calls into either. Mouse events fold into an
  `EMotion.Navigator`. Any real work a workbench asks for goes through
  `EMotion.Job` and comes back as a message. See `EMotion.Job` for why that is
  structural rather than a habit.
  """

  use Cedar.Scene

  alias Cedar.Camera
  alias EMotion.{Boot, Cell, Navigator, Scene, Workbench}
  alias EMotion.Workbench.Registry

  require Logger

  @title "E-Motion Studio"
  @version Mix.Project.config()[:version]

  # ==========================================================================
  # Model
  # ==========================================================================

  def init(_opts) do
    boot = Boot.subscribe()
    cell = Cell.Server.subscribe()

    Boot.run()

    workbench = Registry.default()

    %{
      phase: if(boot.complete?, do: :ready, else: :booting),
      boot: boot,
      cell: cell,
      navigator: Navigator.new(camera: Camera.new(target: {0.0, 0.5, 0.0}, distance: 3.2)),
      surface: {1280, 800},
      workbench: workbench,
      workbench_state: init_workbench(workbench, cell),
      status: "Starting…"
    }
  end

  defp init_workbench(nil, _cell), do: nil

  defp init_workbench(module, cell) do
    case module.init(cell) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Logger.warning("Shell: #{inspect(module)} failed to start: #{inspect(reason)}")
        nil
    end
  end

  # ==========================================================================
  # Async in
  # ==========================================================================

  def handle_info({:boot, progress}, model) do
    model = %{model | boot: progress, status: Boot.status(progress)}

    # The splash goes when the work is done, not after a decent interval. An
    # app that holds a splash to look substantial is just slower.
    {:noreply, if(progress.complete?, do: %{model | phase: :ready}, else: model)}
  end

  def handle_info({:cell, cell}, model) do
    {:noreply, %{model | cell: cell}}
  end

  def handle_info({:cell_error, reason}, model) do
    {:noreply, %{model | status: "Refused: #{inspect(reason)}"}}
  end

  def handle_info({:job, _key, _ref, _result} = message, model) do
    {:noreply, to_workbench(model, :handle_info, message)}
  end

  def handle_info(_message, model), do: {:noreply, model}

  # ==========================================================================
  # Input
  # ==========================================================================

  def handle_event({:ui_event, :viewport, :mouse, event}, model) do
    %{model | navigator: Navigator.handle(model.navigator, event)}
  end

  def handle_event({:ui_event, :viewport, :resize, %{logical_size: size}}, model) do
    %{model | surface: size}
  end

  def handle_event({:ui_event, :workbench_choice, :change, index}, model) do
    case Enum.at(Registry.all(), index) do
      nil ->
        model

      module ->
        if module == model.workbench do
          model
        else
          if model.workbench, do: terminate_workbench(model)

          %{
            model
            | workbench: module,
              workbench_state: init_workbench(module, model.cell),
              status: "#{module.name()} workbench"
          }
        end
    end
  end

  def handle_event({:ui_event, :view_iso, :click}, model), do: look(model, :iso)
  def handle_event({:ui_event, :view_top, :click}, model), do: look(model, :top)
  def handle_event({:ui_event, :view_front, :click}, model), do: look(model, :front)

  def handle_event({:ui_event, :view_fit, :click}, model) do
    {min, max} = bounds(model.cell)

    %{model | navigator: Navigator.update_camera(model.navigator, &Camera.fit(&1, min, max))}
  end

  def handle_event({:ui_event, :main, :close_window, _}, model) do
    System.stop(0)
    %{model | status: "Closing…"}
  end

  # Anything scoped to a workbench belongs to that workbench.
  def handle_event({:ui_event, id, type, payload}, model) do
    case Workbench.owner(id) do
      nil -> model
      _module -> to_workbench(model, :handle_event, {type, id, payload})
    end
  end

  def handle_event(_event, model), do: model

  defp look(model, direction) do
    %{model | navigator: Navigator.update_camera(model.navigator, &Camera.look(&1, direction))}
  end

  # ==========================================================================
  # View
  # ==========================================================================

  def view(%{phase: :booting} = model) do
    percent =
      if model.boot.total > 0, do: round(model.boot.done * 100 / model.boot.total), else: 0

    [
      {:ensure_window, :splash, style: :splash, size: {520, 300}},
      {:ensure_panel, :splash_root, :splash, []},
      {:ensure_widget, :splash_title, :static_text, :splash_root, label: @title},
      {:ensure_widget, :splash_version, :static_text, :splash_root, label: "version #{@version}"},
      {:ensure_widget, :splash_status, :static_text, :splash_root, label: Boot.status(model.boot)},
      {:set, :splash_status, label: Boot.status(model.boot)},
      {:ensure_widget, :splash_gauge, :gauge, :splash_root, range: 100, value: percent},
      {:set, :splash_gauge, value: percent},
      {:layout, :splash_root,
       {:vbox, [padding: 32],
        [
          {:spacer, 40},
          :splash_title,
          {:spacer, 6},
          :splash_version,
          {:spacer, 40},
          :splash_status,
          {:spacer, 8},
          :splash_gauge
        ]}},
      {:refresh, :splash}
    ]
  end

  def view(%{phase: :ready} = model) do
    [
      {:destroy_window, :splash},
      {:ensure_window, :main, title: @title, size: {1440, 900}},
      {:ensure_panel, :root, :main, []},

      # -- toolbar --------------------------------------------------------
      {:ensure_widget, :workbench_label, :static_text, :root, label: "Workbench:"},
      {:ensure_widget, :workbench_choice, :choice, :root, choices: workbench_names()},
      {:ensure_widget, :view_iso, :button, :root, label: "Iso"},
      {:ensure_widget, :view_top, :button, :root, label: "Top"},
      {:ensure_widget, :view_front, :button, :root, label: "Front"},
      {:ensure_widget, :view_fit, :button, :root, label: "Fit"},

      # -- viewport -------------------------------------------------------
      {:ensure_visual, :viewport, :viewport, :root,
       size: {1040, 720},
       fps: 30,
       notify: self(),
       clear: {0.13, 0.14, 0.16, 1.0},
       camera: model.navigator.camera,
       nodes: Scene.nodes(model.cell)},

      # -- status ---------------------------------------------------------
      {:ensure_widget, :status, :static_text, :root, label: model.status},
      {:set, :status, label: model.status}
    ] ++
      workbench_view(model) ++
      [
        {:layout, :root,
         {:vbox, [padding: 8],
          [
            {:hbox, [],
             [
               :workbench_label,
               :workbench_choice,
               {:spacer, 24},
               :view_iso,
               :view_top,
               :view_front,
               {:spacer, 8},
               :view_fit
             ]},
            {:spacer, 6},
            {:viewport, proportion: 1, flag: :expand},
            {:spacer, 6},
            :status
          ]}},
        {:refresh, :main}
      ]
  end

  # ==========================================================================

  defp workbench_names do
    Enum.map(Registry.listing(), fn {_module, name, _description} -> name end)
  end

  defp workbench_view(%{workbench: nil}), do: []
  defp workbench_view(%{workbench_state: nil}), do: []

  defp workbench_view(model) do
    if function_exported?(model.workbench, :view, 2) do
      model.workbench.view(model.workbench_state, context(model))
    else
      []
    end
  end

  defp context(model) do
    %{cell: model.cell, display: %EMotion.Units.Display{}, selection: []}
  end

  # A workbench never edits the document; it returns changes and the shell
  # applies them, so every edit takes one path.
  defp to_workbench(%{workbench: nil} = model, _callback, _payload), do: model
  defp to_workbench(%{workbench_state: nil} = model, _callback, _payload), do: model

  defp to_workbench(model, callback, payload) do
    if function_exported?(model.workbench, callback, 3) do
      case apply(model.workbench, callback, [payload, model.workbench_state, context(model)]) do
        {:ok, state} ->
          %{model | workbench_state: state}

        {:ok, state, changes} ->
          Cell.Server.change(changes)
          %{model | workbench_state: state}
      end
    else
      model
    end
  end

  defp terminate_workbench(model) do
    if function_exported?(model.workbench, :terminate, 1) do
      model.workbench.terminate(model.workbench_state)
    end
  end

  # A box around everything in the cell, for zoom-to-fit. Falls back to a metre
  # cube so an empty cell still frames something rather than dividing by zero.
  defp bounds(cell) do
    points =
      cell
      |> Scene.nodes()
      |> Enum.map(fn item -> Cedar.Math.transform_point(item.transform, {0.0, 0.0, 0.0}) end)

    case points do
      [] ->
        {{-0.5, 0.0, -0.5}, {0.5, 1.0, 0.5}}

      points ->
        xs = Enum.map(points, &elem(&1, 0))
        ys = Enum.map(points, &elem(&1, 1))
        zs = Enum.map(points, &elem(&1, 2))

        {{Enum.min(xs), Enum.min(ys), Enum.min(zs)},
         {Enum.max(xs), Enum.max(ys), Enum.max(zs)}}
    end
  end
end
