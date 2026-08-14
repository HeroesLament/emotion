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
    * `:type`         — `:linear` or `:rotary`
    * `:limits`       — `{min, max}` in SI, radians or metres
    * `:home_pos`     — SI, or nil where an axis has no home
    * `:display_unit` — optional presentation hint, e.g. `:degrees`, `:mm`
    * `:description`  — optional string
    * `:extra`        — optional list of `%Property{}` for machine-specific extras

  ## Standard properties by type

  All axes get Position, TargetPosition, Velocity, DriveState and FaultCode.
  Rotary axes additionally get Direction; linear axes additionally get AtHome.

  ## Usage

      spec = %{id: "axis.j1", name: "J1", type: :rotary,
               limits: {-3.05, 3.05}, home_pos: 0.0, display_unit: :degrees}
      object = ExMo.Schema.FromAxis.to_object(spec)
  """

  alias ExMo.Schema.{Object, Property}

  @type axis_type :: :linear | :rotary

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

  # ── Standard properties (every axis) ──────────────────────────────────────

  defp standard_properties(prefix, type, spec) do
    pos = position_unit(type)
    vel = velocity_unit(type)
    hint = display_meta(spec)

    [
      %Property{
        id: "#{prefix}.position",
        name: "Position",
        description: "Measured position (#{pos})",
        type: :double,
        unit: pos,
        readable: true,
        writable: false,
        observable: true,
        meta: hint
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
        meta: hint
      },
      %Property{
        id: "#{prefix}.velocity",
        name: "Velocity",
        description: "Measured velocity (#{vel})",
        type: :double,
        unit: vel,
        readable: true,
        writable: false,
        observable: true,
        meta: hint
      },
      %Property{
        id: "#{prefix}.drive_state",
        name: "DriveState",
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
        id: "#{prefix}.fault_code",
        name: "FaultCode",
        description: "Active fault code, 0 when healthy",
        type: :uint16,
        readable: true,
        writable: false,
        observable: false
      }
    ]
  end

  # ── Type-specific properties ──────────────────────────────────────────────

  defp type_properties(prefix, :rotary, _spec) do
    [
      %Property{
        id: "#{prefix}.direction",
        name: "Direction",
        description: "Rotation direction: cw | ccw | stopped",
        type: :string,
        readable: true,
        writable: true,
        observable: true
      }
    ]
  end

  defp type_properties(prefix, :linear, _spec) do
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
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Limits and home travel on the object rather than as properties: they are
  # facts about the axis, not values that change, and a consumer wants them
  # when rendering a control rather than when reading a position.
  defp axis_meta(spec) do
    %{axis_type: spec.type, si_unit: position_unit(spec.type)}
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
