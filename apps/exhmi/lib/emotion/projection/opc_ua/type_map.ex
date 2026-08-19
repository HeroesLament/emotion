defmodule EMotion.Projection.OPCUA.TypeMap do
  @moduledoc """
  Maps ExMo Schema types to OPC-UA data type atoms.

  These atoms correspond to the type identifiers used by ex_opcua's codec.
  Enum refs are projected as :string for the first pass; full enum DataType
  node generation comes in a later projection phase.
  """

  alias EMotion.Schema.{Enum, StructType}

  @doc "Maps an ExMo schema type to a UA data type atom."
  @spec to_ua_type(EMotion.Schema.Type.t(), map()) :: atom()
  def to_ua_type(type, types \\ %{})

  def to_ua_type(:boolean, _),  do: :boolean
  def to_ua_type(:string,  _),  do: :string
  def to_ua_type(:int32,   _),  do: :int32
  def to_ua_type(:uint16,  _),  do: :uint16
  def to_ua_type(:float,   _),  do: :float
  def to_ua_type(:double,  _),  do: :double

  # Inline enum — project as string (phase 1)
  def to_ua_type({:enum, %Enum{}}, _), do: :string

  # Inline struct — project as string (phase 1, not yet modelled as UA struct)
  def to_ua_type({:struct, %StructType{}}, _), do: :string

  # Array — project inner type (UA arrays are typed by element)
  def to_ua_type({:array, inner}, types), do: to_ua_type(inner, types)

  # Named reference — resolve from types registry, fall back to :string
  def to_ua_type({:ref, ref_id}, types) do
    case Map.get(types, ref_id) do
      nil             -> :string
      %Enum{}         -> :string
      %StructType{}   -> :string
      other           -> to_ua_type(other, types)
    end
  end

  def to_ua_type(_, _), do: :string
end
