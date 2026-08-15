defmodule ExMo.Schema.FromAxis do
  @moduledoc """
  Converts an axis spec into a schema Object suitable for merging into the
  ExMo Information Model under the Axes fragment.

  Every registered axis gets a standard set of properties derived automatically
  from its spec. No hand-written model fragments required.

  ## Units are SI

  The model carries metres, radians, and seconds — the same contract `Exdrive`
  holds, so a value can travel from a drive to OPC UA to a JSON-RPC client
  without anybody converting it on the way.

  A linear axis reports metres and metres per second. A rotary axis reports
  radians and radians per second. That is not negotiable per axis, because the
  moment two axes disagree about what a number means, every consumer needs a
  lookup table to read a position.

  `:display_unit` is a **presentation hint and nothing else**. It says how a
  pendant or an HMI should render the value for a human; it never changes what
  is on the wire. It lands in the property's `meta`, deliberately apart from
  `:unit`, which states the SI truth.

      # this axis is in radians. it is *shown* in degrees.
      %{id: "axis.j1", name: "J1", type: :rotary, display_unit: :degrees}

  ## Axis spec fields

    * `:id`           — unique string id, e.g. `"axis.j1"`
    * `:name`         — display name, e.g. `"J1"`
    * `:type`         — `:linear` or `:rotary`, the *kinematic* type
    * `:interface`    — how the axis is driven: `:cia402`, `:step_dir` or
      `:pwm`. Defaults to `:cia402`.
    * `:limits`       — `{min, max}` in SI, radians or metres
    * `:home_pos`     — SI, or nil where an axis has no home
    * `:display_unit` — optional presentation hint, e.g. `:degrees`, `:mm`
    * `:description`  — optional string
    * `:extra`        — optional list of `%Property{}` for machine-specific extras

  ## Properties depend on how the axis is driven, not just on its geometry

  E-Motion drives four tiers of hardware — a CiA 402 servo on CAN, a step/dir
  stepper, a PWM servo, an on/off actuator — and they do not have the same
  capabilities. A hobby servo has no PDS state machine, no CANopen emergency
  code and no feedback of any kind. Publishing DriveState and FaultCode on one
  would be describing a machine that does not exist.

  So the model declares only what an interface actually has, and **presence is
  the capability**: a client browsing an axis learns what it can do from what
  is there, with no capability bitmask to consult and nothing to get out of
  step. An axis with no `reset_fault` method cannot have its faults reset
  because it cannot have faults.

  Every axis gets Position, TargetPosition and State. Beyond that:

    * `:cia402`   — Velocity, PdsState, StatusWord, FaultCode
    * `:step_dir` — Velocity
    * `:pwm`      — nothing further

  Rotary axes additionally get Direction; linear axes additionally get AtHome,
  and only where the interface can actually know it.

  ## State is neutral; CiA 402 detail sits beside it

  `State` uses one vocabulary across every tier, so a client that understands
  only that works against all of them. A CiA 402 axis *also* publishes its raw
  `PdsState` and `StatusWord`, so nothing is lost for a servo — a diagnostic
  screen can subscribe to the status word, which it could not if that detail
  had been buried in metadata.

  ## Position does not mean the same thing on every tier

  On a servo it is measured. On an open-loop stepper or a PWM servo there is no
  feedback at all: the value is the commanded position, assumed to have been
  reached, which stops being true the moment a stepper stalls or a servo is
  back-driven. The node is the same everywhere so every client reads one id,
  and it carries `feedback: true | false` in its meta so a studio can draw an
  open-loop arm without implying a certainty it does not have.

  ## Usage

      spec = %{id: "axis.j1", name: "J1", type: :rotary,
               limits: {-3.05, 3.05}, home_pos: 0.0, display_unit: :degrees}
      object = ExMo.Schema.FromAxis.to_object(spec)
  """

  alias ExMo.Schema.{Object, Property}

  @type axis_type :: :linear | :rotary

  @typedoc "How an axis is driven. See the moduledoc on why this shapes the model."
  @type interface :: :cia402 | :step_dir | :pwm

  @interfaces [:cia402, :step_dir, :pwm]

  @doc "The interfaces this build models."
  @spec interfaces() :: [interface()]
  def interfaces, do: @interfaces

  @doc "The id of the neutral axis-state enum."
  @spec state_type_id() :: String.t()
  def state_type_id, do: "type.axis_state"

  @doc """
  The neutral axis states, in the order an axis moves through them.

  One vocabulary for every tier. `ready` is energised but not accepting motion
  — a CiA 402 drive in `switched_on`, or a stepper whose enable pin is high
  before a move is commanded — and it is distinct from `enabled` because an
  operator needs to know the difference between a powered axis and a live one.
  """
  @spec states() :: [String.t()]
  def states, do: ~w(disabled ready enabled moving homing stopping fault)

  @type axis_spec :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:type) => axis_type(),
          optional(:limits) => {float(), float()},
          optional(:home_pos) => float() | nil,
          optional(:display_unit) => atom() | nil,
          optional(:description) => String.t() | nil,
          optional(:extra) => [Property.t()]
        }

  # The SI unit a given axis type reports in. One entry per type, on purpose —
  # adding a type without deciding its unit should fail to compile rather than
  # default to something plausible.
  @position_unit %{linear: "m", rotary: "rad"}
  @velocity_unit %{linear: "m/s", rotary: "rad/s"}

  @doc """
  Returns an `%Object{}` for the given axis spec, to be placed under the Axes
  object in the Information Model.
  """
  @spec to_object(axis_spec()) :: Object.t()
  def to_object(%{id: id, name: name, type: type} = spec) do
    unless Map.has_key?(@position_unit, type) do
      raise ArgumentError,
            "unknown axis type #{inspect(type)}, expected :linear or :rotary"
    end

    %Object{
      id: id,
      name: name,
      description: spec[:description] || default_description(type, name),
      meta: axis_meta(spec),
      children:
        standard_properties(id, type, spec) ++
          interface_properties(id, interface(spec)) ++
          type_properties(id, type, spec) ++
          (spec[:extra] || [])
    }
  end

  @doc """
  The SI unit an axis of this type reports position in.

  Public because it is the answer to "what does this number mean", and that
  question gets asked from projections, tests, and display code alike.
  """
  @spec position_unit(axis_type()) :: String.t()
  def position_unit(type), do: Map.fetch!(@position_unit, type)

  @doc "The SI unit an axis of this type reports velocity in."
  @spec velocity_unit(axis_type()) :: String.t()
  def velocity_unit(type), do: Map.fetch!(@velocity_unit, type)

  # ── Properties ────────────────────────────────────────────────────────────

  defp standard_properties(prefix, type, spec) do
    interface = interface(spec)
    pos = position_unit(type)
    hint = display_meta(spec)
    feedback? = feedback?(interface)

    [
      %Property{
        id: "#{prefix}.position",
        name: "Position",
        description: position_description(feedback?, pos),
        type: :double,
        unit: pos,
        readable: true,
        writable: false,
        observable: true,
        # The one thing a client must know before believing this number.
        meta: Map.put(hint, :feedback, feedback?)
      },
      %Property{
        id: "#{prefix}.target_position",
        name: "TargetPosition",
        description: "Commanded target position (#{pos})",
        type: :double,
        unit: pos,
        readable: true,
        writable: true,
        observable: false,
        # Writing this moves the arm. :write_setpoint, not :write_configuration
        # — an observer must not reach it and an operator must.
        write_grant: :write_setpoint,
        meta: hint
      },
      %Property{
        id: "#{prefix}.state",
        name: "State",
        description:
          "Axis state, the same vocabulary on every interface: " <>
            Elixir.Enum.join(states(), " | "),
        type: {:ref, state_type_id()},
        readable: true,
        writable: false,
        observable: true
      }
    ] ++ velocity_property(prefix, type, hint, interface)
  end

  # A PWM servo is told a position and reports nothing, so it has no velocity to
  # publish. A stepper knows the velocity it is stepping at even open-loop.
  defp velocity_property(_prefix, _type, _hint, :pwm), do: []

  defp velocity_property(prefix, type, hint, interface) do
    vel = velocity_unit(type)

    [
      %Property{
        id: "#{prefix}.velocity",
        name: "Velocity",
        description:
          if(feedback?(interface),
            do: "Measured velocity (#{vel})",
            else: "Commanded velocity (#{vel}) — open loop, not measured"
          ),
        type: :double,
        unit: vel,
        readable: true,
        writable: false,
        observable: true,
        meta: Map.put(hint, :feedback, feedback?(interface))
      }
    ]
  end

  defp position_description(true, unit), do: "Measured position (#{unit})"

  defp position_description(false, unit),
    do: "Commanded position (#{unit}) — open loop, assumed reached, not measured"

  # ── Interface-specific properties ─────────────────────────────────────────

  # CiA 402 detail, published beside the neutral state rather than instead of
  # it. A diagnostic screen can subscribe to a status word; it could not if this
  # had been buried in metadata.
  defp interface_properties(prefix, :cia402) do
    [
      %Property{
        id: "#{prefix}.pds_state",
        name: "PdsState",
        description:
          "CiA 402 PDS state: not_ready_to_switch_on | switch_on_disabled | " <>
            "ready_to_switch_on | switched_on | operation_enabled | " <>
            "quick_stop_active | fault_reaction_active | fault",
        type: :string,
        readable: true,
        writable: false,
        observable: true
      },
      %Property{
        id: "#{prefix}.status_word",
        name: "StatusWord",
        description: "CiA 402 status word, object 0x6041",
        type: :uint16,
        readable: true,
        writable: false,
        observable: true
      },
      %Property{
        id: "#{prefix}.fault_code",
        name: "FaultCode",
        description: "Active CANopen emergency code, 0 when healthy",
        type: :uint16,
        readable: true,
        writable: false,
        observable: false
      }
    ]
  end

  # Nothing yet for step/dir or PWM. A stepper driver with an alarm output could
  # publish it here; inventing one for every stepper would be describing
  # hardware we have not seen.
  defp interface_properties(_prefix, _interface), do: []

  # ── Type-specific properties ──────────────────────────────────────────────

  defp type_properties(prefix, :rotary, _spec) do
    [
      %Property{
        id: "#{prefix}.direction",
        name: "Direction",
        description: "Rotation direction: cw | ccw | stopped",
        type: :string,
        readable: true,
        # Read-only. Direction is an observation derived from the sign of the
        # measured velocity, not a setpoint — there is no object in CiA 402 to
        # write it to, and a drive asked to "be clockwise" has been asked
        # nothing. Commanding motion is target_position or a velocity setpoint.
        writable: false,
        observable: true
      }
    ]
  end

  defp type_properties(prefix, :linear, spec) do
    # Whether an axis is home is only knowable where something can sense it.
    if feedback?(interface(spec)) do
      [
        %Property{
          id: "#{prefix}.at_home",
          name: "AtHome",
          description: "True when the axis is at its home position",
          type: :boolean,
          readable: true,
          writable: false,
          observable: true
        }
      ]
    else
      []
    end
  end

  # ── Interface ─────────────────────────────────────────────────────────────

  @doc """
  How this axis is driven.

  Defaults to `:cia402` because that is what the simulated drives are and what
  the arm on the bench uses. An unknown value is a modelling error and is
  raised rather than quietly treated as a servo — a PWM axis silently gaining a
  PDS state machine is exactly the confusion this exists to prevent.
  """
  @spec interface(map()) :: interface()
  def interface(spec) do
    case spec[:interface] || :cia402 do
      value when value in @interfaces ->
        value

      other ->
        raise ArgumentError,
              "unknown axis interface #{inspect(other)}; known: #{inspect(@interfaces)}"
    end
  end

  @doc """
  Whether this interface can measure where the axis actually is.

  A CiA 402 servo closes a loop on an encoder. A step/dir stepper and a PWM
  servo do not: what they report is what they were told, which stops being true
  the moment a stepper stalls or a servo is back-driven.
  """
  @spec feedback?(interface()) :: boolean()
  def feedback?(:cia402), do: true
  def feedback?(_interface), do: false

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Limits and home travel on the object rather than as properties: they are
  # facts about the axis, not values that change, and a consumer wants them
  # when rendering a control rather than when reading a position.
  defp axis_meta(spec) do
    %{axis_type: spec.type, si_unit: position_unit(spec.type), interface: interface(spec)}
    |> maybe_put(:limits, spec[:limits])
    |> maybe_put(:home_pos, spec[:home_pos])
    |> maybe_put(:display_unit, spec[:display_unit])
  end

  defp display_meta(spec) do
    maybe_put(%{}, :display_unit, spec[:display_unit])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_description(:linear, name), do: "#{name} linear axis (metres)"
  defp default_description(:rotary, name), do: "#{name} rotary axis (radians)"
end
