defmodule ExMo.Program.Args do
  @moduledoc """
  Turns a client's `[{name, value}]` argument list into typed arguments.

  A statement's arguments arrive over the wire as strings, because that is what
  a form field and a text box produce. What they *mean* is declared by the
  statement kind: `feedrate` is a `:velocity`, `point` is a `:point`, `seconds`
  is a `:duration`. So the coercion is driven by the **declared type**, never by
  guessing at the string.

  That distinction is not pedantry. `mix exmo.program` guesses — it runs
  `Float.parse/1` and keeps whatever comes back — which is fine for a shell
  where a human sees what they typed, and wrong for a wire where a point
  legitimately named `"12"` would silently become the number 12.0 and then fail
  to resolve as a reference. Over the wire, a value is what the parameter says
  it is or it is refused.

  ## Why here and not in the Editor

  `ExMo.Program.Editor` already validates arguments against the registry and
  splits them into literals and references. This runs before it and does one
  narrower thing: string to term. Keeping them apart means the Editor's
  contract — "arguments arrive as terms, references arrive as names" — is
  unchanged by there being a wire, and a caller that already has terms (the mix
  task, a test, a future importer) does not go through this at all.
  """

  alias ExMo.Program.Kind

  @doc """
  Coerces a list of `%{"name" => _, "value" => _}` against a kind's parameters.

  Returns `{:ok, args}` with values typed for `Editor.append/3`, or
  `{:error, {:bad_argument, name, why}}` naming the socket that failed. Naming
  it matters: an editor told only "rejected" cannot put the cursor anywhere.

  An argument whose socket the kind does not declare is passed through
  untouched rather than refused here — `Editor` already refuses undeclared
  sockets, with a better message, and two layers refusing the same thing
  differently is how error text drifts.
  """
  def coerce(%Kind{} = kind, args) when is_list(args) do
    Enum.reduce_while(args, {:ok, %{}}, fn arg, {:ok, acc} ->
      with {:ok, name, raw} <- pair(arg),
           {:ok, value} <- cast(Kind.param(kind, name), raw, name) do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def coerce(%Kind{}, _not_a_list), do: {:error, {:bad_argument, "args", "expected a list"}}

  defp pair(%{"name" => name, "value" => value}) when is_binary(name) and name != "",
    do: {:ok, name, value}

  defp pair(_other), do: {:error, {:bad_argument, "args", "each argument needs a name and a value"}}

  # An undeclared socket: leave it alone. Editor refuses it and says which
  # sockets exist, which is the message worth showing.
  defp cast(nil, raw, _name), do: {:ok, raw}

  # References travel as names all the way to the Editor, which resolves them
  # to foreign keys. A name is already a string; there is nothing to convert,
  # and converting would be the bug.
  defp cast(%{type: type}, raw, name) when is_binary(raw) do
    cond do
      type in Kind.reference_types() -> non_empty(raw, name)
      type == :text -> {:ok, raw}
      type == :boolean -> boolean(raw, name)
      type in [:velocity, :length, :angle, :duration, :number] -> number(raw, name)
      true -> {:ok, raw}
    end
  end

  # Already a term — a client that sends a JSON number for a numeric socket is
  # not wrong, and refusing it would make the wire fussier than it needs to be.
  defp cast(%{type: type}, raw, name) when is_number(raw) do
    if type in Kind.reference_types() do
      {:error, {:bad_argument, name, "a #{type} is named, not numbered"}}
    else
      {:ok, raw}
    end
  end

  defp cast(%{type: _}, raw, _name) when is_boolean(raw), do: {:ok, raw}

  defp cast(%{type: _}, _raw, name),
    do: {:error, {:bad_argument, name, "cannot read that value"}}

  defp non_empty("", name), do: {:error, {:bad_argument, name, "needs a name"}}
  defp non_empty(raw, _name), do: {:ok, raw}

  defp boolean(raw, name) do
    case String.downcase(raw) do
      t when t in ~w(true yes 1 on) -> {:ok, true}
      f when f in ~w(false no 0 off) -> {:ok, false}
      _other -> {:error, {:bad_argument, name, "expected true or false"}}
    end
  end

  # Integer-looking strings become floats, deliberately: every numeric parameter
  # in the registry carries a physical dimension, and a feedrate of 1 and a
  # feedrate of 1.0 are the same speed. Storing one as an integer would make the
  # stored args differ by how somebody typed them.
  defp number(raw, name) do
    case Float.parse(String.trim(raw)) do
      {value, ""} -> {:ok, value}
      _other -> {:error, {:bad_argument, name, "expected a number, got #{inspect(raw)}"}}
    end
  end
end
