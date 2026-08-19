defmodule EMotion.Programs do
  @moduledoc """
  The Programs tab: the program library, the statements in one, and the run.

  Same shape as `EMotion.Controllers` and for the same reason — everything here
  is a pure function of a small state struct, and every action returns
  `{state, effects}` rather than doing anything. Which buttons are live in which
  run state is the part of this tab most likely to be wrong, and it is exactly
  the part that is testable with no window open and no controller attached.

  ## Nothing here is a copy of the program

  The list, the statements and the run state are all *last known* — read from
  the controller and redisplayed. The program lives on the controller. A studio
  that held its own copy would be a second source of truth for the thing the
  arm is about to do, and the two would agree right up until somebody edited
  one from a pendant.

  So every edit is a round trip, and `:refresh` after a write is not laziness:
  it is the only way the tab can be sure what it is showing.

  ## Appending a statement takes two dialogs, on purpose

  A statement's arguments depend on its kind, and a dialog's fields are fixed
  when it opens. So the kind is chosen first, and the second dialog is built
  from *that kind's declared parameters* — which is the whole return on the
  controller declaring them. A build that loads an extension offers it here
  without this module being edited, and a studio older than a kind still draws
  a correct form for it.

  ## Run controls follow the run, not the user's optimism

  `Start` is live only when a program is selected and nothing is running.
  `Hold` only while running, `Resume` and `Step` only while held, `Stop` while
  either. A button that can be pressed and refused teaches an operator that the
  interface is lying to them, which is worse than a greyed-out button.
  """

  alias EMotion.Program.Printer

  @typedoc """
  Something the shell should do. Returned, never performed.

  A dialog carries its kind, because opening a file is a file dialog and not a
  form. The alternative — a second effect per dialog flavour — puts the
  toolkit's vocabulary in a module whose whole point is not knowing there is a
  toolkit.
  """
  @type effect ::
          {:dialog, atom(), atom(), keyword()}
          | :refresh
          | {:program, tuple()}
          | {:file, tuple()}

  defstruct programs: [],
            selected: nil,
            statements: [],
            statement: nil,
            kinds: [],
            points: [],
            run: %{},
            pending_kind: nil,
            file: nil,
            mode: nil,
            fault?: false,
            connected?: false,
            message: "Not connected"

  @type t :: %__MODULE__{}

  @doc "An empty tab."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── What the widgets show ─────────────────────────────────────────────────

  @doc "Program names, for the library list."
  @spec labels(t()) :: [String.t()]
  def labels(%__MODULE__{programs: programs}) do
    Enum.map(programs, fn p ->
      case p["statements"] do
        n when is_integer(n) -> "#{p["name"]}  (#{n})"
        _ -> to_string(p["name"])
      end
    end)
  end

  @doc """
  Statement lines, numbered from zero and marked with where the run is.

      ▶ 2  move_joint   point=weld_start

  The marker is on the statement the controller says it is *on*, which during a
  motion is the one still moving rather than the one that finished.
  """
  @spec statement_labels(t()) :: [String.t()]
  def statement_labels(%__MODULE__{} = state) do
    current = running_statement(state)

    Enum.map(state.statements, fn s ->
      marker = if s["seq"] == current, do: "▶", else: " "
      # One renderer, in EMotion.Program.Printer, rather than a second copy
      # here. Two renderings of the same thing is how KUKA ended up with editor
      # metadata living in a comment.
      "#{marker} #{String.pad_leading(to_string(s["seq"]), 2)}  #{Printer.statement(s)}"
    end)
  end

  @doc "Kind names, for the palette."
  @spec kind_names(t()) :: [String.t()]
  def kind_names(%__MODULE__{kinds: kinds}) do
    Enum.map(kinds, fn k -> k["label"] || k["name"] end)
  end

  @doc "Index of the selected program in `labels/1`, or -1."
  @spec selected_index(t()) :: integer()
  def selected_index(%__MODULE__{selected: nil}), do: -1

  def selected_index(%__MODULE__{} = state) do
    Enum.find_index(state.programs, &(&1["name"] == state.selected)) || -1
  end

  @doc "Index of the selected statement, or -1."
  @spec statement_index(t()) :: integer()
  def statement_index(%__MODULE__{statement: nil}), do: -1

  def statement_index(%__MODULE__{} = state) do
    Enum.find_index(state.statements, &(&1["seq"] == state.statement)) || -1
  end

  @doc """
  Which buttons are live.

  Editing is refused by the controller while the program it is given is the one
  running, so it is greyed here rather than offered and refused.
  """
  @spec enabled(t()) :: map()
  def enabled(%__MODULE__{} = state) do
    connected = state.connected?
    chosen = connected and state.selected != nil
    picked = chosen and state.statement != nil
    editable = chosen and not editing_blocked?(state)

    %{
      new: connected,
      delete: editable,
      refresh: connected,
      append: editable and state.kinds != [],
      remove: picked and not editing_blocked?(state),
      up: picked and not editing_blocked?(state) and state.statement > 0,
      down: picked and not editing_blocked?(state) and state.statement < length(state.statements) - 1,
      open: true,
      save_as: chosen,
      push: connected and state.file != nil,
      # A button that can be pressed and refused teaches an operator that the
      # interface is lying to them. `program.start` is refused outside auto, so
      # until this tab knew the mode it was offering a button the controller
      # would turn down — which is the rule at the top of this module, broken by
      # the module that states it.
      start: chosen and idle?(state) and state.mode == "auto",
      hold: running?(state),
      resume: held?(state),
      step: held?(state),
      stop: running?(state) or held?(state)
    }
  end

  @doc "Whether a run is active, which is when the tab wants polling."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{} = state), do: running?(state) or held?(state)

  defp run_state(%__MODULE__{run: run}), do: run[:state] || run["state"]
  defp running?(state), do: run_state(state) == "running"
  defp held?(state), do: run_state(state) == "held"
  defp idle?(state), do: not (running?(state) or held?(state))

  # The controller refuses an edit only for the program that is running. A
  # different program is fair game, which matters: fixing the next job while
  # this one runs is most of what a shift looks like.
  defp editing_blocked?(%__MODULE__{} = state) do
    active?(state) and (state.run[:name] || state.run["name"]) == state.selected
  end

  defp running_statement(%__MODULE__{} = state) do
    if active?(state) and (state.run[:name] || state.run["name"]) == state.selected do
      state.run[:statement] || state.run["statement"]
    end
  end

  # ── Selection ─────────────────────────────────────────────────────────────

  @doc "Choose a program. Its statements are stale until the shell refreshes them."
  @spec select(t(), integer()) :: {t(), [effect()]}
  def select(%__MODULE__{} = state, index) do
    case Enum.at(state.programs, index) do
      nil -> {state, []}
      program -> {%{state | selected: program["name"], statement: nil, statements: []}, [:refresh]}
    end
  end

  @doc "Choose a statement."
  @spec select_statement(t(), integer()) :: t()
  def select_statement(%__MODULE__{} = state, index) do
    case Enum.at(state.statements, index) do
      nil -> state
      statement -> %{state | statement: statement["seq"]}
    end
  end

  # ── Actions ───────────────────────────────────────────────────────────────

  @doc "A button. Returns the new state and what the shell should do."
  @spec action(t(), atom()) :: {t(), [effect()]}
  def action(state, :new) do
    {state, [{:dialog, :program_new, :form,
        title: "New Program", fields: [{:name, :text, label: "Name", value: ""}]}]}
  end

  def action(%{selected: nil} = state, :delete), do: {nothing(state, "Choose a program first"), []}

  def action(state, :delete) do
    {state, [{:program, {:delete, state.selected}}, :refresh]}
  end

  def action(state, :refresh), do: {state, [:refresh]}

  def action(%{selected: nil} = state, :append), do: {nothing(state, "Choose a program first"), []}

  def action(state, :append) do
    {state,
     [
       {:dialog, :program_kind, :form,
        title: "Add Statement",
        fields: [{:kind, :choice, label: "Kind", choices: kind_names(state), selected: 0}]}
     ]}
  end

  def action(%{statement: nil} = state, action) when action in [:remove, :up, :down] do
    {nothing(state, "Choose a statement first"), []}
  end

  def action(state, :remove) do
    {%{state | statement: nil}, [{:program, {:remove, state.selected, state.statement}}, :refresh]}
  end

  def action(state, :up) do
    move(state, state.statement - 1)
  end

  def action(state, :down) do
    move(state, state.statement + 1)
  end

  def action(%{selected: nil} = state, :start), do: {nothing(state, "Choose a program first"), []}
  def action(state, :start), do: {state, [{:program, {:start, state.selected}}]}

  def action(state, run) when run in [:hold, :resume, :step, :stop] do
    {state, [{:program, {run}}]}
  end

  # ── Files ─────────────────────────────────────────────────────────────────
  #
  # A `.emp` is not a copy of a controller's program. It is its own thing, with
  # no memory of where it came from — see `EMotion.Program.Bundle`. So the open
  # file is held beside the controller's library rather than mixed into it, and
  # the tab says which is which. A list that could be either is the question
  # this tab has already made somebody ask out loud.

  def action(state, :open) do
    {state,
     [
       {:dialog, :program_open, :file_open,
        message: "Open a program", wildcard: "E-Motion programs (*.emp)|*.emp|All files|*.*"}
     ]}
  end

  def action(%{selected: nil} = state, :save_as),
    do: {nothing(state, "Choose a program to save"), []}

  def action(state, :save_as) do
    {state,
     [
       {:dialog, :program_save, :file_save,
        message: "Save program",
        default_file: "#{state.selected}.emp",
        wildcard: "E-Motion programs (*.emp)|*.emp"}
     ]}
  end

  def action(%{file: nil} = state, :push),
    do: {nothing(state, "No file open — Save As… or Open… one first"), []}

  # Planned first and confirmed second, always. `INSTALLATION.md` requires that
  # reconciling two copies is something a person asks for, and a push that
  # showed nothing before writing would not be asking.
  def action(state, :push), do: {state, [{:file, {:plan_push, state.file.bundle}}]}

  def action(state, _unknown), do: {state, []}

  # A button that does nothing must say why it did nothing.
  #
  # This is the greyed-button rule at the top of this module, one step further
  # on. `clear_message/1` runs before every action, so an action that returns no
  # effects used to leave the line blank — which is the same silence the
  # zero-width labels produced, arrived at from the opposite direction. Pressing
  # a control and watching the only feedback disappear is worse than pressing
  # one and seeing nothing change.
  defp nothing(state, why), do: %{state | message: why}

  defp move(state, to) when to < 0, do: {nothing(state, "Already first"), []}

  defp move(state, to) do
    if to > length(state.statements) - 1 do
      {nothing(state, "Already last"), []}
    else
      # The selection follows the statement, not the row. Moving something and
      # then finding the next click acts on its neighbour is how a wrong
      # statement gets deleted.
      {%{state | statement: to}, [{:program, {:move, state.selected, state.statement, to}}, :refresh]}
    end
  end

  # ── Dialogs ───────────────────────────────────────────────────────────────

  @doc "A dialog came back."
  @spec dialog(t(), atom(), term()) :: {t(), [effect()]}
  def dialog(state, _id, :cancel), do: {%{state | pending_kind: nil}, []}

  def dialog(state, :program_new, {:ok, %{"name" => name}}) do
    case String.trim(to_string(name)) do
      "" -> {%{state | message: "A program needs a name"}, []}
      name -> {%{state | selected: name}, [{:program, {:create, name}}, :refresh]}
    end
  end

  def dialog(state, :program_kind, {:ok, values}) do
    case kind_at(state, values["kind"]) do
      nil ->
        {state, []}

      kind ->
        {%{state | pending_kind: kind["name"]},
         [{:dialog, :program_args, :form,
           title: kind["label"] || kind["name"], fields: arg_fields(state, kind)}]}
    end
  end

  def dialog(%{pending_kind: nil} = state, :program_args, _values), do: {state, []}

  def dialog(state, :program_args, {:ok, values}) do
    kind = Enum.find(state.kinds, &(&1["name"] == state.pending_kind))
    args = collect_args(kind, values)

    {%{state | pending_kind: nil},
     [{:program, {:append, state.selected, state.pending_kind, args}}, :refresh]}
  end

  # `is_binary` is not enough and was the bug: wx hands back charlists, Cedar's
  # form dialog converts them and its file dialog did not, so a guard written
  # after using the form dialog matched nothing and the catch-all below ate it.
  # Cedar now converts too; this accepts either, because a client should not
  # break on a toolkit detail it cannot see.
  def dialog(state, :program_open, {:ok, path}) when is_binary(path) or is_list(path) do
    {state, [{:file, {:open, IO.chardata_to_string(path)}}]}
  end

  def dialog(state, :program_save, {:ok, path}) when is_binary(path) or is_list(path) do
    {state, [{:file, {:save, state.selected, IO.chardata_to_string(path)}}]}
  end

  def dialog(state, :program_push_confirm, confirmed) when confirmed in [:ok, :yes] do
    {state, [{:file, {:push, state.file && state.file.bundle}}, :refresh]}
  end

  def dialog(state, :program_push_confirm, _declined), do: {state, []}

  # A dialog we asked for that came back in a shape we do not understand is a
  # bug, and silence is how the last one hid. Cancel is not that — it is an
  # answer, and it is handled above.
  def dialog(state, id, result)
      when id in [
             :program_open,
             :program_save,
             :program_new,
             :program_kind,
             :program_args,
             :program_push_confirm
           ] do
    {nothing(state, "Could not read the dialog result: #{inspect(result, limit: 3)}"), []}
  end

  def dialog(state, _id, _result), do: {state, []}

  # A choice field hands back an index; a text field hands back a string.
  defp kind_at(state, index) when is_integer(index), do: Enum.at(state.kinds, index)

  defp kind_at(state, name) when is_binary(name) do
    Enum.find(state.kinds, &((&1["label"] || &1["name"]) == name)) ||
      Enum.find(state.kinds, &(&1["name"] == name))
  end

  defp kind_at(_state, _other), do: nil

  # Fields built from the kind's own declared parameters. A point gets a choice
  # of taught points, because typing the name of a thing that already exists is
  # a spelling test nobody should have to pass. Everything else is text, and
  # `program.validate` is what explains a wrong one — it can name the socket,
  # which a refusal cannot.
  defp arg_fields(state, kind) do
    for param <- kind["params"] || [] do
      label = label_for(param)

      case param["type"] do
        "point" ->
          names = Enum.map(state.points, & &1["name"])
          {String.to_atom(param["name"]), :choice, label: label, choices: names, selected: 0}

        "boolean" ->
          {String.to_atom(param["name"]), :choice, label: label, choices: ["false", "true"],
           selected: 0}

        _ ->
          {String.to_atom(param["name"]), :text, label: label, value: default_text(param)}
      end
    end
  end

  defp label_for(param) do
    base = param["name"] |> to_string() |> String.replace("_", " ") |> String.capitalize()
    if param["required"], do: base, else: base <> " (optional)"
  end

  defp default_text(%{"default" => nil}), do: ""
  defp default_text(%{"default" => value}), do: to_string(value)
  defp default_text(_param), do: ""

  # Empty optional fields are dropped rather than sent as "". A socket the user
  # left alone is one the controller should fill with its own default, and ""
  # is a value that means something different from absent.
  defp collect_args(nil, _values), do: []

  defp collect_args(kind, values) do
    for param <- kind["params"] || [],
        raw = resolve(param, values[param["name"]]),
        raw not in [nil, ""] do
      %{"name" => param["name"], "value" => raw}
    end
  end

  defp resolve(_param, nil), do: nil
  defp resolve(_param, value) when is_binary(value), do: String.trim(value)
  defp resolve(_param, value), do: value

  # ── Results the shell feeds back ──────────────────────────────────────────

  @doc "The program library, freshly read."
  @spec loaded(t(), [map()]) :: t()
  def loaded(%__MODULE__{} = state, programs) do
    selected = if Enum.any?(programs, &(&1["name"] == state.selected)), do: state.selected
    %{state | programs: programs, selected: selected}
  end

  @doc "The selected program's statements, freshly read."
  @spec shown(t(), [map()]) :: t()
  def shown(%__MODULE__{} = state, statements) do
    statement = if Enum.any?(statements, &(&1["seq"] == state.statement)), do: state.statement
    %{state | statements: statements, statement: statement}
  end

  @doc "The palette, read once per connection."
  @spec kinds_loaded(t(), [map()]) :: t()
  def kinds_loaded(%__MODULE__{} = state, kinds), do: %{state | kinds: kinds}

  @doc "Taught points, for the point choices in the argument dialog."
  @spec points_loaded(t(), [map()]) :: t()
  def points_loaded(%__MODULE__{} = state, points), do: %{state | points: points}

  @doc "The run's own account of itself."
  @spec ran(t(), map()) :: t()
  def ran(%__MODULE__{} = state, run), do: %{state | run: run}

  @doc """
  The run's own account of itself, as a line.

  Derived rather than stored, and that is the fix for a bug worth recording: it
  used to be written into the same field as messages. Polling runs after almost
  every action, so a refusal or a push result survived for milliseconds before
  `describe_run/1` overwrote it — and with nothing running, what it overwrote it
  with was "No program loaded". Every message in this tab looked like that
  sentence, including the answer to a button somebody had just pressed.

  Two lifetimes, two fields. A run line is true until the run changes; a message
  is true until the operator does something else.
  """
  @spec run_line(t()) :: String.t()
  def run_line(%__MODULE__{run: run}), do: describe_run(run)

  @doc "The last thing that happened, in words. Cleared when the operator acts."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message

  @doc "Forget the last message, because something new is being asked for."
  @spec clear_message(t()) :: t()
  def clear_message(%__MODULE__{} = state), do: %{state | message: ""}

  @doc "Something was refused. The controller's own words, not ours."
  @spec failed(t(), term()) :: t()
  def failed(%__MODULE__{} = state, reason), do: %{state | message: describe(reason)}

  @doc """
  A file was opened. Held beside the controller's library, never merged into it.
  """
  @spec opened(t(), String.t(), map(), String.t()) :: t()
  def opened(%__MODULE__{} = state, path, bundle, hash) do
    %{
      state
      | file: %{path: path, bundle: bundle, hash: hash},
        message: "Opened #{Path.basename(path)}"
    }
  end

  @doc "What the open file is, in one line, or nil when there is none."
  @spec file_line(t()) :: String.t() | nil
  def file_line(%__MODULE__{file: nil}), do: nil

  def file_line(%__MODULE__{file: file}) do
    bundle = file.bundle
    statements = length(bundle.statements || [])
    points = length(bundle.points || [])

    "#{Path.basename(file.path)}   #{String.slice(file.hash, 0, 12)}   " <>
      "#{bundle.name} — #{statements} statement#{plural(statements)}, #{points} point#{plural(points)}"
  end

  defp plural(1), do: ""
  defp plural(_n), do: "s"

  @doc "Where the mode selector is, and whether anything is faulted."
  @spec mode_loaded(t(), map()) :: t()
  def mode_loaded(%__MODULE__{} = state, values) do
    %{
      state
      | mode: values["state.controller_mode"],
        fault?: values["state.fault_present"] == true
    }
  end

  @doc """
  The machine's own state, as a line.

  The mode is here because it is the reason Start is greyed, and a greyed
  button with no visible cause is its own kind of lie.
  """
  @spec machine_line(t()) :: String.t()
  def machine_line(%__MODULE__{connected?: false}), do: "Not connected"

  def machine_line(%__MODULE__{} = state) do
    mode =
      case state.mode do
        nil -> "mode unknown"
        "auto" -> "AUTO"
        other -> "#{String.upcase(other)} — programs will not start"
      end

    fault = if state.fault?, do: "  ·  FAULT", else: ""
    "#{mode}#{fault}"
  end

  @doc "A controller arrived."
  @spec connected(t()) :: t()
  def connected(%__MODULE__{} = state) do
    %{state | connected?: true, message: "Connected"}
  end

  @doc "It went away. What was on screen is now stale, and saying so is the job."
  @spec disconnected(t()) :: t()
  def disconnected(%__MODULE__{} = state) do
    # The open file survives. Programming with no controller present is the
    # whole reason a file exists, and closing somebody's document because a
    # socket dropped would be the tool deciding what they are working on.
    %{state | connected?: false, programs: [], statements: [], kinds: [], points: [],
              selected: nil, statement: nil, run: %{}, mode: nil, fault?: false,
              message: "Not connected"}
  end

  defp describe_run(run) do
    name = run[:name] || run["name"]
    state = run[:state] || run["state"]
    at = run[:statement] || run["statement"]
    total = run[:statements] || run["statements"]
    reason = run[:reason] || run["reason"] || ""

    cond do
      name in [nil, ""] -> "No program loaded"
      reason != "" -> "#{name}: #{state} at #{at}/#{total} — #{reason}"
      true -> "#{name}: #{state} at #{at}/#{total}"
    end
  end

  defp describe(%{"message" => message, "data" => data}) when is_map(data) and data != %{} do
    detail = data |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end) |> Enum.join(", ")
    "#{message} (#{detail})"
  end

  defp describe(%{"message" => message}), do: message
  defp describe({:unexpected_result, key, _got}), do: "Controller sent no #{key}"
  defp describe(:disconnected), do: "Not connected"
  defp describe(reason), do: inspect(reason)
end
