defmodule EMotion.Schema.Argument do
  @moduledoc """
  A typed input argument for a Method node.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :description,
    required: false,
    default:  nil,
    meta:     %{}
  ]

  @type t :: %__MODULE__{
    name:        String.t(),
    type:        EMotion.Schema.Type.t(),
    description: String.t() | nil,
    required:    boolean(),
    default:     term(),
    meta:        map()
  }
end
