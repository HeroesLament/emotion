defmodule ExMo.Behavior do
  @moduledoc """
  Behaviour callback for ExMo behavior modules.

  Any module implementing a behavior contract should implement `definition/0`
  to return an explicit ExMo.Behavior.Definition describing the public surface.

  The implementation (gen_statem FSM, etc.) and the contract are kept separate.
  """

  @callback definition() :: ExMo.Behavior.Definition.t()
end

defmodule ExMo.Behavior.Definition do
  @moduledoc """
  The public contract for an ExMo behavior.

  Describes:
  - callable method surface (inputs, outputs)
  - externally observable runtime fields while active
  - named fault classes the behavior can raise

  Does NOT describe internal FSM states.
  """

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :description,
    input_args:     [],
    output_args:    [],
    runtime_fields: [],
    faults:         [],
    async:          true,
    meta:           %{}
  ]

  @type t :: %__MODULE__{
    id:             String.t(),
    name:           String.t(),
    description:    String.t() | nil,
    input_args:     [ExMo.Schema.Argument.t()],
    output_args:    [ExMo.Schema.ResultField.t()],
    runtime_fields: [ExMo.Behavior.RuntimeField.t()],
    faults:         [ExMo.Behavior.Fault.t()],
    async:          boolean(),
    meta:           map()
  }
end

defmodule ExMo.Behavior.RuntimeField do
  @moduledoc """
  A live runtime field exposed while a behavior is executing.

  The type system here matches ExMo.Schema.Type — the same type descriptors
  are used so FromBehavior can project these directly into Property nodes.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :description,
    observable: true,
    meta:       %{}
  ]

  @type t :: %__MODULE__{
    name:        String.t(),
    type:        ExMo.Schema.Type.t(),
    description: String.t() | nil,
    observable:  boolean(),
    meta:        map()
  }
end

defmodule ExMo.Behavior.Fault do
  @moduledoc """
  A named fault class that a behavior can raise.
  """

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :description,
    :severity,
    meta: %{}
  ]

  @type t :: %__MODULE__{
    id:          String.t(),
    name:        String.t(),
    description: String.t() | nil,
    severity:    atom() | nil,
    meta:        map()
  }
end
