defmodule ExMo.Schema.Method do
  @moduledoc """
  A callable capability node in the ExMo Information Model.

  Methods represent machine behaviors invocable from external interfaces.
  `async: true` means the call returns an acceptance envelope immediately;
  results arrive via runtime state updates or separate result mechanisms.
  """

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :description,
    :path,
    input_args:  [],
    output_args: [],
    async:       true,
    meta:        %{}
  ]

  @type t :: %__MODULE__{
    id:          String.t(),
    name:        String.t(),
    description: String.t() | nil,
    path:        [String.t()] | nil,
    input_args:  [ExMo.Schema.Argument.t()],
    output_args: [ExMo.Schema.ResultField.t()],
    async:       boolean(),
    meta:        map()
  }
end
