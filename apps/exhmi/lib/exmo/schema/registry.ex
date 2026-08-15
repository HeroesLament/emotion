defmodule ExMo.Schema.Registry do
  @moduledoc """
  Builds the static root ExMo Information Model.

  Contributions from behaviors are merged here. Later, this can be made
  dynamic — behavior modules register themselves, device modules contribute
  printer/drive fragments, etc. For now it's explicit and inspectable.
  """

  alias ExMo.Schema.{Model, Object, Property, Enum, FromAxis, FromBehavior}
  alias ExMo.Behaviors.K1C.RemovePreviousPrint

  @doc "Returns the uncompiled root model with all registered fragments."
  @spec base_model() :: Model.t()
  def base_model do
    rpp_def     = RemovePreviousPrint.definition()
    rpp_catalog = FromBehavior.catalog_object(rpp_def)
    rpp_runtime = FromBehavior.runtime_properties(rpp_def)

    %Model{
      id:      "exmo",
      name:    "ExMo Information Model",
      version: "0.1.0",
      types:   base_types(),
      root:    root_object(rpp_catalog, rpp_runtime)
    }
  end

  # ── Type registry ─────────────────────────────────────────────────────────

  defp base_types do
    %{
      "type.axis_state" => %Enum{
        id:          "type.axis_state",
        name:        "AxisState",
        description:
          "Axis state, in one vocabulary across every interface E-Motion drives " <>
            "— CiA 402 servo, step/dir stepper, PWM servo. `ready` is energised " <>
            "but not accepting motion; `enabled` is live.",
        values: ExMo.Schema.FromAxis.states()
      },
      "type.behavior_phase" => %Enum{
        id:          "type.behavior_phase",
        name:        "BehaviorPhase",
        description: "Public phase of an executing behavior. Coarser than internal FSM states.",
        values: [
          "idle",
          "verify_printer_ready",
          "approach_printer",
          "open_door",
          "acquire_plate",
          "extract_plate",
          "transfer_to_drop_zone",
          "release_part",
          "verify_release",
          "push_part_down_line",
          "restage",
          "complete",
          "fault"
        ]
      }
    }
  end

  # ── Object tree ───────────────────────────────────────────────────────────

  defp root_object(rpp_catalog, rpp_runtime) do
    %Object{
      id:       "exmo",
      name:     "ExMo",
      children: [
        axes_object(),
        behaviors_object(rpp_catalog, rpp_runtime),
        printers_object(),
        state_object()
      ]
    }
  end

  defp behaviors_object(rpp_catalog, rpp_runtime) do
    %Object{
      id:       "behaviors",
      name:     "Behaviors",
      children: [
        %Object{
          id:       "behaviors.catalog",
          name:     "Catalog",
          children: [rpp_catalog]
        },
        %Object{
          id:       "behaviors.runtime",
          name:     "Runtime",
          children: [active_behavior_object(rpp_runtime)]
        }
      ]
    }
  end

  defp active_behavior_object(runtime_props) do
    %Object{
      id:          "behaviors.runtime.active_behavior",
      name:        "ActiveBehavior",
      description: "Live state of the currently executing behavior. Fields are nil when idle.",
      children:    runtime_props
    }
  end

  # ── Axes ──────────────────────────────────────────────────────────────────

  # The arm, in SI. Limits mirror the demo chain in EMotion.Startup; they are
  # here rather than derived from it because the controller owns the cell model
  # and the Studio is a consumer of it, not the other way round.
  #
  # `display_unit: :degrees` is a hint to whatever renders these for a human.
  # It does not change the values, which are radians everywhere.
  @arm_axes [
    %{id: "axes.j1", name: "J1", type: :rotary, limits: {-3.05, 3.05}, home_pos: 0.0,
      display_unit: :degrees, description: "Shoulder pan"},
    %{id: "axes.j2", name: "J2", type: :rotary, limits: {-3.05, 3.05}, home_pos: 0.0,
      display_unit: :degrees, description: "Shoulder lift"},
    %{id: "axes.j3", name: "J3", type: :rotary, limits: {-3.05, 3.05}, home_pos: 0.0,
      display_unit: :degrees, description: "Elbow"},
    %{id: "axes.j4", name: "J4", type: :rotary, limits: {-3.05, 3.05}, home_pos: 0.0,
      display_unit: :degrees, description: "Wrist 1"},
    %{id: "axes.j5", name: "J5", type: :rotary, limits: {-3.05, 3.05}, home_pos: 0.0,
      display_unit: :degrees, description: "Wrist 2"},
    %{id: "axes.j6", name: "J6", type: :rotary, limits: {-3.05, 3.05}, home_pos: 0.0,
      display_unit: :degrees, description: "Wrist 3"}
  ]

  @doc "The registered axis specs, for tests and for whoever wires the drives."
  def arm_axes, do: @arm_axes

  defp axes_object do
    %Object{
      id:          "axes",
      name:        "Axes",
      description: "Motion axes. Positions in radians, velocities in rad/s.",
      children:    Elixir.Enum.map(@arm_axes, &FromAxis.to_object/1)
    }
  end

  defp printers_object do
    %Object{
      id:       "printers",
      name:     "Printers",
      children: [k1c_01_object()]
    }
  end

  defp k1c_01_object do
    %Object{
      id:          "printers.k1c_01",
      name:        "K1C_01",
      description: "Creality K1C printer, unit 01",
      children: [
        %Property{id: "printers.k1c_01.ready_for_unload",    name: "ReadyForUnload",    type: :boolean, description: "True when printer has a completed job ready for plate removal"},
        %Property{id: "printers.k1c_01.door_state",          name: "DoorState",         type: :string,  description: "Current door state: open | closed | fault"},
        %Property{id: "printers.k1c_01.build_plate_present", name: "BuildPlatePresent", type: :boolean, description: "True if build plate is detected inside the printer"},
        %Property{id: "printers.k1c_01.unload_lane_clear",   name: "UnloadLaneClear",   type: :boolean, description: "True if unload lane sensor indicates no obstruction"}
      ]
    }
  end

  defp state_object do
    %Object{
      id:          "state",
      name:        "State",
      description: "Top-level controller state",
      children: [
        %Property{id: "state.controller_mode", name: "ControllerMode", type: :string,  description: "Current controller operating mode: idle | manual | auto | fault"},
        %Property{id: "state.fault_present",   name: "FaultPresent",   type: :boolean, description: "True if any active fault is present on the controller"}
      ]
    }
  end
end
