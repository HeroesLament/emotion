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
  alias EMotion.{Boot, Cell, Controllers, Jog, Link, Navigator, Pendant, Program, Programs, Scene,
                 Teach, Workbench}
  alias EMotion.Program.Bundle
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
    Link.subscribe()

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
      controllers: Controllers.new(),
      programs: Programs.new(),
      pendant: Pendant.new(cell),
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

  # What the holder says is happening, which is not the same as what was asked
  # for: a refusal arrives here and lands in the panel's status line.
  def handle_info({:jog, %{status: {:refused, reason}}}, model) do
    {:noreply,
     %{model | pendant: %{Pendant.release(model.pendant) | status: refusal(reason)}}}
  end

  def handle_info({:jog, _state}, model), do: {:noreply, model}

  def handle_info(:program_poll, model) do
    was_active = Programs.active?(model.programs)
    model = poll_program(model)

    # A run that has just finished leaves the statement list showing a marker
    # that is no longer true, so the last poll of a run refreshes the display.
    model = if was_active and not Programs.active?(model.programs), do: refresh_programs(model), else: model
    {:noreply, model}
  end

  def handle_info({:link, {:disconnected, reason}}, model) do
    # Both tabs care. What the Programs tab is showing became stale the moment
    # the socket did, and a list of programs from a controller that is no
    # longer there is the most confident kind of wrong.
    {:noreply,
     %{
       model
       | controllers: Controllers.disconnected(model.controllers, reason),
         programs: Programs.disconnected(model.programs)
     }}
  end

  def handle_info({:link, :connected}, model), do: {:noreply, load_program_catalog(model)}

  def handle_info({:link, _event}, model), do: {:noreply, model}

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

  def handle_event({:dialog_result, id, result}, model)
      when id in [
             :program_new,
             :program_kind,
             :program_args,
             :program_open,
             :program_save,
             :program_push_confirm
           ] do
    {state, effects} = Programs.dialog(model.programs, id, result)
    run_program_effects(%{model | programs: state}, effects)
  end

  def handle_event({:dialog_result, id, result}, model) do
    {state, effects} = Controllers.dialog(model.controllers, id, result)
    run_effects(%{model | controllers: state}, effects)
  end

  def handle_event({:ui_event, :ctl_list, :change, index}, model) do
    %{model | controllers: Controllers.select(model.controllers, index)}
  end

  def handle_event({:ui_event, :ctl_list, :double_click, index}, model) do
    model
    |> Map.put(:controllers, Controllers.select(model.controllers, index))
    |> controller_action(:connect)
  end

  def handle_event({:ui_event, :prg_list, :change, index}, model) do
    {state, effects} = Programs.select(model.programs, index)
    run_program_effects(%{model | programs: state}, effects)
  end

  def handle_event({:ui_event, :prg_statements, :change, index}, model) do
    %{model | programs: Programs.select_statement(model.programs, index)}
  end

  for {id, action} <- [
        prg_new: :new,
        prg_delete: :delete,
        prg_refresh: :refresh,
        prg_open: :open,
        prg_save: :save_as,
        prg_push: :push,
        prg_append: :append,
        prg_remove: :remove,
        prg_up: :up,
        prg_down: :down,
        prg_start: :start,
        prg_hold: :hold,
        prg_resume: :resume,
        prg_step: :step,
        prg_stop: :stop
      ] do
    def handle_event({:ui_event, unquote(id), :click}, model),
      do: program_action(model, unquote(action))
  end

  def handle_event({:ui_event, :ctl_add, :click}, model), do: controller_action(model, :add)
  def handle_event({:ui_event, :ctl_edit, :click}, model), do: controller_action(model, :edit)
  def handle_event({:ui_event, :ctl_remove, :click}, model), do: controller_action(model, :remove)
  def handle_event({:ui_event, :ctl_props, :click}, model), do: controller_action(model, :properties)
  def handle_event({:ui_event, :ctl_connect, :click}, model), do: controller_action(model, :connect)

  def handle_event({:ui_event, :ctl_disconnect, :click}, model),
    do: controller_action(model, :disconnect)

  # Jogging. The scene records what is held; EMotion.Jog does the asserting,
  # because a hold that lasted only as long as the interface happened to be
  # re-rendering would be a machine controlled by a redraw loop.
  def handle_event({:ui_event, {:jog_neg, axis}, :press}, model), do: press(model, axis, -1)
  def handle_event({:ui_event, {:jog_pos, axis}, :press}, model), do: press(model, axis, 1)

  def handle_event({:ui_event, {:jog_neg, _axis}, :release}, model), do: release(model)
  def handle_event({:ui_event, {:jog_pos, _axis}, :release}, model), do: release(model)

  def handle_event({:ui_event, :pendant_slower, :click}, model), do: speed(model, :slower)
  def handle_event({:ui_event, :pendant_faster, :click}, model), do: speed(model, :faster)

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

  # Programs, like Controllers, returns effects rather than performing them.
  #
  # These run inline rather than through `EMotion.Job`. A program call is a
  # request on a socket the studio already holds open and answers in under a
  # millisecond on a bench; putting it on a task would mean rendering a tab
  # that shows the state before the edit, which is the one thing this tab must
  # never do. If a controller over a slow link ever makes that false, the fix
  # is a pending flag in the state, not a background task with no flag.
  defp program_action(model, action) do
    # A message is true until the operator does something else. Clearing here
    # rather than in each clause means no action can forget to.
    {state, effects} = Programs.action(Programs.clear_message(model.programs), action)
    run_program_effects(%{model | programs: state}, effects)
  end

  defp run_program_effects(model, effects), do: Enum.reduce(effects, model, &run_program_effect/2)

  defp run_program_effect({:dialog, id, kind, opts}, model) do
    Cedar.Renderer.render({:show_dialog, id, kind, :main, opts})
    model
  end

  defp run_program_effect({:program, call}, model) do
    case perform(call) do
      {:ok, _result} -> poll_program(model)
      {:error, reason} -> %{model | programs: Programs.failed(model.programs, reason)}
    end
  end

  defp run_program_effect(:refresh, model), do: refresh_programs(model)

  # Files. These are the one part of this tab that works with no controller
  # attached, which is the point of a file existing at all.
  defp run_program_effect({:file, {:open, path}}, model) do
    case Bundle.load(path) do
      {:ok, bundle} ->
        %{model | programs: Programs.opened(model.programs, path, bundle, Bundle.hash(bundle))}

      {:error, reason} ->
        %{model | programs: Programs.failed(model.programs, describe_file(reason))}
    end
  end

  defp run_program_effect({:file, {:save, name, path}}, model) do
    with {:ok, bundle} <- Bundle.pull(name),
         :ok <- Bundle.save(bundle, path) do
      %{model | programs: Programs.opened(model.programs, path, bundle, Bundle.hash(bundle))}
    else
      {:error, reason} ->
        %{model | programs: Programs.failed(model.programs, describe_file(reason))}
    end
  end

  # Planned, then shown, then confirmed. A push that wrote first and reported
  # after would be the implicit sync `PROGRAMS.md` refuses: "a tool that
  # silently uploaded on save would make opening a file a way to change a
  # machine."
  defp run_program_effect({:file, {:plan_push, bundle}}, model) do
    case Bundle.plan(bundle, []) do
      {:ok, plan} ->
        Cedar.Renderer.render(
          {:show_dialog, :program_push_confirm, :message, :main,
           caption: "Push #{bundle.name}?",
           type: :ok_cancel,
           icon: if(Enum.any?(plan, &match?({:refuse, _, _, _}, &1)), do: :warning, else: :question),
           message: Bundle.describe(plan)}
        )

        model

      {:error, reason} ->
        %{model | programs: Programs.failed(model.programs, reason)}
    end
  end

  defp run_program_effect({:file, {:push, nil}}, model), do: model

  defp run_program_effect({:file, {:push, bundle}}, model) do
    case Bundle.push(bundle, []) do
      {:ok, done} ->
        %{model | programs: %{model.programs | message: summarise(done)}}

      {:error, {:cell_not_commissioned, refusals}} ->
        missing = Enum.map_join(refusals, ", ", fn {_, kind, name, _} -> "#{kind} #{name}" end)
        %{model | programs: Programs.failed(model.programs, "cell has no #{missing}")}

      {:error, reason} ->
        %{model | programs: Programs.failed(model.programs, reason)}
    end
  end

  defp summarise(done) do
    case Enum.count(done, &match?({:failed, _, _, _}, &1)) do
      0 -> "Pushed #{length(done)} items"
      n -> "Pushed with #{n} failure#{if n == 1, do: "", else: "s"}"
    end
  end

  defp describe_file({:hash_mismatch, _stored, _actual}),
    do: "That file's contents do not match its own fingerprint"

  defp describe_file(:not_a_program_file), do: "Not an E-Motion program file"
  defp describe_file({:format_too_new, v}), do: "Written by a newer Studio (format #{v})"
  defp describe_file(:enoent), do: "No such file"
  defp describe_file(reason), do: reason

  defp perform({:create, name}), do: Program.create(name)
  defp perform({:delete, name}), do: Program.delete(name)
  defp perform({:append, program, kind, args}), do: Program.append(program, kind, args)
  defp perform({:remove, program, seq}), do: Program.remove(program, seq)
  defp perform({:move, program, seq, to}), do: Program.move(program, seq, to)
  defp perform({:start, name}), do: Program.start(name)
  defp perform({:hold}), do: Program.hold()
  defp perform({:resume}), do: Program.resume()
  defp perform({:step}), do: Program.step()
  defp perform({:stop}), do: Program.stop()

  # Read everything the tab shows, in the order it depends on itself: the
  # library, then the statements of whatever survived in it.
  defp refresh_programs(model) do
    state =
      model.programs
      |> ingest(&Program.list/0, &Programs.loaded/2)
      |> then(fn state ->
        if state.selected,
          do: ingest(state, fn -> Program.show(state.selected) end, &Programs.shown/2),
          else: %{state | statements: [], statement: nil}
      end)

    poll_program(%{model | programs: state})
  end

  # The palette and the taught points change rarely and are read once per
  # connection rather than per refresh — a point list is the same shape as a
  # program list and would double the traffic of every edit for nothing.
  defp load_program_catalog(model) do
    state =
      model.programs
      |> Programs.connected()
      |> ingest(&Program.kinds/0, &Programs.kinds_loaded/2)
      |> ingest(&Teach.list_points/0, &Programs.points_loaded/2)

    refresh_programs(%{model | programs: state})
  end

  defp ingest(state, read, apply_fun) do
    case read.() do
      {:ok, value} -> apply_fun.(state, value)
      {:error, reason} -> Programs.failed(state, reason)
    end
  end

  # Polling, and only while there is something to poll. A studio that asks a
  # controller what it is doing twice a second forever is a studio that shows
  # up in someone's bus trace as the reason a cycle is late.
  defp poll_program(model) do
    state =
      case Program.status() do
        {:ok, run} -> Programs.ran(model.programs, run)
        {:error, _reason} -> model.programs
      end

    if Programs.active?(state), do: Process.send_after(self(), :program_poll, 250)
    %{model | programs: state}
  end

  # Controllers returns effects rather than performing them, so this is the one
  # place the tab touches the world.
  defp controller_action(model, action) do
    {state, effects} = Controllers.action(model.controllers, action)
    run_effects(%{model | controllers: state}, effects)
  end

  defp run_effects(model, effects), do: Enum.reduce(effects, model, &run_effect/2)

  # A dialog is a one-shot action, not a piece of state, so it is pushed
  # straight at the renderer rather than declared in view/1. Cedar marks
  # :show_dialog non-diffable, which means a dialog left in a view would
  # re-open on every render until the model changed — an unclosable modal.
  defp run_effect({:dialog, id, opts}, model) do
    Cedar.Renderer.render({:show_dialog, id, :form, :main, opts})
    model
  end

  defp run_effect({:save, profiles}, model) do
    EMotion.Controller.Profile.save(profiles)
    model
  end

  defp run_effect({:connect, profile, opts}, model) do
    # Connecting is a blocking call into the link, which in turn does a TLS
    # handshake. Done here rather than in a Task because the shell must not
    # render a half-connected state, and because the link itself is the thing
    # that serialises access to the controller.
    case Link.connect(profile, opts) do
      {:ok, info} ->
        %{model | controllers: Controllers.connected(model.controllers, profile.name, info)}

      {:error, reason} ->
        %{model | controllers: Controllers.failed(model.controllers, reason)}
    end
  end

  defp run_effect(:disconnect, model) do
    Link.disconnect()
    model
  end

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

      # -- ribbon ---------------------------------------------------------
      # A fixed-height strip. Without a minimum size a notebook takes its best
      # size from its busiest page, so the Controllers list would decide how
      # tall the bar is for every tab.
      {:ensure_widget, :ribbon, :notebook, :root, size: {0, 200}},

      {:ensure_panel, :tab_view, :ribbon, label: "View"},
      {:ensure_widget, :workbench_label, :static_text, :tab_view, label: "Workbench:"},
      {:ensure_widget, :workbench_choice, :choice, :tab_view, choices: workbench_names()},
      {:ensure_widget, :view_iso, :button, :tab_view, label: "Iso"},
      {:ensure_widget, :view_top, :button, :tab_view, label: "Top"},
      {:ensure_widget, :view_front, :button, :tab_view, label: "Front"},
      {:ensure_widget, :view_fit, :button, :tab_view, label: "Fit"},
      {:layout, :tab_view,
       {:vbox, [padding: 10],
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
          {:spacer, 8}
        ]}}
    ] ++ programs_tab(model) ++ controllers_tab(model) ++ [

      # -- docking --------------------------------------------------------
      # The viewport is the centre pane, which is the one pane that cannot
      # float — so the GL context is never reparented into a new top-level
      # window, which is how a GL context is lost. Every suite in this genre
      # puts the document in the middle anyway.
      {:ensure_dock_host, :dock, :root, []},
      {:ensure_dock_pane, :viewport_pane, :dock, dock: :centre},

      # -- viewport -------------------------------------------------------
      {:ensure_visual, :viewport, :viewport, :viewport_pane,
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
      pendant_pane(model) ++
      workbench_view(model) ++
      [
        {:layout, :root,
         {:vbox, [padding: 8],
          [
            {:ribbon, proportion: 0, flag: :expand},
            {:spacer, 6},
            {:dock, proportion: 1, flag: :expand},
            {:spacer, 6},
            :status
          ]}},
        {:refresh, :main}
      ]
  end

  # ==========================================================================
  # Pendant
  # ==========================================================================

  # A pane rather than a ribbon tab. A pendant is the thing an operator keeps
  # in view for as long as they are moving the machine, which a tab that hides
  # the moment they look at anything else cannot be — and it is the panel most
  # likely to want dragging onto a second screen next to the cell.
  defp pendant_pane(model) do
    pendant = model.pendant
    live? = Pendant.enabled?(pendant, connected?(model))

    header =
      [
        {:ensure_dock_pane, :pendant, :dock,
         caption: "Pendant", dock: :right, size: {300, 700}},
        {:ensure_widget, :pendant_status, :static_text, :pendant, label: pendant.status},
        {:set, :pendant_status, label: pendant.status},
        {:ensure_widget, :pendant_speed_label, :static_text, :pendant,
         label: "Speed  #{Pendant.speed_label(pendant)}"},
        {:set, :pendant_speed_label, label: "Speed  #{Pendant.speed_label(pendant)}"},
        {:ensure_widget, :pendant_slower, :button, :pendant, label: "−"},
        {:ensure_widget, :pendant_faster, :button, :pendant, label: "+"}
      ]

    rows = Enum.flat_map(pendant.axes, &axis_row(&1, pendant, live?))

    header ++
      rows ++
      [
        {:layout, :pendant,
         {:vbox, [padding: 8],
          [
            :pendant_status,
            {:spacer, 6},
            {:hbox, [], [:pendant_speed_label, {:spacer, 8}, :pendant_slower, :pendant_faster]},
            {:spacer, 10}
          ] ++ Enum.map(pendant.axes, &axis_layout/1)}}
      ]
  end

  # Minus on the left of plus, always, on every axis. An operator reaching for
  # J5 without looking is the case this is for, and a row that reorders itself
  # for any reason at all breaks it.
  defp axis_row(axis, pendant, live?) do
    [
      {:ensure_widget, {:axis_name, axis}, :static_text, :pendant, label: String.upcase(axis)},
      {:ensure_widget, {:axis_value, axis}, :static_text, :pendant,
       label: Pendant.readout(pendant, axis)},
      {:set, {:axis_value, axis}, label: Pendant.readout(pendant, axis)},
      # `hold: true`: these report going down and coming up rather than being
      # clicked, because the axis moves for exactly as long as the button is
      # held. See Cedar.Renderer.Intents.Widgets.Button.
      {:ensure_widget, {:jog_neg, axis}, :button, :pendant, label: "−", hold: true},
      {:ensure_widget, {:jog_pos, axis}, :button, :pendant, label: "+", hold: true},
      {:set, {:jog_neg, axis}, enabled: live?},
      {:set, {:jog_pos, axis}, enabled: live?}
    ]
  end

  defp axis_layout(axis) do
    {:hbox, [],
     [
       {:axis_name, axis},
       {:spacer, 8},
       {:axis_value, axis},
       {:spacer, 12},
       {:jog_neg, axis},
       {:spacer, 4},
       {:jog_pos, axis}
     ]}
  end

  defp connected?(model), do: model.controllers.connected_to != nil

  defp press(model, axis, direction) do
    Jog.press(axis, direction)

    %{
      model
      | pendant: %{
          Pendant.hold(model.pendant, axis, direction)
          | status: "Jogging #{String.upcase(axis)} #{arrow(direction)}"
        }
    }
  end

  defp release(model) do
    Jog.release()
    %{model | pendant: %{Pendant.release(model.pendant) | status: "Ready"}}
  end

  defp speed(model, change) do
    pendant = apply(Pendant, change, [model.pendant])
    Jog.set_speed(pendant.speed)
    %{model | pendant: pendant}
  end

  defp arrow(-1), do: "−"
  defp arrow(1), do: "+"

  defp refusal(%{"message" => message}), do: message
  defp refusal(reason), do: inspect(reason)

  # ==========================================================================

  # Between View and Controllers, which is where it belongs in the order of a
  # session: choose what you are looking at, write what it should do, then
  # decide which machine does it.
  defp programs_tab(model) do
    state = model.programs
    enabled = Programs.enabled(state)
    programs = Programs.labels(state)
    statements = Programs.statement_labels(state)

    [
      {:ensure_panel, :tab_programs, :ribbon, label: "Programs"},
      {:ensure_widget, :prg_list, :list_box, :tab_programs, choices: programs},
      {:set, :prg_list, items: programs},
      {:set, :prg_list, selected: Programs.selected_index(state)},
      {:ensure_widget, :prg_statements, :list_box, :tab_programs, choices: statements},
      {:set, :prg_statements, items: statements},
      {:set, :prg_statements, selected: Programs.statement_index(state)},

      {:ensure_widget, :prg_new, :button, :tab_programs, label: "New…"},
      {:ensure_widget, :prg_delete, :button, :tab_programs, label: "Delete"},
      {:ensure_widget, :prg_refresh, :button, :tab_programs, label: "Refresh"},
      {:ensure_widget, :prg_open, :button, :tab_programs, label: "Open…"},
      {:ensure_widget, :prg_save, :button, :tab_programs, label: "Save As…"},
      {:ensure_widget, :prg_push, :button, :tab_programs, label: "Push File"},
      {:ensure_widget, :prg_file, :static_text, :tab_programs, label: ""},
      {:ensure_widget, :prg_append, :button, :tab_programs, label: "Add…"},
      {:ensure_widget, :prg_remove, :button, :tab_programs, label: "Remove"},
      {:ensure_widget, :prg_up, :button, :tab_programs, label: "Up"},
      {:ensure_widget, :prg_down, :button, :tab_programs, label: "Down"},
      {:ensure_widget, :prg_start, :button, :tab_programs, label: "Start"},
      {:ensure_widget, :prg_hold, :button, :tab_programs, label: "Hold"},
      {:ensure_widget, :prg_resume, :button, :tab_programs, label: "Resume"},
      {:ensure_widget, :prg_step, :button, :tab_programs, label: "Step"},
      {:ensure_widget, :prg_stop, :button, :tab_programs, label: "Stop"},
      {:ensure_widget, :prg_run, :static_text, :tab_programs, label: ""},
      {:set, :prg_run, label: Programs.run_line(state)},
      {:ensure_widget, :prg_status, :static_text, :tab_programs, label: ""},
      {:set, :prg_status, label: Programs.message(state)},

      {:set, :prg_new, enabled: enabled.new},
      {:set, :prg_delete, enabled: enabled.delete},
      {:set, :prg_refresh, enabled: enabled.refresh},
      {:set, :prg_open, enabled: enabled.open},
      {:set, :prg_save, enabled: enabled.save_as},
      {:set, :prg_push, enabled: enabled.push},
      {:set, :prg_file, label: Programs.file_line(state) || "No file open"},
      {:set, :prg_append, enabled: enabled.append},
      {:set, :prg_remove, enabled: enabled.remove},
      {:set, :prg_up, enabled: enabled.up},
      {:set, :prg_down, enabled: enabled.down},
      {:set, :prg_start, enabled: enabled.start},
      {:set, :prg_hold, enabled: enabled.hold},
      {:set, :prg_resume, enabled: enabled.resume},
      {:set, :prg_step, enabled: enabled.step},
      {:set, :prg_stop, enabled: enabled.stop},

      {:layout, :tab_programs,
       {:vbox, [padding: 10],
        [
          {:hbox, [proportion: 1],
           [
             {:prg_list, proportion: 2, flag: :expand},
             {:spacer, 10},
             {:prg_statements, proportion: 3, flag: :expand},
             {:spacer, 12},
             {:vbox, [],
              [
                {:hbox, [],
                 [
                   :prg_new,
                   {:spacer, 6},
                   :prg_delete,
                   {:spacer, 6},
                   :prg_refresh,
                   {:spacer, 18},
                   :prg_open,
                   {:spacer, 6},
                   :prg_save,
                   {:spacer, 6},
                   :prg_push
                 ]},
                {:spacer, 8},
                {:hbox, [],
                 [:prg_append, {:spacer, 6}, :prg_remove, {:spacer, 6}, :prg_up, {:spacer, 6},
                  :prg_down]},
                {:spacer, 8},
                {:hbox, [],
                 [:prg_start, {:spacer, 6}, :prg_hold, {:spacer, 6}, :prg_resume, {:spacer, 6},
                  :prg_step, {:spacer, 6}, :prg_stop]}
              ]}
           ]},
          {:spacer, 6},
          :prg_file,
          {:spacer, 2},
          :prg_run,
          {:spacer, 2},
          :prg_status
        ]}}
    ]
  end

  defp controllers_tab(model) do
    state = model.controllers
    enabled = Controllers.enabled(state)
    labels = Controllers.labels(state)
    selected_index = selected_index(state)

    [
      {:ensure_panel, :tab_controllers, :ribbon, label: "Controllers"},
      {:ensure_widget, :ctl_list, :list_box, :tab_controllers, choices: labels},
      {:set, :ctl_list, items: labels},
      {:set, :ctl_list, selected: selected_index},
      {:ensure_widget, :ctl_add, :button, :tab_controllers, label: "Add…"},
      {:ensure_widget, :ctl_edit, :button, :tab_controllers, label: "Edit…"},
      {:ensure_widget, :ctl_remove, :button, :tab_controllers, label: "Remove"},
      {:ensure_widget, :ctl_props, :button, :tab_controllers, label: "Properties…"},
      {:ensure_widget, :ctl_connect, :button, :tab_controllers, label: "Connect"},
      {:ensure_widget, :ctl_disconnect, :button, :tab_controllers, label: "Disconnect"},
      {:ensure_widget, :ctl_status, :static_text, :tab_controllers, label: state.status},
      {:set, :ctl_status, label: state.status},
      {:set, :ctl_add, enabled: enabled.add},
      {:set, :ctl_edit, enabled: enabled.edit},
      {:set, :ctl_remove, enabled: enabled.remove},
      {:set, :ctl_props, enabled: enabled.properties},
      {:set, :ctl_connect, enabled: enabled.connect},
      {:set, :ctl_disconnect, enabled: enabled.disconnect},
      {:layout, :tab_controllers,
       {:vbox, [padding: 10],
        [
          {:hbox, [proportion: 1],
           [
             {:ctl_list, proportion: 1, flag: :expand},
             {:spacer, 12},
             {:vbox, [],
              [
                {:hbox, [],
                 [:ctl_add, {:spacer, 6}, :ctl_edit, {:spacer, 6}, :ctl_remove]},
                {:spacer, 8},
                {:hbox, [],
                 [:ctl_props, {:spacer, 6}, :ctl_connect, {:spacer, 6}, :ctl_disconnect]}
              ]}
           ]},
          {:spacer, 6},
          :ctl_status
        ]}}
    ]
  end

  defp selected_index(state) do
    Enum.find_index(state.profiles, &(&1.name == state.selected)) || -1
  end

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
