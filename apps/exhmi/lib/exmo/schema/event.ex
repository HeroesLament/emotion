defmodule ExMo.Schema.Event do
  @moduledoc """
  An event type definition in the ExMo Information Model.

  Events describe streaming/state-change notifications:
  alarm transitions, behavior lifecycle, printer-ready signals, etc.

  Not yet projected to all transports — WebSocket and OPC-UA event
  projections come in a later phase.
  """

  @enforce_keys [:id, :name, :payload_type]
  defstruct [
    :id,
    :name,
    :description,
    :path,
    :payload_type,
    meta: %{}
  ]

  @type t :: %__MODULE__{
    id:           String.t(),
    name:         String.t(),
    description:  String.t() | nil,
    path:         [String.t()] | nil,
    payload_type: ExMo.Schema.Type.t(),
    meta:         map()
  }
end
