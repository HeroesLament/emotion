defmodule ExProto.Source.Program do
  @moduledoc """
  The running program, over the protocol.

  Reads come from the run rather than from the store, and the difference
  matters: what a pendant needs to know is what the controller is *doing*, and
  a program that has been edited since it started has not changed what is
  executing. The body was read once, when the run began.
  """

  @behaviour ExProto.Source

  alias ExMo.Program.{Args, Editor, Kinds}
  alias ExProto.Program.Run
  alias ExStore.Program.{Statement, StatementRef}
  alias ExStore.{Frames, Points, Programs, Tools}

  @impl ExProto.Source
  def read(node_id, arg) do
    status = Run.status(run_server(arg))

    case node_id do
      "program.name" -> {:ok, status.program}
      "program.state" -> {:ok, Atom.to_string(status.state)}
      "program.statement" -> {:ok, status.statement}
      "program.statements" -> {:ok, status.statements}
      "program.kind" -> {:ok, status.kind}
      "program.reason" -> {:ok, status.reason}
      _unknown -> {:error, :unknown_node}
    end
  end

  @impl ExProto.Source
  def write(_node_id, _value, _arg), do: {:error, :not_writable}

  @impl ExProto.Source
  def call("program.start", args, arg) do
    with {:ok, name} <- name(args) do
      # The refusal is passed through rather than flattened, because "wrong
      # mode" and "no such program" are different things to do something about.
      case Run.start(name, run_server(arg)) do
        :ok -> :ok
        {:error, {:wrong_mode, mode}} -> {:error, {:wrong_mode, mode}}
        {:error, _reason} -> {:error, :rejected}
      end
    end
  end

  def call("program.hold", _args, arg), do: accepted(Run.hold(run_server(arg)))
  def call("program.resume", _args, arg), do: accepted(Run.resume(run_server(arg)))
  def call("program.step", _args, arg), do: accepted(Run.step(run_server(arg)))
  def call("program.stop", _args, arg), do: accepted(Run.stop_run(run_server(arg)))

  def call("program.list", _args, _arg) do
    programs =
      for program <- Programs.list() do
        %{"name" => program.name, "statements" => length(Programs.body(program))}
      end

    {:ok, %{"programs" => programs}}
  end

  def call("program.show", args, _arg) do
    with {:ok, name} <- name(args) do
      case Programs.by_name(name) do
        nil ->
          {:error, :rejected}

        program ->
          statements =
            for statement <- Programs.body(program) do
              %{
                "seq" => statement.seq,
                "kind" => statement.kind,
                "args" => render_args(statement),
                "refs" => render_refs(statement)
              }
            end

          {:ok, %{"statements" => statements}}
      end
    end
  end

  # ── The kind registry, which is what an editor is built from ─────────────

  def call("program.kinds", _args, _arg) do
    kinds =
      for kind <- Kinds.all() do
        %{
          "name" => kind.name,
          "label" => kind.label,
          "description" => kind.description || "",
          "motion" => kind.motion?,
          "params" =>
            for param <- kind.params do
              %{
                "name" => param.name,
                "type" => to_string(param.type),
                "required" => Map.get(param, :required, false),
                "default" => render_default(Map.get(param, :default)),
                "description" => Map.get(param, :description) || ""
              }
            end
        }
      end

    {:ok, %{"kinds" => kinds}}
  end

  # A query, not a command: it succeeds and describes rather than refusing,
  # because `ExProto.Source`'s error vocabulary is a fixed set of atoms and a
  # `:rejected` cannot say which socket was wrong. See the registry's note.
  def call("program.validate", args, _arg) do
    case check(Map.get(args, "kind"), Map.get(args, "args") || []) do
      :ok ->
        {:ok, %{"ok" => true, "socket" => "", "reason" => ""}}

      {:error, socket, reason} ->
        {:ok, %{"ok" => false, "socket" => socket, "reason" => reason}}
    end
  end

  # ── Editing ──────────────────────────────────────────────────────────────

  def call("program.create", args, _arg) do
    with {:ok, name} <- string(args, "name") do
      case Programs.create(%{name: name}) do
        {:ok, _program} -> :ok
        {:error, _changeset} -> {:error, :rejected}
      end
    end
  end

  def call("program.delete", args, arg) do
    with {:ok, name} <- string(args, "name"),
         {:ok, program} <- fetch(name),
         :ok <- not_running(program, arg) do
      case Programs.delete(program) do
        {:ok, _program} -> :ok
        {:error, _changeset} -> {:error, :rejected}
      end
    end
  end

  def call("program.append", args, arg) do
    with {:ok, program} <- editable(args, arg),
         {:ok, kind_name} <- string(args, "kind"),
         {:ok, coerced} <- coerce(kind_name, Map.get(args, "args") || []),
         {:ok, statement} <- store(Editor.append(program, kind_name, coerced)) do
      {:ok, %{"seq" => statement.seq}}
    end
  end

  def call("program.replace", args, arg) do
    with {:ok, program} <- editable(args, arg),
         {:ok, seq} <- integer(args, "seq"),
         {:ok, statement} <- statement_at(program, seq),
         {:ok, kind_name} <- string(args, "kind"),
         {:ok, coerced} <- coerce(kind_name, Map.get(args, "args") || []),
         {:ok, _updated} <- store(Editor.replace(statement, kind_name, coerced)) do
      :ok
    end
  end

  def call("program.remove", args, arg) do
    with {:ok, program} <- editable(args, arg),
         {:ok, seq} <- integer(args, "seq"),
         {:ok, statement} <- statement_at(program, seq),
         {:ok, _count} <- store(Programs.remove(statement)) do
      :ok
    end
  end

  def call("program.move", args, arg) do
    with {:ok, program} <- editable(args, arg),
         {:ok, seq} <- integer(args, "seq"),
         {:ok, to} <- integer(args, "to"),
         {:ok, statement} <- statement_at(program, seq),
         {:ok, _moved} <- store(Programs.move(statement, to)) do
      :ok
    end
  end

  def call(_unknown, _args, _arg), do: {:error, :not_callable}

  # ── Edit helpers ─────────────────────────────────────────────────────────

  # Every edit refuses while that program is running. The danger is not the
  # engine reading a changed body — `ExProto.Program.Run` captures the body at
  # start deliberately — it is the operator believing the thing they just
  # edited is the thing that ran.
  defp editable(args, arg) do
    with {:ok, name} <- string(args, "program"),
         {:ok, program} <- fetch(name),
         :ok <- not_running(program, arg) do
      {:ok, program}
    end
  end

  defp not_running(program, arg) do
    status = Run.status(run_server(arg))

    if status.state in [:running, :held] and status.program == program.name do
      {:error, :rejected}
    else
      :ok
    end
  catch
    # No run process is not a reason to refuse an edit.
    :exit, _reason -> :ok
  end

  defp fetch(name) do
    case Programs.by_name(name) do
      nil -> {:error, :rejected}
      program -> {:ok, program}
    end
  end

  defp statement_at(program, seq) do
    case Enum.find(Programs.body(program), &(&1.seq == seq)) do
      nil -> {:error, :rejected}
      statement -> {:ok, statement}
    end
  end

  defp coerce(kind_name, args) do
    case Kinds.get(kind_name) do
      nil -> {:error, :rejected}
      kind -> with {:error, _why} <- Args.coerce(kind, args), do: {:error, :rejected}
    end
  end

  # Editor and Programs both answer {:ok, _} | {:error, term}; the protocol's
  # vocabulary has one word for all of it. `program.validate` is where the
  # detail lives.
  defp store({:ok, _value} = ok), do: ok
  defp store({:error, _reason}), do: {:error, :rejected}

  # The validate path, which unlike the edit path is allowed to explain itself.
  defp check(kind_name, args) when is_binary(kind_name) do
    case Kinds.get(kind_name) do
      nil ->
        {:error, "",
         "no statement kind called \"#{kind_name}\"; this build knows " <>
           Enum.map_join(Kinds.all(), ", ", & &1.name)}

      kind ->
        with {:ok, coerced} <- coerced_or_error(kind, args) do
          missing_or_undeclared(kind, coerced)
        end
    end
  end

  defp check(_absent, _args), do: {:error, "", "a statement needs a kind"}

  defp coerced_or_error(kind, args) do
    case Args.coerce(kind, args) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, {:bad_argument, socket, why}} -> {:error, socket, why}
    end
  end

  defp missing_or_undeclared(kind, coerced) do
    declared = MapSet.new(kind.params, & &1.name)

    undeclared =
      coerced |> Map.keys() |> Enum.reject(&MapSet.member?(declared, &1)) |> Enum.sort()

    missing =
      kind.params
      |> Enum.filter(&Map.get(&1, :required, false))
      |> Enum.reject(&Map.has_key?(coerced, &1.name))
      |> Enum.map(& &1.name)

    cond do
      undeclared != [] ->
        {:error, hd(undeclared),
         "#{kind.name} has no socket called \"#{hd(undeclared)}\"; it takes " <>
           Enum.map_join(kind.params, ", ", & &1.name)}

      missing != [] ->
        {:error, hd(missing), "#{kind.name} needs #{hd(missing)}"}

      true ->
        unresolved(kind, coerced)
    end
  end

  # A reference that names nothing is the failure an editor most wants to show
  # inline, because it is the one a person makes by mistyping.
  defp unresolved(kind, coerced) do
    kind.params
    |> Enum.filter(&ExMo.Program.Kind.reference?/1)
    |> Enum.filter(&Map.has_key?(coerced, &1.name))
    |> Enum.find_value(:ok, fn param ->
      name = Map.fetch!(coerced, param.name)

      if resolves?(param.type, name) do
        nil
      else
        {:error, param.name, "no #{param.type} called \"#{name}\""}
      end
    end)
  end

  defp resolves?(:point, name), do: Points.by_name(name) != nil
  defp resolves?(:frame, name), do: Frames.by_name(name) != nil
  defp resolves?(:tool, name), do: Tools.by_name(name) != nil
  defp resolves?(:program, name), do: Programs.by_name(name) != nil
  defp resolves?(_other, _name), do: true

  defp render_default(nil), do: ""
  defp render_default(value) when is_binary(value), do: value
  defp render_default(value), do: to_string(value)

  defp string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, :rejected}
    end
  end

  defp integer(args, key) do
    case Map.get(args, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _absent -> {:error, :rejected}
    end
  end

  defp accepted(:ok), do: :ok
  defp accepted({:error, _reason}), do: {:error, :rejected}

  defp name(args) do
    case Map.get(args, "name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _absent -> {:error, :rejected}
    end
  end

  defp run_server(arg) when is_list(arg), do: Keyword.get(arg, :run, ExProto.Program.Run)
  defp run_server(_arg), do: ExProto.Program.Run

  # Rendered rather than returned as a map, because a statement's arguments are
  # a different shape per kind and a typed protocol should not pretend otherwise.
  # The structured form is what the block editor will read, over HTTP.
  defp render_args(statement) do
    statement
    |> Statement.args()
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp render_refs(statement) do
    statement.refs
    |> Enum.sort_by(& &1.arg_name)
    |> Enum.map_join(" ", fn ref -> "#{ref.arg_name}=#{referent_name(ref)}" end)
  end

  defp referent_name(ref) do
    case StatementRef.referent(ref) do
      {:point, id} -> named(Points.get(id))
      {:frame, id} -> named(Frames.get(id))
      {:tool, id} -> named(Tools.get(id))
      {:program, id} -> named(Programs.get(id))
      _nothing -> "?"
    end
  end

  defp named(nil), do: "?"
  defp named(%{name: name}), do: name
end
