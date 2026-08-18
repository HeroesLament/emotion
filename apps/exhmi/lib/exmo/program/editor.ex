defmodule ExMo.Program.Editor do
  @moduledoc """
  Writes statements, and refuses the ones that cannot mean anything.

  This is the layer `exstore` deliberately does not have. The store holds a
  statement's kind as a validated *string* because the registry of kinds is
  populated by compiled extensions, which are code it cannot see — so validation
  happens here, where the registry is, and the store enforces what a database
  can enforce.

  Two things it does that are worth naming:

    * **A statement is refused when it is stored, not when it is reached.** A
      program with a typo in a socket name, a missing required argument, or a
      point that does not exist is refused while somebody is editing it rather
      than at the moment the arm is already moving. That is the whole return on
      typed parameters.
    * **References arrive as names and leave as ids.** A client says
      `point: "weld_start"`, because that is what a person taught; the database
      stores a foreign key, because that is what refuses a deletion.
  """

  alias ExMo.Program.{Kind, Kinds}
  alias ExStore.{Frames, Points, Programs, Tools}

  @doc "Appends a validated statement to a program."
  def append(program, kind_name, args \\ %{}) do
    with {:ok, kind} <- fetch_kind(kind_name),
         {:ok, literals, refs} <- split(kind, args) do
      case Programs.append(program, kind.name, literals, refs) do
        {:ok, statement} -> {:ok, statement}
        {:error, changeset} -> {:error, {:rejected, inspect(changeset.errors)}}
      end
    end
  end

  @doc "Replaces a statement in place, validating the new kind and arguments."
  def replace(statement, kind_name, args \\ %{}) do
    with {:ok, kind} <- fetch_kind(kind_name),
         {:ok, literals, refs} <- split(kind, args) do
      case Programs.replace(statement, kind.name, literals, refs) do
        {:ok, updated} -> {:ok, updated}
        {:error, changeset} -> {:error, {:rejected, inspect(changeset.errors)}}
      end
    end
  end

  defp fetch_kind(name) when is_binary(name) do
    case Kinds.get(name) do
      nil ->
        {:error,
         {:unknown_kind,
          "no statement kind called \"#{name}\"; this build knows " <>
            Enum.map_join(Kinds.all(), ", ", & &1.name)}}

      kind ->
        {:ok, kind}
    end
  end

  defp fetch_kind(_other), do: {:error, {:unknown_kind, "a statement needs a kind"}}

  # Every argument is checked against a declared parameter, and an argument that
  # matches none is an error rather than something quietly dropped. A socket name
  # typed wrong is the single most likely mistake a client makes, and ignoring it
  # produces a statement that is valid, stored, and not what anybody wrote.
  defp split(kind, args) do
    args = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    declared = MapSet.new(kind.params, & &1.name)
    undeclared = args |> Map.keys() |> Enum.reject(&MapSet.member?(declared, &1))

    cond do
      undeclared != [] ->
        {:error,
         {:unknown_argument,
          "#{kind.name} has no argument #{Enum.map_join(undeclared, ", ", &"\"#{&1}\"")}; it takes " <>
            Enum.map_join(kind.params, ", ", & &1.name)}}

      true ->
        Enum.reduce_while(kind.params, {:ok, %{}, %{}}, fn param, {:ok, literals, refs} ->
          case value_for(kind, param, args) do
            {:literal, name, value} -> {:cont, {:ok, Map.put(literals, name, value), refs}}
            {:reference, name, referent} -> {:cont, {:ok, literals, Map.put(refs, name, referent)}}
            :absent -> {:cont, {:ok, literals, refs}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp value_for(kind, param, args) do
    case Map.fetch(args, param.name) do
      :error ->
        cond do
          Map.get(param, :required, false) ->
            {:error, {:missing_argument, "#{kind.name} needs #{param.name}"}}

          Map.has_key?(param, :default) ->
            {:literal, param.name, param.default}

          true ->
            :absent
        end

      {:ok, value} ->
        if Kind.reference?(param) do
          resolve(param, value)
        else
          literal(kind, param, value)
        end
    end
  end

  defp resolve(%{type: :point} = param, name) when is_binary(name) do
    case Points.by_name(name) do
      nil -> {:error, {:unknown_point, "there is no point called \"#{name}\""}}
      point -> {:reference, param.name, {:point, point.id}}
    end
  end

  defp resolve(%{type: :frame} = param, name) when is_binary(name) do
    case Frames.by_name(name) do
      nil -> {:error, {:unknown_frame, "there is no frame called \"#{name}\""}}
      frame -> {:reference, param.name, {:frame, frame.id}}
    end
  end

  defp resolve(%{type: :tool} = param, name) when is_binary(name) do
    case Tools.by_name(name) do
      nil -> {:error, {:unknown_tool, "there is no tool called \"#{name}\""}}
      tool -> {:reference, param.name, {:tool, tool.id}}
    end
  end

  defp resolve(%{type: :program} = param, name) when is_binary(name) do
    case Programs.by_name(name) do
      nil -> {:error, {:unknown_program, "there is no program called \"#{name}\""}}
      program -> {:reference, param.name, {:program, program.id}}
    end
  end

  defp resolve(param, _value),
    do: {:error, {:wrong_type, "#{param.name} is a #{param.type} and wants a name"}}

  defp literal(_kind, %{type: :boolean} = param, value) when is_boolean(value),
    do: {:literal, param.name, value}

  defp literal(_kind, %{type: :text} = param, value) when is_binary(value),
    do: {:literal, param.name, value}

  defp literal(_kind, param, value) when is_number(value) do
    if param.type in [:velocity, :length, :angle, :duration, :number] do
      positive_only = param.type in [:velocity, :length, :duration]

      if positive_only and value <= 0 do
        {:error,
         {:wrong_value,
          "#{param.name} is a #{param.type} and must be greater than zero, not #{value}"}}
      else
        {:literal, param.name, value / 1}
      end
    else
      {:error, {:wrong_type, "#{param.name} is a #{param.type}, not a number"}}
    end
  end

  defp literal(_kind, param, value),
    do: {:error, {:wrong_type, "#{param.name} is a #{param.type}; got #{inspect(value)}"}}
end
