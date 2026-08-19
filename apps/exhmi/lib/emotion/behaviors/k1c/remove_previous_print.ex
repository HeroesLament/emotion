defmodule EMotion.Behaviors.K1C.RemovePreviousPrint do
  @moduledoc """
  Public contract for the RemovePreviousPrint behavior.

  This module describes the callable surface and runtime observability of the
  behavior — NOT the internal FSM implementation.

  What the behavior does:
  1. Verify printer is ready and door can be opened
  2. Open printer door
  3. Grip spring steel build plate
  4. Extract plate from printer
  5. Transfer to drop zone
  6. Release / deposit part
  7. Push finished part down unload surface
  8. Restage for next cycle

  Public phases are coarser than internal FSM states by design.
  Internal states like :waiting_force_threshold or :awaiting_sensor_confirmation
  are implementation details and do not appear here.
  """

  @behaviour EMotion.Behavior

  alias EMotion.Behavior.{Definition, RuntimeField, Fault}
  alias EMotion.Schema.{Argument, ResultField}

  @impl EMotion.Behavior
  def definition do
    %Definition{
      id:          "behavior.remove_previous_print",
      name:        "RemovePreviousPrint",
      description: "Open printer, remove build plate, release part, and clear unload lane.",
      async:       true,

      input_args: [
        %Argument{
          name:        "printer_id",
          type:        :string,
          description: "ID of the target printer (e.g. \"k1c_01\")",
          required:    true
        },
        %Argument{
          name:        "unload_lane",
          type:        :string,
          description: "Target unload lane identifier",
          required:    true
        },
        %Argument{
          name:        "release_strategy",
          type:        :string,
          description: "Part release strategy override (optional)",
          required:    false,
          default:     "default"
        },
        %Argument{
          name:        "correlation_id",
          type:        :string,
          description: "Caller-supplied idempotency / tracing token",
          required:    false
        }
      ],

      output_args: [
        %ResultField{name: "accepted",    type: :boolean, description: "Whether the behavior was accepted for execution"},
        %ResultField{name: "job_id",      type: :string,  description: "Assigned job identifier for tracking"},
        %ResultField{name: "result_code", type: :int32,   description: "Numeric result code (0 = success)"},
        %ResultField{name: "message",     type: :string,  description: "Human-readable result or rejection reason"}
      ],

      runtime_fields: [
        %RuntimeField{name: "phase",          type: {:ref, "type.behavior_phase"}, description: "Current public phase of the behavior",      observable: true},
        %RuntimeField{name: "progress",       type: :uint16,                       description: "Estimated percent complete (0–100)",         observable: true},
        %RuntimeField{name: "retry_count",    type: :uint16,                       description: "Number of automatic retries attempted",       observable: true},
        %RuntimeField{name: "fault_code",     type: :string,                       description: "Fault ID if phase == fault, else nil",        observable: true},
        %RuntimeField{name: "fault_message",  type: :string,                       description: "Human-readable fault detail",                 observable: true},
        %RuntimeField{name: "printer_ready",  type: :boolean,                      description: "Whether printer confirmed ready at start",    observable: true},
        %RuntimeField{name: "door_state",     type: :string,                       description: "Last observed door state (open/closed/fault)", observable: true},
        %RuntimeField{name: "plate_gripped",  type: :boolean,                      description: "Whether build plate has been gripped",        observable: true},
        %RuntimeField{name: "part_released",  type: :boolean,                      description: "Whether part has been released to drop zone", observable: true}
      ],

      faults: [
        %Fault{id: "printer_not_ready",   name: "PrinterNotReady",   description: "Printer did not confirm ready within timeout",       severity: :recoverable},
        %Fault{id: "door_open_failed",    name: "DoorOpenFailed",    description: "Printer door failed to open",                       severity: :recoverable},
        %Fault{id: "plate_grip_failed",   name: "PlateGripFailed",   description: "End effector failed to acquire build plate",        severity: :recoverable},
        %Fault{id: "plate_extract_jam",   name: "PlateExtractJam",   description: "Build plate jammed during extraction",              severity: :critical},
        %Fault{id: "part_release_failed", name: "PartReleaseFailed", description: "Part was not successfully released to drop zone",   severity: :recoverable},
        %Fault{id: "unload_lane_blocked", name: "UnloadLaneBlocked", description: "Unload lane sensor indicates obstruction",          severity: :recoverable}
      ]
    }
  end
end
