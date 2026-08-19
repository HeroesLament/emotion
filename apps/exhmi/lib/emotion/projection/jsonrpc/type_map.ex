defmodule EMotion.Projection.JSONRPC.TypeMap do
  @moduledoc """
  Renders ExMo schema types as JSON Schema fragments.

  The sibling of `EMotion.Projection.OPCUA.TypeMap`, and the reason a generated
  admin UI can pick a control without knowing anything about robots: a boolean
  gets a toggle, a bounded integer gets a spinner, an enum gets a select, and
  none of that needs a special case per property.

  Integer bounds are emitted rather than left implicit. `:uint16` is the type a
  fault code arrives in, and a client that will happily send 70000 for it is a
  client that finds out on the bench instead of at the edge of the wire.
  """

  alias EMotion.Schema.{Enum, StructType}

  @doc """
  Renders a type as a JSON Schema fragment.

  `types` is the model's named-type registry, used to resolve `{:ref, id}`.
  """
  @spec to_json_schema(term(), map()) :: map()
  def to_json_schema(type, types \\ %{})

  def to_json_schema(:boolean, _types), do: %{"type" => "boolean"}
  def to_json_schema(:string, _types), do: %{"type" => "string"}
  def to_json_schema(:float, _types), do: %{"type" => "number"}
  def to_json_schema(:double, _types), do: %{"type" => "number"}

  def to_json_schema(:int32, _types) do
    %{"type" => "integer", "minimum" => -2_147_483_648, "maximum" => 2_147_483_647}
  end

  def to_json_schema(:uint16, _types) do
    %{"type" => "integer", "minimum" => 0, "maximum" => 65_535}
  end

  def to_json_schema({:enum, %Enum{} = enum}, _types) do
    %{"type" => "string", "enum" => enum.values}
    |> put_description(enum.description)
  end

  def to_json_schema({:array, inner}, types) do
    %{"type" => "array", "items" => to_json_schema(inner, types)}
  end

  def to_json_schema({:struct, %StructType{} = struct}, types) do
    fields = struct.fields || []

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" =>
        Elixir.Enum.into(fields, %{}, fn field ->
          {field.name, to_json_schema(field.type, types)}
        end),
      "required" =>
        fields
        |> Elixir.Enum.filter(&Map.get(&1, :required, false))
        |> Elixir.Enum.map(& &1.name)
    }
    |> put_description(struct.description)
  end

  def to_json_schema({:ref, id}, types) do
    case Map.fetch(types, id) do
      {:ok, %Enum{} = enum} ->
        to_json_schema({:enum, enum}, types)

      {:ok, %StructType{} = struct} ->
        to_json_schema({:struct, struct}, types)

      {:ok, other} ->
        to_json_schema(other, types)

      :error ->
        # An unresolved reference is a modelling bug, and a schema of `{}` would
        # hide it by validating everything. Say so instead.
        raise ArgumentError,
              "unresolved type reference #{inspect(id)}; known types: " <>
                inspect(Map.keys(types))
    end
  end

  def to_json_schema(other, _types) do
    raise ArgumentError, "no JSON Schema mapping for type #{inspect(other)}"
  end

  defp put_description(schema, nil), do: schema
  defp put_description(schema, ""), do: schema
  defp put_description(schema, text), do: Map.put(schema, "description", text)
end
