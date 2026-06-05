defmodule ExMo.Schema.FromAxis do
  @moduledoc """
  Converts an axis spec into a schema Object suitable for merging into
  the ExMo Information Model under the Axes fragment.

  Every registered axis gets a standard set of properties derived
  automatically from its spec. No hand-written IMS fragments required.

  ## Axis spec fields

    * `:id`          — unique string id, e.g. `"axis.z"` or `"spindle"`
    * `:name`        — display name, e.g. `"Z"` or `"Spindle"`
    * `:type`        — `:linear` or `:rotary`
    * `:unit`        — `:mm`, `:inches`, `:rpm`, `:degrees`, or any atom
    * `:limits`      — `{min, max}` float tuple
    * `:home_pos`    — float or nil (spindles typically have no home)
    * `:description` — optional string
    * `:extra`       — optional list of `%Property{}` for machine-specific extras

  ## Standard properties by type

  All axes get: Position, TargetPosition, Velocity, DriveState, FaultCode.

  Rotary axes additionally get: Direction (cw | ccw | stopped).

  Linear axes additionally get: AtHome (boolean).

  ## Usage

      spec = %{id: "axis.z", name: "Z", type: :linear, unit: :mm, limits: {-300.0, 0.0}, home_pos: 0.0}
      object = ExMo.Schema.FromAxis.to_object(spec)

  """

  alias ExMo.Schema.{Object, Property}

  @type axis_spec :: %{
    required(:id)   => String.t(),
    required(:name) => String.t(),
    required(:type) => :linear | :rotary,
    required(:unit) => atom(),
    optional(:limits)      => {float(), float()},
    optional(:home_pos)    => float() | nil,
    optional(:description) => String.t() | nil,
    optional(:extra)       => [Property.t()]
  }

  @doc """
  Returns an `%Object{}` for the given axis spec.
  Placed under the Axes object in the Information Model.
  """
  @spec to_object(axis_spec()) :: Object.t()
  def to_object(%{id: id, name: name, type: type} = spec) do
    unit_label = unit_label(spec[:unit])

    %Object{
      id:          id,
      name:        name,
      description: spec[:description] || default_description(type, name, unit_label),
      children:
        standard_properties(id, unit_label) ++
        type_properties(id, type) ++
        (spec[:extra] || [])
    }
  end

  # ── Standard properties (every axis) ─────────────────────────────────────

  defp standard_properties(prefix, unit_label) do
    [
      %Property{
        id:          "#{prefix}.position",
        name:        "Position",
        description: "Current position (#{unit_label})",
        type:        :float,
        readable:    true,
        writable:    false,
        observable:  true
      },
      %Property{
        id:          "#{prefix}.target_position",
        name:        "TargetPosition",
        description: "Commanded target position (#{unit_label})",
        type:        :float,
        readable:    true,
        writable:    true,
        observable:  false
      },
      %Property{
        id:          "#{prefix}.velocity",
        name:        "Velocity",
        description: "Current velocity (#{unit_label}/s)",
        type:        :float,
        readable:    true,
        writable:    false,
        observable:  true
      },
      %Property{
        id:          "#{prefix}.drive_state",
        name:        "DriveState",
        description: "CiA 402 drive state: disabled | ready | moving | fault",
        type:        :string,
        readable:    true,
        writable:    false,
        observable:  true
      },
      %Property{
        id:          "#{prefix}.fault_code",
        name:        "FaultCode",
        description: "Active fault code, 0 when healthy",
        type:        :uint16,
        readable:    true,
        writable:    false,
        observable:  false
      }
    ]
  end

  # ── Type-specific properties ──────────────────────────────────────────────

  defp type_properties(prefix, :rotary) do
    [
      %Property{
        id:          "#{prefix}.direction",
        name:        "Direction",
        description: "Rotation direction: cw | ccw | stopped",
        type:        :string,
        readable:    true,
        writable:    true,
        observable:  true
      }
    ]
  end

  defp type_properties(prefix, :linear) do
    [
      %Property{
        id:          "#{prefix}.at_home",
        name:        "AtHome",
        description: "True when axis is at its home position",
        type:        :boolean,
        readable:    true,
        writable:    false,
        observable:  true
      }
    ]
  end

  defp type_properties(_prefix, _type), do: []

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp unit_label(:mm),      do: "mm"
  defp unit_label(:inches),  do: "in"
  defp unit_label(:rpm),     do: "RPM"
  defp unit_label(:degrees), do: "deg"
  defp unit_label(other),    do: to_string(other)

  defp default_description(:linear, name, unit),
    do: "#{name} linear axis (#{unit})"
  defp default_description(:rotary, name, unit),
    do: "#{name} rotary axis (#{unit})"
  defp default_description(_, name, _),
    do: name
end
