defmodule ExProto.Validate do
  @moduledoc """
  Checks a value against the JSON Schema fragment a node carries.

  Deliberately not a general JSON Schema implementation. It handles exactly the
  shapes `ExMo.Projection.JSONRPC.TypeMap` produces — the schemas that can
  actually appear on a node — and refuses anything else rather than quietly
  accepting it.

  ## Why not a validator dependency

  A full validator is thousands of lines to check six shapes, and it would
  accept schemas this codebase never emits, which makes it harder rather than
  easier to reason about what a write can contain. The narrow version fits on a
  screen, and when the TypeMap grows a shape this fails loudly until it grows
  the same one.

  ## Why validate at all

  Because `nodes/write` promises `InvalidValue` in the generated document, and
  a promise the implementation does not keep is worse than one it never made. A
  drive should never be the thing that discovers a client sent a string where a
  number belonged.
  """

  @type result :: :ok | {:error, String.t()}

  @doc """
  Validates `value` against `schema`.

  Returns `:ok`, or `{:error, message}` where the message names what was
  expected and what arrived — a client that gets told only "invalid" has to
  guess.
  """
  @spec check(term(), map()) :: result()
  def check(value, %{"enum" => allowed} = schema) do
    with :ok <- check(value, Map.delete(schema, "enum")) do
      if value in allowed do
        :ok
      else
        {:error, "expected one of #{inspect(allowed)}, got #{inspect(value)}"}
      end
    end
  end

  def check(value, %{"type" => "boolean"}) when is_boolean(value), do: :ok
  def check(value, %{"type" => "string"}) when is_binary(value), do: :ok

  def check(value, %{"type" => "number"} = schema) when is_number(value) do
    bounds(value, schema)
  end

  def check(value, %{"type" => "integer"} = schema) when is_integer(value) do
    bounds(value, schema)
  end

  # A float that happens to be whole is not an integer here. JSON has one
  # number type, so 3.0 and 3 arrive indistinguishably from some clients and
  # identically from others; accepting 3.0 for an integer would mean a fault
  # code could arrive as a float and be written to a uint16 register.
  def check(value, %{"type" => "integer"}) when is_float(value) do
    {:error, "expected an integer, got the float #{inspect(value)}"}
  end

  def check(value, %{"type" => "array", "items" => items}) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      case check(element, items) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, "at index #{index}: #{message}"}}
      end
    end)
  end

  def check(value, %{"type" => "array"}) when is_list(value), do: :ok

  def check(value, %{"type" => "object"} = schema) when is_map(value) do
    with :ok <- required_present(value, schema) do
      check_properties(value, schema)
    end
  end

  def check(value, %{"type" => "null"}) when is_nil(value), do: :ok

  # A schema with no type constrains nothing. That is legitimate — the document
  # uses it for a node value whose type comes from the node itself — so it
  # accepts anything rather than raising.
  def check(_value, schema) when map_size(schema) == 0, do: :ok
  def check(_value, %{"description" => _} = schema) when map_size(schema) == 1, do: :ok

  def check(value, %{"type" => type}) do
    {:error, "expected #{type}, got #{describe(value)}"}
  end

  def check(_value, schema) do
    raise ArgumentError,
          "no validation rule for schema #{inspect(schema)}; " <>
            "ExProto.Validate covers only what ExMo.Projection.JSONRPC.TypeMap emits"
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp bounds(value, schema) do
    cond do
      is_number(schema["minimum"]) and value < schema["minimum"] ->
        {:error, "#{inspect(value)} is below the minimum #{schema["minimum"]}"}

      is_number(schema["maximum"]) and value > schema["maximum"] ->
        {:error, "#{inspect(value)} is above the maximum #{schema["maximum"]}"}

      is_number(schema["exclusiveMinimum"]) and value <= schema["exclusiveMinimum"] ->
        {:error, "#{inspect(value)} must be greater than #{schema["exclusiveMinimum"]}"}

      true ->
        :ok
    end
  end

  defp required_present(value, schema) do
    missing = Enum.reject(schema["required"] || [], &Map.has_key?(value, &1))

    if missing == [] do
      :ok
    else
      {:error, "missing required #{Enum.join(missing, ", ")}"}
    end
  end

  defp check_properties(value, schema) do
    properties = schema["properties"] || %{}

    Enum.reduce_while(value, :ok, fn {key, element}, :ok ->
      case Map.fetch(properties, key) do
        {:ok, sub} ->
          case check(element, sub) do
            :ok -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, "at #{key}: #{message}"}}
          end

        :error ->
          if Map.get(schema, "additionalProperties", true) == false do
            {:halt, {:error, "unexpected property #{key}"}}
          else
            {:cont, :ok}
          end
      end
    end)
  end

  defp describe(value) when is_binary(value), do: "a string"
  defp describe(value) when is_boolean(value), do: "a boolean"
  defp describe(value) when is_integer(value), do: "an integer"
  defp describe(value) when is_float(value), do: "a float"
  defp describe(value) when is_list(value), do: "an array"
  defp describe(value) when is_map(value), do: "an object"
  defp describe(nil), do: "null"
  defp describe(value), do: inspect(value)
end
