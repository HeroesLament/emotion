defmodule EMotion.Schema.Model do
  @moduledoc """
  Root container for the E-Motion Information Model.

  `root` is the top-level E-Motion Object node.
  `types` is a registry of named reusable types keyed by their stable string ID,
  e.g. "type.behavior_phase" → %EMotion.Schema.Enum{}.
  """

  @enforce_keys [:id, :root]
  defstruct [
    :id,
    :name,
    :version,
    :root,
    types: %{},
    meta:  %{}
  ]

  @type t :: %__MODULE__{
    id:      String.t(),
    name:    String.t() | nil,
    version: String.t() | nil,
    root:    EMotion.Schema.Object.t(),
    types:   %{String.t() => EMotion.Schema.Type.t()},
    meta:    map()
  }
end
