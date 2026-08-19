defmodule EMotion.Schema.Method do
  @moduledoc """
  A callable capability node in the ExMo Information Model.

  Methods represent machine behaviors invocable from external interfaces.
  `async: true` means the call returns an acceptance envelope immediately;
  results arrive via runtime state updates or separate result mechanisms.

  ## Grants

  `:call_grant` names the `ExAuth.Grant` a caller must hold to invoke this
  method, and has **no default** — exactly as `EMotion.Schema.Property` treats
  `:write_grant`. A method that does not say who may call it is rejected by the
  projection rather than given a permissive fallback, because the failure mode
  of guessing is a published, callable command that anyone who can connect may
  run.

  ## Watchdogged methods

  `meta: %{watchdog: true}` marks a method that is *asserted* rather than
  invoked: it stays in effect only while the client keeps re-sending it, and
  the controller commands the neutral value as soon as the assertions stop.
  Jogging is the case it exists for — a button that is held, where a dropped
  link must stop the machine rather than leave it moving.

  The contract a watchdogged method signs up to:

    * it takes a `velocity` argument whose neutral value is `0.0`, which is
      what the controller asserts on its behalf when assertions lapse;
    * it takes an optional `deadlineMs`, clamped to `watchdog_deadline_ms/0`;
    * the acceptance reports the deadline that was *granted*, which is what the
      client must re-assert within.

  It is declared here, on the model, so that the enforcement point can find it
  by asking the node table rather than by recognising a node id — the protocol
  layer has no business knowing what an axis is called. `ExProto.Jog` is what
  enforces it.
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

  # How long a watchdogged method's assertion stands before the controller
  # commands the neutral value.
  #
  # The floor is there because a client asking for a 5 ms deadline has built
  # something that stops on every ordinary network hiccup, and will be "fixed"
  # by someone raising it to a second. The ceiling is there because half a
  # second of motion after the operator let go is already as much as anyone
  # should accept: at the 250 mm/s ISO 10218 allows in manual mode, that is
  # 125 mm of travel.
  @watchdog_deadline_ms %{min: 50, default: 300, max: 500}

  @doc "Deadline bounds, in milliseconds, for a watchdogged method."
  @spec watchdog_deadline_ms() :: %{min: pos_integer(), default: pos_integer(), max: pos_integer()}
  def watchdog_deadline_ms, do: @watchdog_deadline_ms

  @doc """
  Whether this method is asserted rather than invoked.

  Takes anything with a `:meta` map, so it answers for a `%Method{}` and for
  the projected node table entry alike — the enforcement point holds the
  latter.
  """
  @spec watchdog?(%{optional(:meta) => map() | nil}) :: boolean()
  def watchdog?(%{meta: meta}), do: Map.get(meta || %{}, :watchdog) == true
  def watchdog?(_node), do: false

  @type t :: %__MODULE__{
    id:          String.t(),
    name:        String.t(),
    description: String.t() | nil,
    path:        [String.t()] | nil,
    input_args:  [EMotion.Schema.Argument.t()],
    output_args: [EMotion.Schema.ResultField.t()],
    async:       boolean(),
    call_grant:  atom() | nil,
    meta:        map()
  }
end
