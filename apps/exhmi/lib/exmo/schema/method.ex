defmodule ExMo.Schema.Method do
  @moduledoc """
  A callable capability node in the ExMo Information Model.

  Methods represent machine behaviors invocable from external interfaces.
  `async: true` means the call returns an acceptance envelope immediately;
  results arrive via runtime state updates or separate result mechanisms.

  ## Grants

  `:call_grant` names the `ExAuth.Grant` a caller must hold to invoke this
  method, and has **no default** — exactly as `ExMo.Schema.Property` treats
  `:write_grant`. A method that does not say who may call it is rejected by the
  projection rather than given a permissive fallback, because the failure mode
  of guessing is a published, callable command that anyone who can connect may
  run.
  """

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    :description,
    :path,
    :call_grant,
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
    call_grant:  atom() | nil,
    meta:        map()
  }
end
