defmodule ExMo.Schema.Enum do
  @moduledoc """
  A named, transport-neutral enumeration type.

  Values are strings in the public model. Projection layers may map them
  to numeric or atom representations as needed.
  """

  @enforce_keys [:id, :name, :values]
  defstruct [
    :id,
    :name,
    :description,
    values: [],
    meta: %{}
  ]

  @type t :: %__MODULE__{
    id:          String.t(),
    name:        String.t(),
    description: String.t() | nil,
    values:      [String.t()],
    meta:        map()
  }
end
