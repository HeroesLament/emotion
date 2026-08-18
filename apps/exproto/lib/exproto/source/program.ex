defmodule ExProto.Source.Program do
  @moduledoc """
  The running program, over the protocol.

  Reads come from the run rather than from the store, and the difference
  matters: what a pendant needs to know is what the controller is *doing*, and
  a program that has been edited since it started has not changed what is
  executing. The body was read once, when the run began.
  """

  @behaviour ExProto.Source

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

  def call(_unknown, _args, _arg), do: {:error, :not_callable}

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
