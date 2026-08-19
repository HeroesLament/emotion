defmodule EMotion.Schema.Type do
  @moduledoc """
  Transport-neutral type descriptors for ExMo schema nodes.

  Covers primitives, enums, structs, arrays, and named references.
  References are resolved by the compiler against the model's types registry.
  """

  @type primitive ::
          :boolean
          | :string
          | :int32
          | :uint16
          | :float
          | :double

  @type t ::
          primitive()
          | {:enum, EMotion.Schema.Enum.t()}
          | {:struct, EMotion.Schema.StructType.t()}
          | {:array, t()}
          | {:ref, String.t()}

  @primitives [:boolean, :string, :int32, :uint16, :float, :double]

  @doc "Returns true if the given type is a known primitive."
  @spec primitive?(t()) :: boolean()
  def primitive?(t), do: t in @primitives

  @doc "Returns all supported primitive atoms."
  @spec primitives() :: [primitive()]
  def primitives, do: @primitives
end
