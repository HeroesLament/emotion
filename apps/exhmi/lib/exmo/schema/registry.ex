defmodule ExMo.Schema.Registry do
  @moduledoc """
  Builds the static root ExMo Information Model.

  Contributions from behaviors are merged here. Later, this can be made
  dynamic — behavior modules register themselves, device modules contribute
  printer/drive fragments, etc. For now it's explicit and inspectable.
  """

  alias ExMo.Schema.{Argument, Model, Object, Property, Enum, Method, FromAxis, FromBehavior}
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

  @doc """
  The kinematic chain the axes above form.

  Public because it is the answer to "where is the tool", and that gets asked
  from the projection, from the source that serves it, and from tests alike.
  One description: the Studio draws this chain and the controller computes
  forward kinematics over it.
  """
  def arm_chain, do: ExMove.Library.demo()

  # The joints, and the point at the end of them.
  #
  # The id is `axes` because that is the object which contains the joints, and
  # a tool centre point is a fact about the set of them rather than about any
  # one. It reads a little oddly and it is deliberate: the alternative is
  # wrapping everything in an `arm` object today, which renames every node id
  # in the published protocol and 169 call sites, to buy a distinction that
  # only starts to pay when there are two arms. When there are, this becomes
  # `arm_a.axes` and the rename is worth it.
  #
  # It also puts the TCP inside the same subtree as the joints, which is what
  # `ExProto.Jog` needs: a Cartesian jog is one held command on this object,
  # and a hold on it has to cover every joint underneath.
  defp axes_object do
    %Object{
      id:          "axes",
      name:        "Axes",
      description:
        "The arm: its joints, and the tool centre point they place. Positions " <>
          "in radians, velocities in rad/s, the tool in metres.",
      children:
        Elixir.Enum.map(@arm_axes, &FromAxis.to_object/1) ++
          [tcp_object(), cartesian_motion_object(), cartesian_jog()]
    }
  end

  # ── Cartesian jog ─────────────────────────────────────────────────────────

  # Held, like the per-axis jog, and held on THIS object — which is what makes
  # it safe. One Cartesian assertion moves six joints, so it has to be one hold
  # with one deadline: six per-axis holds would mean one of them lapsing stops
  # one joint and leaves five running, which is worse than either stopping or
  # not stopping. `ExProto.Jog` keys the hold on the method's parent and treats
  # a hold as covering everything beneath it, so holding this locks every joint
  # under `axes` against another session.
  #
  # One direction at a time, not a six-vector twist. A pendant has buttons and
  # an operator presses one; more importantly, the watchdog contract is that a
  # held method takes a `velocity` whose neutral value is zero, and a twist
  # vector has no single number to zero. Diagonal motion is a program, not a
  # jog.
  defp cartesian_jog do
    bounds = Method.watchdog_deadline_ms()

    %Method{
      id: "axes.jog_cartesian",
      name: "JogCartesian",
      description:
        "Move the tool centre point along or about one axis of the chosen " <>
          "frame, for as long as the client keeps saying so. Held exactly " <>
          "like a joint jog: re-send at around 10 Hz, and the controller " <>
          "commands zero as soon as assertions stop arriving. An assertion " <>
          "refreshes the direction and speed; the controller re-solves from " <>
          "the arm's live joint positions on its own clock, so the path does " <>
          "not depend on how often the client can speak, and the frame is " <>
          "re-resolved with it, so a rotation about a tool axis follows the " <>
          "tool rather than tracing a cone. Solved differentially from where " <>
          "the arm is, so it stays on the configuration it is already in " <>
          "rather than flipping elbow or wrist mid-move. When a joint would " <>
          "have to turn faster than it can, or would run out of travel, or " <>
          "more tool speed is asked for than manual mode allows, the whole " <>
          "joint vector is scaled rather than clamped per joint — the tool " <>
          "stays exactly on the commanded line and the motion slows. " <>
          "Watch `axes.cartesian` for what the controller is making of it: " <>
          "the state, the fraction of commanded speed being delivered, the " <>
          "reason, and the joint responsible when there is one. Approaching a " <>
          "singularity that fraction falls to zero and the jog is refused; " <>
          "use a joint jog, which is the only way out of one.",
      async: true,
      call_grant: :jog,
      meta: %{watchdog: true},
      input_args: [
        %Argument{
          name: "axis",
          type: :string,
          required: true,
          description:
            "Which direction to move in: x | y | z for translation, rx | ry | " <>
              "rz for rotation. Interpreted in `frame`."
        },
        %Argument{
          name: "velocity",
          type: :double,
          required: true,
          description:
            "Signed tool speed, m/s for a translation and rad/s for a " <>
              "rotation. Zero is the neutral assertion. Translation is capped " <>
              "at the manual-mode tool speed limit — 250 mm/s per ISO 10218 — " <>
              "by scaling rather than by refusing, so asking for more gets a " <>
              "slower move in the right direction rather than an error. A " <>
              "functional limit, not a safety-rated one."
        },
        %Argument{
          name: "frame",
          type: :string,
          required: false,
          default: "base",
          description:
            "`base` — the arm's origin, fixed in the cell. `tool` — the current " <>
              "tool centre point orientation, re-resolved every controller " <>
              "tick, so a rotation about a tool axis follows the tool rather " <>
              "than tracing a cone. `user` frames are not implemented and are " <>
              "refused, as is anything unrecognised: a pendant showing one " <>
              "frame while the arm moves in another is a bug found by a fixture."
        },
        %Argument{
          name: "deadlineMs",
          type: :uint16,
          required: false,
          default: bounds.default,
          description:
            "How long this assertion stands. Clamped to " <>
              "#{bounds.min}..#{bounds.max} ms; read the granted value from " <>
              "the acceptance."
        }
      ]
    }
  end

  # ── Tool centre point ─────────────────────────────────────────────────────

  # Derived, not measured, and read-only for the same reason `direction` is: a
  # pose is where the arm has ended up, not something a client sets. Commanding
  # the tool somewhere is a Cartesian move, which is a method.
  #
  # Six flat doubles rather than one struct. A pendant subscribing to a pose
  # wants to know when Z changed, and a struct-valued node changes when any
  # field does — so every wrist rotation would wake every client watching
  # height. Flat also means the OPC UA projection and the JSON-RPC one need no
  # struct support to publish it.
  #
  # Forward kinematics is exact given the joints, so this is only ever as
  # trustworthy as they are — which is what `feedback` says, carried up from
  # the axes rather than asserted here. An arm of open-loop steppers reports a
  # tool centre point computed from where it believes it is.
  defp tcp_object do
    feedback? = Elixir.Enum.all?(@arm_axes, &FromAxis.feedback?(FromAxis.interface(&1)))

    %Object{
      id:          "axes.tcp",
      name:        "TCP",
      description:
        "Tool centre point, by forward kinematics over the joints above. " <>
          "Position in metres, orientation in radians as fixed-axis roll, " <>
          "pitch and yaw.",
      meta:        %{feedback: feedback?, frame: "base"},
      children:
        Elixir.Enum.map(
          [
            {"x", "X", "m", "Tool position along base X"},
            {"y", "Y", "m", "Tool position along base Y"},
            {"z", "Z", "m", "Tool position along base Z"},
            {"rx", "Rx", "rad", "Tool roll about base X"},
            {"ry", "Ry", "rad", "Tool pitch about base Y"},
            {"rz", "Rz", "rad", "Tool yaw about base Z"}
          ],
          fn {id, name, unit, description} ->
            %Property{
              id:          "axes.tcp.#{id}",
              name:        name,
              description: description,
              type:        :double,
              unit:        unit,
              readable:    true,
              writable:    false,
              observable:  true,
              meta:        %{feedback: feedback?}
            }
          end
        )
    }
  end

  # ── What the Cartesian motion is actually doing ───────────────────────────

  # A jog near a singularity slows down. That is correct — the arm cannot hold a
  # constant tool speed there — and it is indistinguishable, from a pendant, from
  # a controller that has hung. Whether the operator experiences a machine
  # explaining itself or a machine that feels broken is decided entirely by
  # whether these two nodes exist.
  #
  # Read-only and observable, because this is the controller narrating its own
  # decisions. Nothing writes here; the way to change it is to jog somewhere
  # else.
  defp cartesian_motion_object do
    %Object{
      id: "axes.cartesian",
      name: "Cartesian",
      description:
        "What the controller is making of the Cartesian motion it has been " <>
          "asked for. Idle unless a Cartesian jog is being held.",
      children: [
        %Property{
          id: "axes.cartesian.state",
          name: "State",
          description:
            "idle | tracking | limited | refused. `limited` means the motion " <>
              "is on the commanded line and slower than asked; read " <>
              "`speed_fraction` for how much slower and `reason` for why. " <>
              "`refused` means the arm cannot go where it was pointed and has " <>
              "been commanded to zero. Neither is a fault and neither latches: " <>
              "jog somewhere else and the next tick tracks.",
          type: :string,
          readable: true,
          writable: false,
          observable: true
        },
        %Property{
          id: "axes.cartesian.speed_fraction",
          name: "SpeedFraction",
          description:
            "The fraction of the commanded tool speed being delivered, 0 to 1. " <>
              "1.0 when tracking or idle. Below 1 the joint rates the command " <>
              "asks for exceed what a joint can turn, and the whole vector is " <>
              "scaled — so the direction is exactly as commanded and only the " <>
              "speed gives way.",
          type: :double,
          readable: true,
          writable: false,
          observable: true
        },
        %Property{
          id: "axes.cartesian.reason",
          name: "Reason",
          description:
            "Why the motion is limited or refused, empty when it is neither. " <>
              "`rate` — a joint would have to turn faster than it can, which is " <>
              "what approaching a singularity looks like from the rate side. " <>
              "`joint_limit` — a joint is at or approaching the end of its " <>
              "travel; `joint` names it. `tool_speed` — more tool speed was " <>
              "asked for than manual mode allows, which is policy rather than " <>
              "the arm's own limit and never causes a refusal. `singular` — " <>
              "the arm cannot move in the direction asked at all. `unreadable` " <>
              "— a joint could not be read, which is a wiring problem rather " <>
              "than a kinematic one.",
          type: :string,
          readable: true,
          writable: false,
          observable: true
        },
        %Property{
          id: "axes.cartesian.joint",
          name: "Joint",
          description:
            "The axis that is limiting the motion, empty when none is. " <>
              "Populated when `reason` is joint_limit. \"The arm stopped\" is a " <>
              "support call; \"J5 is at its limit\" is something an operator can " <>
              "act on without one, and the difference is this node.",
          type: :string,
          readable: true,
          writable: false,
          observable: true
        },
        %Property{
          id: "axes.cartesian.manipulability",
          name: "Manipulability",
          description:
            "sqrt(det(J·Jt)) at the current pose, zero at a singularity. " <>
              "Published for a viewport to shade reachability with, and " <>
              "deliberately not what the controller decides on: it describes " <>
              "the pose and not the command, so it collapses identically " <>
              "whether the freedom being lost is one the operator asked for or " <>
              "one they did not.",
          type: :double,
          readable: true,
          writable: false,
          observable: true
        }
      ]
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
