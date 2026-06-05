defmodule ExMo.Schema.Property do
  @moduledoc """
  A typed, readable/writable/observable value node in the ExMo Information Model.

  Defaults to readable=true, writable=false, observable=true.
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
    readable:   true,
    writable:   false,
    observable: true,
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
    meta:        map()
  }
end
