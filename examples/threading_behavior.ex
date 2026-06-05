defmodule ExMo.Behaviors.MiniLathe.Threading do
  @moduledoc """
  Public contract for the Threading behavior.

  Synchronises Z-axis leadscrew motion to spindle rotation to cut
  either US (TPI) or metric (mm/rev) threads. The behavior owns the
  entire threading pass from approach to retract — the caller only
  supplies the thread specification and pass depth.

  What the behavior does:
  1. Verify spindle is at speed and encoder is locked
  2. Wait for index pulse (Z=0 datum)
  3. Engage leadscrew feed at the computed mm/rev ratio
  4. Drive Z from start_z to end_z while tracking spindle encoder
  5. Rapid-retract Z to clear_z
  6. Optionally repeat for multi-pass (each pass increments depth by
     pass_depth until target_depth is reached)
  7. Return to start_z at rapid feed, ready for next cycle

  Threading is synchronous within a pass but the behavior itself is async —
  the caller receives a job_id and observes progress via runtime fields.

  Standard hint:
    - US threads:     pass standard: :us,     tpi: 20        (20 TPI = 1.27 mm/rev)
    - Metric threads: pass standard: :metric, pitch_mm: 1.25 (M8 coarse)
  """

  @behaviour ExMo.Behavior

  alias ExMo.Behavior.{Definition, RuntimeField, Fault}
  alias ExMo.Schema.{Argument, ResultField}

  @impl ExMo.Behavior
  def definition do
    %Definition{
      id:          "behavior.threading",
      name:        "Threading",
      description: "Cut US or metric threads by synchronising the Z leadscrew to spindle rotation.",
      async:       true,

      input_args: [
        %Argument{
          name:        "standard",
          type:        :string,
          description: "Thread standard: \"us\" or \"metric\"",
          required:    true
        },
        %Argument{
          name:        "tpi",
          type:        :float,
          description: "Threads per inch (required when standard = \"us\")",
          required:    false
        },
        %Argument{
          name:        "pitch_mm",
          type:        :float,
          description: "Thread pitch in mm/rev (required when standard = \"metric\")",
          required:    false
        },
        %Argument{
          name:        "start_z",
          type:        :float,
          description: "Z position at which threading engagement begins (mm)",
          required:    true
        },
        %Argument{
          name:        "end_z",
          type:        :float,
          description: "Z position at which threading disengages and retracts (mm)",
          required:    true
        },
        %Argument{
          name:        "clear_z",
          type:        :float,
          description: "Z rapid-retract position after each pass (mm, must be > start_z)",
          required:    true
        },
        %Argument{
          name:        "target_depth",
          type:        :float,
          description: "Total thread depth (radial infeed from surface, mm)",
          required:    true
        },
        %Argument{
          name:        "pass_depth",
          type:        :float,
          description: "Infeed per pass (mm). Behavior computes pass count automatically.",
          required:    true
        },
        %Argument{
          name:        "spindle_rpm",
          type:        :float,
          description: "Target spindle speed. Behavior verifies before engaging.",
          required:    true
        },
        %Argument{
          name:        "direction",
          type:        :string,
          description: "Thread hand: \"rh\" (right-hand, default) or \"lh\" (left-hand)",
          required:    false,
          default:     "rh"
        },
        %Argument{
          name:        "correlation_id",
          type:        :string,
          description: "Caller-supplied idempotency / tracing token",
          required:    false
        }
      ],

      output_args: [
        %ResultField{name: "accepted",      type: :boolean, description: "Whether the behavior was accepted for execution"},
        %ResultField{name: "job_id",        type: :string,  description: "Assigned job identifier for tracking"},
        %ResultField{name: "passes_cut",    type: :uint16,  description: "Number of passes completed before completion or fault"},
        %ResultField{name: "result_code",   type: :int32,   description: "Numeric result code (0 = success)"},
        %ResultField{name: "message",       type: :string,  description: "Human-readable result or rejection reason"}
      ],

      runtime_fields: [
        %RuntimeField{name: "phase",            type: {:ref, "type.behavior_phase"}, description: "Current public phase",                                    observable: true},
        %RuntimeField{name: "progress",         type: :uint16,                       description: "Estimated percent complete across all passes (0–100)",   observable: true},
        %RuntimeField{name: "current_pass",     type: :uint16,                       description: "Pass number currently being cut",                        observable: true},
        %RuntimeField{name: "total_passes",     type: :uint16,                       description: "Total passes computed from target_depth / pass_depth",   observable: true},
        %RuntimeField{name: "depth_achieved",   type: :float,                        description: "Cumulative radial infeed completed so far (mm)",          observable: true},
        %RuntimeField{name: "z_position",       type: :float,                        description: "Live Z position during a pass (mm)",                     observable: true},
        %RuntimeField{name: "spindle_rpm",      type: :float,                        description: "Actual spindle speed at last encoder sample",            observable: true},
        %RuntimeField{name: "feed_rate",        type: :float,                        description: "Computed Z feed rate for current spindle speed (mm/min)", observable: true},
        %RuntimeField{name: "sync_locked",      type: :boolean,                      description: "True when encoder synchronisation is established",       observable: true},
        %RuntimeField{name: "fault_code",       type: :string,                       description: "Fault ID if phase == fault, else nil",                   observable: true},
        %RuntimeField{name: "fault_message",    type: :string,                       description: "Human-readable fault detail",                            observable: true}
      ],

      faults: [
        %Fault{id: "spindle_not_at_speed",   name: "SpindleNotAtSpeed",   description: "Spindle did not reach target RPM within timeout",            severity: :recoverable},
        %Fault{id: "encoder_sync_lost",      name: "EncoderSyncLost",     description: "Spindle encoder sync was lost mid-pass — Z halted safely",   severity: :critical},
        %Fault{id: "z_overtravel",           name: "ZOvertravel",         description: "Z axis reached a soft or hard limit during a pass",          severity: :critical},
        %Fault{id: "feed_rate_unachievable", name: "FeedRateUnachievable", description: "Required Z feed rate exceeds axis velocity limit for given TPI/RPM combination", severity: :recoverable},
        %Fault{id: "pass_depth_too_large",   name: "PassDepthTooLarge",   description: "pass_depth exceeds safe single-pass limit for this material", severity: :recoverable},
        %Fault{id: "retract_failed",         name: "RetractFailed",       description: "Z did not reach clear_z after a pass",                       severity: :critical}
      ]
    }
  end
end
