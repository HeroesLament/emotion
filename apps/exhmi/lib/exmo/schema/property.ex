defmodule ExMo.Schema.Property do
  @moduledoc """
  A typed, readable/writable/observable value node in the ExMo Information Model.

  Defaults to readable=true, writable=false, observable=true.

  ## Grants

  `:read_grant` and `:write_grant` name the `ExAuth.Grant` a caller must hold
  to read or write this property. They live here, on the model, rather than in
  either transport, for the same reason units do: there are two surfaces
  projecting from this model — JSON-RPC and OPC UA — and a permission defined
  in one of them is a permission the other does not enforce. The failure mode
  of that is a pendant refusing a write while an OPC UA client three metres
  away performs it.

  `:read_grant` defaults to `:read_state`, which is the grant every role above
  nothing already holds. `:write_grant` deliberately has **no default**: a
  writable property that does not name the grant required to write it is
  rejected by the projection rather than being given a permissive fallback.
  Forgetting an annotation should produce a build failure, not an open door.
  """

  @enforce_keys [:id, :name, :type]
  defstruct [
    :id,
    :name,
    :description,
    :path,
    :type,
    :access,
    :default,
    :unit,
    :nullable,
    :write_grant,
    readable:   true,
    writable:   false,
    observable: true,
    read_grant: :read_state,
    meta:       %{}
  ]

  @type t :: %__MODULE__{
    id:          String.t(),
    name:        String.t(),
    description: String.t() | nil,
    path:        [String.t()] | nil,
    type:        ExMo.Schema.Type.t(),
    access:      atom() | nil,
    default:     term(),
    unit:        String.t() | nil,
    nullable:    boolean() | nil,
    readable:    boolean(),
    writable:    boolean(),
    observable:  boolean(),
    read_grant:  atom(),
    write_grant: atom() | nil,
    meta:        map()
  }
end
