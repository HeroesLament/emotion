defmodule EMotion.Schema.Object do
  @moduledoc """
  A hierarchical grouping node in the E-Motion Information Model.

  Objects contain children: other Objects, Properties, Methods, or Events.
  Paths are populated by the Compiler's normalize pass.
  """

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :description,
    :path,
    children: [],
    meta:     %{}
  ]

  @type child ::
          EMotion.Schema.Object.t()
          | EMotion.Schema.Property.t()
          | EMotion.Schema.Method.t()
          | EMotion.Schema.Event.t()

  @type t :: %__MODULE__{
    id:          String.t(),
    name:        String.t(),
    description: String.t() | nil,
    path:        [String.t()] | nil,
    children:    [child()],
    meta:        map()
  }
end
