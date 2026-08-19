defmodule EMotion.Schema.ResultField do
  @moduledoc """
  A typed output/result field for a Method node, or a field in a StructType.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :description,
    meta: %{}
  ]

  @type t :: %__MODULE__{
    name:        String.t(),
    type:        EMotion.Schema.Type.t(),
    description: String.t() | nil,
    meta:        map()
  }
end
