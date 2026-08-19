defmodule Mix.Tasks.Exmo.Program do
  @moduledoc """
  Writes program bodies, from a terminal.

      mix exmo.program list
      mix exmo.program new <name>
      mix exmo.program show <name>
      mix exmo.program append <name> <kind> [arg=value ...]
      mix exmo.program remove <name> <seq>
      mix exmo.program delete <name>
      mix exmo.program kinds

  A program body is not on the JSON-RPC link — `PROGRAMS.md` §4 — so authoring
  lives here until the HTTP transfer exists and the block editor speaks it. What
  *is* on the link is running one: `mix exmo.rpc call program.start name=weld`.

  Arguments are the ones the statement kind declares; `mix exmo.program kinds`
  lists them. References are given by name, because that is what a person
  taught:

      mix exmo.program append weld move_linear point=weld_start feedrate=0.05

  ## Runs alongside a live controller

  Starts only `:exstore`, so it does not contend for ports the controller holds.
  It writes to the same database. A program edited while it is running does not
  change what is executing — the body is read once, when the run starts.
  """

  @shortdoc "Create and edit stored programs"

  use Mix.Task

  alias EMotion.Program.{Editor, Kinds}
  alias ExStore.Program.Statement
  alias ExStore.Programs

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:exstore)

    case argv do
      ["list"] -> list()
      ["kinds"] -> kinds()
      ["new", name] -> new(name)
      ["show", name] -> show(name)
      ["delete", name] -> delete(name)
      ["remove", name, seq] -> remove(name, seq)
      ["append", name, kind | args] -> append(name, kind, args)
      _unknown -> Mix.shell().info(@moduledoc)
    end
  end

  defp list do
    case Programs.list() do
      [] ->
        Mix.shell().info("\n  no programs\n")

      programs ->
        Mix.shell().info("")

        for program <- programs do
          Mix.shell().info("  #{pad(program.name)} #{length(Programs.body(program))} statements")
        end

        Mix.shell().info("")
    end
  end

  defp kinds do
    Mix.shell().info("")

    for kind <- Kinds.all() do
      Mix.shell().info("  #{pad(kind.name)} #{if kind.motion?, do: "moves the arm", else: "a barrier"}")

      for param <- kind.params do
        required = if Map.get(param, :required, false), do: "required", else: "optional"
        default = if Map.has_key?(param, :default), do: ", default #{param.default}", else: ""
        Mix.shell().info("    #{pad(param.name, 12)} #{param.type} (#{required}#{default})")
      end
    end

    Mix.shell().info("")
  end

  defp new(name) do
    case Programs.create(%{name: name}) do
      {:ok, program} -> Mix.shell().info("\n  created #{program.name}\n")
      {:error, changeset} -> errors(changeset)
    end
  end

  defp delete(name) do
    with {:ok, program} <- fetch(name) do
      {:ok, _} = Programs.delete(program)
      Mix.shell().info("\n  deleted #{name}\n")
    end
  end

  defp show(name) do
    with {:ok, program} <- fetch(name) do
      Mix.shell().info("\n  #{program.name}\n")

      for statement <- Programs.body(program) do
        Mix.shell().info(
          "  #{String.pad_leading(to_string(statement.seq), 3)}  #{pad(statement.kind)}" <>
            " #{refs(statement)}#{args(statement)}"
        )
      end

      Mix.shell().info("")
    end
  end

  defp append(name, kind, args) do
    with {:ok, program} <- fetch(name),
         {:ok, parsed} <- parse(args) do
      case Editor.append(program, kind, parsed) do
        {:ok, statement} ->
          Mix.shell().info("\n  #{name}: #{statement.seq} #{statement.kind}\n")

        # The Editor's refusals carry a sentence, which is the whole point of
        # validating a statement when it is stored rather than when it is
        # reached. Printing the reason as well gives a script something to match.
        {:error, {reason, message}} ->
          Mix.shell().error("\n  refused (#{reason}): #{message}\n")
      end
    end
  end

  defp remove(name, seq) do
    with {:ok, program} <- fetch(name),
         {seq, ""} <- Integer.parse(seq) do
      case Enum.find(Programs.body(program), &(&1.seq == seq)) do
        nil ->
          Mix.shell().error("\n  #{name} has no statement #{seq}\n")

        statement ->
          {:ok, :ok} = Programs.remove(statement)
          Mix.shell().info("\n  removed #{seq}; the rest closed up\n")
      end
    else
      :error -> Mix.shell().error("\n  a statement number, please\n")
      other -> other
    end
  end

  # `key=value`, with numbers parsed as numbers and everything else left as a
  # name. The Editor decides which is which from the kind's declared types, so
  # this only has to avoid making that decision badly.
  defp parse(args) do
    Enum.reduce_while(args, {:ok, %{}}, fn arg, {:ok, acc} ->
      case String.split(arg, "=", parts: 2) do
        [key, value] -> {:cont, {:ok, Map.put(acc, key, coerce(value))}}
        _malformed -> {:halt, Mix.shell().error("\n  arguments are key=value, not #{arg}\n")}
      end
    end)
  end

  defp coerce(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _not_a_number -> value
    end
  end

  defp fetch(name) do
    case Programs.by_name(name) do
      nil -> Mix.shell().error("\n  no program called #{name}\n")
      program -> {:ok, program}
    end
  end

  defp args(statement) do
    case Statement.args(statement) do
      empty when map_size(empty) == 0 -> ""
      args -> args |> Enum.sort() |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
    end
  end

  defp refs(statement) do
    statement.refs
    |> Enum.sort_by(& &1.arg_name)
    |> Enum.map_join(" ", fn ref ->
      case ExStore.Program.StatementRef.referent(ref) do
        {:point, id} -> "#{ref.arg_name}=#{name_of(ExStore.Points.get(id))}"
        {kind, id} -> "#{ref.arg_name}=#{kind}##{id}"
        _nothing -> ""
      end
    end)
    |> then(fn rendered -> if rendered == "", do: "", else: rendered <> " " end)
  end

  defp name_of(nil), do: "?"
  defp name_of(%{name: name}), do: name

  defp pad(string, width \\ 14), do: String.pad_trailing(to_string(string), width)

  defp errors(changeset) do
    Mix.shell().error("")

    for {field, messages} <- Ecto.Changeset.traverse_errors(changeset, & &1), message <- messages do
      Mix.shell().error("  #{field} #{message}")
    end

    Mix.shell().error("")
  end
end
