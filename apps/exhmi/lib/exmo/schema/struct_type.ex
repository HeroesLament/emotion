defmodule ExMo.Schema.StructType do
  @moduledoc """
  A named, transport-neutral composite struct type.

  Fields reuse the ResultField shape. Used for rich method payload types
  and complex property values.
  """

  @enforce_keys [:id, :name, :fields]
  defstruct [
    :id,
    :name,
    :description,
    fields: [],
    meta: %{}
  ]

  @type t :: %__MODULE__{
    id:          String.t(),
    name:        String.t(),
    description: String.t() | nil,
    fields:      [ExMo.Schema.ResultField.t()],
    meta:        map()
  }
end
