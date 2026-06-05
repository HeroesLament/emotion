defmodule ExMo.Projection.OPCUA.NodeSpec do
  @moduledoc """
  Intermediate representation of a projected OPC-UA node.

  This is the output of the ExMo -> OPC-UA projection pass. It is intentionally
  decoupled from the ex_opcua wire layer — it is inspectable, testable, and
  can be fed into NodeManager or AddressSpace independently.

  node_class values: :object | :variable | :method

  reference_type values: :organizes | :has_component
  - :organizes    — Object containing child Objects (folder-style)
  - :has_component — Object owning a Property/Method (compositional)
  """

  @enforce_keys [:node_id, :browse_name, :display_name, :node_class]
  defstruct [
    :node_id,
    :browse_name,
    :display_name,
    :description,
    :node_class,
    :parent_node_id,
    :reference_type,
    :data_type,
    :value,
    :access_level,
    :executable,
    :user_executable,
    input_args:  [],
    output_args: [],
    meta:        %{}
  ]

  @type node_class  :: :object | :variable | :method
  @type ref_type    :: :organizes | :has_component

  @type t :: %__MODULE__{
    node_id:         String.t(),
    browse_name:     String.t(),
    display_name:    String.t(),
    description:     String.t() | nil,
    node_class:      node_class(),
    parent_node_id:  String.t() | nil,
    reference_type:  ref_type() | nil,
    data_type:       atom() | nil,
    value:           term(),
    access_level:    atom() | nil,
    executable:      boolean() | nil,
    user_executable: boolean() | nil,
    input_args:      [map()],
    output_args:     [map()],
    meta:            map()
  }
end
