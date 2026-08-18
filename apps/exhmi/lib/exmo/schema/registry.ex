defmodule ExMo.Schema.Registry do
  @moduledoc """
  Builds the static root ExMo Information Model.

  Contributions from behaviors are merged here. Later, this can be made
  dynamic — behavior modules register themselves, device modules contribute
  printer/drive fragments, etc. For now it's explicit and inspectable.
  """

  alias ExMo.Cell.Loaded

  alias ExMo.Schema.{
    Argument,
    Model,
    Object,
    Property,
    Enum,
    Method,
    ResultField,
    StructType,
    FromAxis,
    FromBehavior
  }
  alias ExMo.Behaviors.K1C.RemovePreviousPrint

  @doc "Returns the uncompiled root model with all registered fragments."
  @spec base_model() :: Model.t()
  def base_model do
    rpp_def = RemovePreviousPrint.definition()
    rpp_catalog = FromBehavior.catalog_object(rpp_def)
    rpp_runtime = FromBehavior.runtime_properties(rpp_def)

    %Model{
      id: "exmo",
      name: "ExMo Information Model",
      version: "0.1.0",
      types: base_types(),
      root: root_object(rpp_catalog, rpp_runtime)
    }
  end

  # ── Type registry ─────────────────────────────────────────────────────────

  defp base_types do
    %{
      "type.axis_state" => %Enum{
        id: "type.axis_state",
        name: "AxisState",
        description:
          "Axis state, in one vocabulary across every interface E-Motion drives " <>
            "— CiA 402 servo, step/dir stepper, PWM servo. `ready` is energised " <>
            "but not accepting motion; `enabled` is live.",
        values: ExMo.Schema.FromAxis.states()
      },
      "type.stored_frame" => %StructType{
        id: "type.stored_frame",
        name: "StoredFrame",
        description:
          "A user frame as stored: six numbers relative to `parent`, or to the " <>
            "arm's base when there is none.",
        fields: stored_pose_fields() ++
          [
            %ResultField{
              name: "parent",
              type: :string,
              description: "The frame this one is relative to, or empty"
            },
            %ResultField{
              name: "mutable",
              type: :boolean,
              description:
                "Whether a running program may write this frame. Taught-constant " <>
                  "against runtime-mutable is the axis that matters — a vision " <>
                  "offset writes a mutable frame at line rate; a taught fixture " <>
                  "origin is configuration and is not writable by a program at all."
            }
          ]
      },
      "type.stored_tool" => %StructType{
        id: "type.stored_tool",
        name: "StoredTool",
        description: "An end-of-arm tool as stored: the flange-to-TCP transform.",
        fields: stored_pose_fields() ++
          [
            %ResultField{
              name: "fitted",
              type: :boolean,
              description: "Whether this tool is the one currently on the flange"
            }
          ]
      },
      "type.behavior_phase" => %Enum{
        id: "type.behavior_phase",
        name: "BehaviorPhase",
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

  defp stored_pose_fields do
    [%ResultField{name: "name", type: :string, description: "The stored name"}] ++
      for {axis, label} <- [
            {"x", "Position along X, metres"},
            {"y", "Position along Y, metres"},
            {"z", "Position along Z, metres"},
            {"rx", "Roll about X, radians"},
            {"ry", "Pitch about Y, radians"},
            {"rz", "Yaw about Z, radians"}
          ] do
        %ResultField{name: axis, type: :double, description: label}
      end
  end

  # ── Object tree ───────────────────────────────────────────────────────────

  defp root_object(rpp_catalog, rpp_runtime) do
    %Object{
      id: "exmo",
      name: "ExMo",
      children: [
        axes_object(),
        behaviors_object(rpp_catalog, rpp_runtime),
        cell_object(),
        printers_object(),
        state_object()
      ]
    }
  end

  defp behaviors_object(rpp_catalog, rpp_runtime) do
    %Object{
      id: "behaviors",
      name: "Behaviors",
      children: [
        %Object{
          id: "behaviors.catalog",
          name: "Catalog",
          children: [rpp_catalog]
        },
        %Object{
          id: "behaviors.runtime",
          name: "Runtime",
          children: [active_behavior_object(rpp_runtime)]
        }
      ]
    }
  end

  defp active_behavior_object(runtime_props) do
    %Object{
      id: "behaviors.runtime.active_behavior",
      name: "ActiveBehavior",
      description: "Live state of the currently executing behavior. Fields are nil when idle.",
      children: runtime_props
    }
  end

  # ── Axes ──────────────────────────────────────────────────────────────────

  # The arm, derived from the chain this controller was commissioned with.
  #
  # This was a literal list of six axes whose limits, per the comment that used
  # to sit here, "mirror the demo chain" — a third description of one arm,
  # agreeing with the other two only for as long as nobody edited any of them.
  # It is now read from the loaded URDF and its commissioning, which is what
  # makes the address space a fact about the machine rather than about the
  # build.
  #
  # `display_unit: :degrees` is a hint to whatever renders these for a human.
  # It does not change the values, which are radians everywhere.
  defp arm_axis_specs do
    chain = Loaded.chain()

    chain.joints
    |> Elixir.Enum.zip(chain.axis_ids)
    |> Elixir.Enum.map(fn {joint, axis_id} ->
      spec = %{
        id: "axes.#{axis_id}",
        name: axis_id |> Atom.to_string() |> String.upcase(),
        type: axis_type(joint.type),
        home_pos: 0.0,
        display_unit: display_unit(joint.type),
        # The joint's name in the document it came from. Less pretty than
        # "Shoulder pan", and true — a controller describing an axis as a
        # shoulder because that is what the last arm's shoulder was called is
        # the class of thing this exercise was about.
        description: joint.name
      }

      # A continuous joint has no travel, and the model says nothing rather
      # than inventing a limit somebody might believe.
      case joint.limit do
        {_lower, _upper} = limits -> Map.put(spec, :limits, limits)
        nil -> spec
      end
    end)
  end

  defp axis_type(:prismatic), do: :linear
  defp axis_type(_rotary), do: :rotary

  defp display_unit(:prismatic), do: :mm
  defp display_unit(_rotary), do: :degrees

  @doc "The registered axis specs, for tests and for whoever wires the drives."
  def arm_axes, do: arm_axis_specs()

  @doc """
  The kinematic chain the axes above form.

  Public because it is the answer to "where is the tool", and that gets asked
  from the projection, from the source that serves it, and from tests alike.
  One description: the Studio draws this chain and the controller computes
  forward kinematics over it.
  """
  def arm_chain, do: Loaded.chain()

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
      id: "axes",
      name: "Axes",
      description:
        "The arm: its joints, and the tool centre point they place. Positions " <>
          "in radians, velocities in rad/s, the tool in metres.",
      children:
        Elixir.Enum.map(arm_axis_specs(), &FromAxis.to_object/1) ++
          [
            tcp_object(),
            cartesian_motion_object(),
            cartesian_jog(),
            move_linear(),
            move_arc()
          ]
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
              "than tracing a cone. Any other name is a user frame stored on " <>
              "the controller, resolved with its parents composed in, so a " <>
              "re-taught fixture moves everything taught in it. An " <>
              "unrecognised name is refused rather than treated as base: a " <>
              "pendant showing one frame while the arm moves in another is a " <>
              "bug found by a fixture."
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


  # ── The cell: stored geometry ─────────────────────────────────────────────

  # Frames and tools are *configuration*, and configuration is the part of a
  # controller an operator changes without a deploy. That is the whole reason
  # they are rows rather than a field on a struct, and this object is where
  # that becomes true from the outside as well.
  #
  # What is deliberately not here is a node per frame. A model node per stored
  # row means the address space changes shape when someone teaches a fixture —
  # which OPC UA can express and this build's compiled model cannot, since it is
  # built once at boot. Listing is therefore a method that returns rows, and the
  # node tree stays a fact about the build rather than about the database.
  defp cell_object do
    %Object{
      id: "cell",
      name: "Cell",
      description:
        "The geometry the controller stores rather than compiles: user frames, " <>
          "end-of-arm tools, and which tool is fitted. Frames are named places " <>
          "to teach in; re-teaching one moves everything taught in it. Tools " <>
          "are the transform from the flange to the tool centre point, and the " <>
          "fitted one is machine state that survives a power cycle.",
      children: [
        %Property{
          id: "cell.tool",
          name: "FittedTool",
          description:
            "The name of the tool currently fitted, or empty for a bare " <>
              "flange. A bare flange is a real state, not a missing answer: it " <>
              "is what the arm has after a changeover nobody finished, and the " <>
              "tool centre point is then the flange itself. Read-only — fitting " <>
              "is a changeover, which is a method, because it is something " <>
              "somebody did to the machine rather than a value to be set.",
          type: :string,
          read_grant: :read_state
        },
        %Property{
          id: "cell.robot",
          name: "Robot",
          description:
            "The name of the robot description this controller was " <>
              "commissioned with, and is running now. Loading a different one " <>
              "takes a restart: the axis nodes above come from this chain, so " <>
              "changing it changes the shape of the address space — which is " <>
              "why this is read-only where a fitted tool is a method.",
          type: :string,
          read_grant: :read_state
        },
        teach_frame(),
        forget_frame(),
        list_frames(),
        teach_tool(),
        list_tools(),
        fit_tool(),
        release_tool()
      ]
    }
  end

  # Six numbers and a name, which is the whole of a frame — and the same six
  # arguments serve teaching a tool, so they are generated rather than typed
  # twice and allowed to drift.
  defp pose_arguments(what) do
    for {axis, label, unit} <- [
          {"x", "along X", "metres"},
          {"y", "along Y", "metres"},
          {"z", "along Z", "metres"},
          {"rx", "roll about X", "radians"},
          {"ry", "pitch about Y", "radians"},
          {"rz", "yaw about Z", "radians"}
        ] do
      %Argument{
        name: axis,
        type: :double,
        required: false,
        default: 0.0,
        description: "#{String.capitalize(label)} of #{what}, #{unit}. Omitted is zero."
      }
    end
  end

  defp teach_frame do
    %Method{
      id: "cell.teach_frame",
      name: "TeachFrame",
      description:
        "Creates a user frame, or re-teaches one that exists. Re-teaching " <>
          "moves everything taught in the frame and nothing else, which is the " <>
          "property frames exist for — and it is why this is one method rather " <>
          "than a create and an update: a fixture that was bumped is the same " <>
          "fixture. `base` and `tool` are refused: the controller computes " <>
          "those and a stored row must not be able to shadow one.",
      async: false,
      call_grant: :write_configuration,
      input_args:
        [
          %Argument{
            name: "name",
            type: :string,
            required: true,
            description:
              "Lowercase, starting with a letter. Case-sensitive names produce " <>
                "two frames that print the same and are not the same, which is " <>
                "a fault nobody finds by reading."
          }
        ] ++
          pose_arguments("the frame's origin") ++
          [
            %Argument{
              name: "parent",
              type: :string,
              required: false,
              description:
                "The frame this one is defined relative to — a jig on a table. " <>
                  "Omitted, the frame is relative to the arm's base. Re-teaching " <>
                  "the parent moves this frame with it. A cycle is refused."
            }
          ],
      output_args: [
        %ResultField{name: "name", type: :string, description: "The frame that was taught"},
        %ResultField{
          name: "created",
          type: :boolean,
          description: "True if the frame did not exist before this call"
        }
      ]
    }
  end

  defp forget_frame do
    %Method{
      id: "cell.forget_frame",
      name: "ForgetFrame",
      description:
        "Deletes a user frame. Refused while another frame is defined relative " <>
          "to it, rather than orphaning the child — and, once points exist, " <>
          "refused while anything is taught in it. A frame that can be deleted " <>
          "out from under a taught path is a path that silently means somewhere " <>
          "else.",
      async: false,
      call_grant: :write_configuration,
      input_args: [
        %Argument{name: "name", type: :string, required: true, description: "The frame to delete"}
      ]
    }
  end

  defp list_frames do
    %Method{
      id: "cell.list_frames",
      name: "ListFrames",
      description:
        "Every stored frame: its name, its parent if it has one, and its six " <>
          "numbers relative to that parent. A method rather than a node per " <>
          "frame, because the node tree is built at boot and teaching a fixture " <>
          "must not change the shape of the address space.",
      async: false,
      call_grant: :read_state,
      output_args: [
        %ResultField{
          name: "frames",
          type: {:array, {:ref, "type.stored_frame"}},
          description: "Stored frames, by name"
        }
      ]
    }
  end

  defp teach_tool do
    %Method{
      id: "cell.teach_tool",
      name: "TeachTool",
      description:
        "Creates an end-of-arm tool, or re-teaches one that exists. The six " <>
          "numbers are the transform from the flange to the tool centre point. " <>
          "Teaching a tool is not fitting it: this describes a thing that " <>
          "exists, and says nothing about what is bolted on right now.",
      async: false,
      call_grant: :write_configuration,
      input_args:
        [
          %Argument{
            name: "name",
            type: :string,
            required: true,
            description: "Lowercase, starting with a letter"
          }
        ] ++ pose_arguments("the tool centre point, from the flange"),
      output_args: [
        %ResultField{name: "name", type: :string, description: "The tool that was taught"},
        %ResultField{
          name: "created",
          type: :boolean,
          description: "True if the tool did not exist before this call"
        }
      ]
    }
  end

  defp list_tools do
    %Method{
      id: "cell.list_tools",
      name: "ListTools",
      description: "Every stored tool, its six numbers, and which one is fitted.",
      async: false,
      call_grant: :read_state,
      output_args: [
        %ResultField{
          name: "tools",
          type: {:array, {:ref, "type.stored_tool"}},
          description: "Stored tools, by name"
        }
      ]
    }
  end

  defp fit_tool do
    %Method{
      id: "cell.fit_tool",
      name: "FitTool",
      description:
        "Records that this tool is now on the flange, and that whatever was " <>
          "there is not. Every pose the controller computes changes with it: " <>
          "the tool centre point moves without the arm moving, and the ISO " <>
          "10218 speed cap starts applying to a different point. It is refused " <>
          "while the arm is moving, because a tool change mid-move would mean " <>
          "the motion finished somewhere other than where it was aimed.\n\n" <>
          "Guarded by `write_configuration` today. Fitting is arguably an " <>
          "operator action where teaching is an engineering one, and the split " <>
          "wants its own grant the first time somebody must be allowed to " <>
          "change a gripper without being allowed to re-teach it.",
      async: false,
      call_grant: :write_configuration,
      input_args: [
        %Argument{name: "name", type: :string, required: true, description: "The tool to fit"}
      ]
    }
  end

  defp release_tool do
    %Method{
      id: "cell.release_tool",
      name: "ReleaseTool",
      description:
        "Records a bare flange. The tool centre point becomes the flange, " <>
          "which is where it actually is once the gripper is in your hand.",
      async: false,
      call_grant: :write_configuration
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
    feedback? = Elixir.Enum.all?(arm_axis_specs(), &FromAxis.feedback?(FromAxis.interface(&1)))

    %Object{
      id: "axes.tcp",
      name: "TCP",
      description:
        "Tool centre point, by forward kinematics over the joints above. " <>
          "Position in metres, orientation in radians as fixed-axis roll, " <>
          "pitch and yaw.",
      meta: %{feedback: feedback?, frame: "base"},
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
              id: "axes.tcp.#{id}",
              name: name,
              description: description,
              type: :double,
              unit: unit,
              readable: true,
              writable: false,
              observable: true,
              meta: %{feedback: feedback?}
            }
          end
        )
    }
  end

  # ── move_linear ───────────────────────────────────────────────────────────

  # Not held, and the contrast with the jog beside it is the point.
  #
  # A jog is an assertion that somebody is still holding a button, so it needs a
  # deadline and dies without one. A move has an end in it — the arrival — and
  # needs nothing to keep talking for it to finish. That is also the thing to be
  # careful about: a client that disappears mid-move does not stop the arm, and
  # anyone who wants it stopped sends something else on the same object.
  #
  # No queue. This build has none, so a second move replaces the first rather
  # than following it. Termination and blending — whether a move settles on its
  # point or rounds through it — are what a queue is for, and are a separate
  # document.
  defp move_linear do
    %Method{
      id: "axes.move_linear",
      name: "MoveLinear",
      description:
        "Move the tool centre point in a straight line to a pose, and stop " <>
          "there. Unlike a jog this is not held: it is sent once and runs to " <>
          "completion, and nothing needs to keep asserting for it to finish — " <>
          "which also means a client that vanishes mid-move does not stop the " <>
          "arm. Translation and rotation are synchronised, so whichever needs " <>
          "longer sets the pace and both arrive together. Solved on the " <>
          "controller's clock from the arm's live pose, under the same rate " <>
          "ceiling, joint limits and tool speed cap as a jog; watch " <>
          "`axes.cartesian` for what it is making of the motion, including " <>
          "`done` when it has arrived. Moves queue: a second one runs after " <>
          "the first rather than replacing it. A jog clears the queue, because " <>
          "an operator taking hold of the arm has taken hold of it.",
      async: true,
      call_grant: :write_setpoint,
      input_args: [
        %Argument{
          name: "x",
          type: :double,
          required: true,
          description: "Target tool position along X of `frame`, metres"
        },
        %Argument{
          name: "y",
          type: :double,
          required: true,
          description: "Target tool position along Y of `frame`, metres"
        },
        %Argument{
          name: "z",
          type: :double,
          required: true,
          description: "Target tool position along Z of `frame`, metres"
        },
        %Argument{
          name: "rx",
          type: :double,
          required: false,
          description:
            "Target tool roll about X of `frame`, radians. Omit all three " <>
              "rotations to keep the orientation the arm already has — which " <>
              "is answered in `frame`, so a rotated frame does not turn the " <>
              "wrist by saying nothing about it."
        },
        %Argument{
          name: "ry",
          type: :double,
          required: false,
          description: "Target tool pitch about Y of `frame`, radians"
        },
        %Argument{
          name: "rz",
          type: :double,
          required: false,
          description: "Target tool yaw about Z of `frame`, radians"
        },
        %Argument{
          name: "feedrate",
          type: :double,
          required: false,
          description:
            "Tool speed along the path, m/s. Capped at the mode's tool speed " <>
              "limit — 250 mm/s in manual per ISO 10218 — by scaling rather " <>
              "than by refusing."
        },
        %Argument{
          name: "blend",
          type: :double,
          required: false,
          description:
            "Radius in metres within which this move gives way to the next, " <>
              "rounding the corner instead of settling in it. Omitted, the " <>
              "move stops on its end point. These are the FINE and CNT " <>
              "terminations every teach pendant shows per line. Ignored when " <>
              "nothing is queued behind: rounding a corner into nothing is " <>
              "just stopping short."
        },
        target_frame_argument()
      ]
    }
  end

  # ── move_arc ──────────────────────────────────────────────────────────────

  # Three points, which is the form every teach pendant uses and the only one
  # that can be taught by driving the arm somewhere three times.
  defp move_arc do
    %Method{
      id: "axes.move_arc",
      name: "MoveArc",
      description:
        "Move the tool centre point along a circular arc through a via point " <>
          "to an end pose. The circle is the one through three points: where " <>
          "the arm is when the move starts, the via point, and the end. Three " <>
          "points that do not define a circle — collinear, or two of them the " <>
          "same — are refused rather than approximated, because an arc that " <>
          "quietly becomes a straight line is a program doing something other " <>
          "than what it says. Otherwise identical to `move_linear`: not held, " <>
          "queued behind whatever is running, under the same limits, and " <>
          "reported through `axes.cartesian`.",
      async: true,
      call_grant: :write_setpoint,
      input_args:
        arc_point_args() ++
          [
            %Argument{
              name: "feedrate",
              type: :double,
              required: false,
              description:
                "Tool speed along the arc, m/s. Capped at the mode's tool " <>
                  "speed limit, by scaling rather than by refusing."
            },
            %Argument{
              name: "blend",
              type: :double,
              required: false,
              description:
                "Radius in metres within which this move gives way to the " <>
                  "next, rounding the corner instead of settling in it. " <>
                  "Omitted, the move stops on its end point. These are the " <>
                  "FINE and CNT terminations every teach pendant shows per " <>
                  "line. Ignored when nothing is queued behind: rounding a " <>
                  "corner into nothing is just stopping short."
            },
            target_frame_argument()
          ]
    }
  end

  # The frame a *destination* is named in, which is narrower than the frame a
  # velocity is pushed along. `tool` is refused here: the tool is where the arm
  # already is, so a destination named in it is either a no-op or a request for
  # relative motion — and relative motion should be its own method rather than
  # a surprising reading of this one.
  defp target_frame_argument do
    %Argument{
      name: "frame",
      type: :string,
      required: false,
      default: "base",
      description:
        "The frame the target is given in. `base` — the arm's origin. Any " <>
          "other name is a user frame stored on the controller, with its " <>
          "parents composed in, so re-teaching a fixture moves every target " <>
          "given in it. `tool` is refused, as is any name that is not stored: " <>
          "a destination that quietly means somewhere else is the failure this " <>
          "argument exists to prevent."
    }
  end

  defp arc_point_args do
    for {prefix, what} <- [{"via", "the point the arc passes through"}, {"", "the end pose"}],
        {axis, label} <- [
          {"x", "position along X of `frame`, metres"},
          {"y", "position along Y of `frame`, metres"},
          {"z", "position along Z of `frame`, metres"}
        ] do
      %Argument{
        name: if(prefix == "", do: axis, else: prefix <> "_" <> axis),
        type: :double,
        required: true,
        description: "#{String.capitalize(label)} of #{what}"
      }
    end
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
            "idle | tracking | limited | refused | done. `done` is a " <>
              "`move_linear` that has arrived, and is distinct from `idle` on " <>
              "purpose: a finished move and a move that was never asked for " <>
              "should not look the same. `limited` means the motion " <>
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
      id: "printers",
      name: "Printers",
      children: [k1c_01_object()]
    }
  end

  defp k1c_01_object do
    %Object{
      id: "printers.k1c_01",
      name: "K1C_01",
      description: "Creality K1C printer, unit 01",
      children: [
        %Property{
          id: "printers.k1c_01.ready_for_unload",
          name: "ReadyForUnload",
          type: :boolean,
          description: "True when printer has a completed job ready for plate removal"
        },
        %Property{
          id: "printers.k1c_01.door_state",
          name: "DoorState",
          type: :string,
          description: "Current door state: open | closed | fault"
        },
        %Property{
          id: "printers.k1c_01.build_plate_present",
          name: "BuildPlatePresent",
          type: :boolean,
          description: "True if build plate is detected inside the printer"
        },
        %Property{
          id: "printers.k1c_01.unload_lane_clear",
          name: "UnloadLaneClear",
          type: :boolean,
          description: "True if unload lane sensor indicates no obstruction"
        }
      ]
    }
  end

  defp state_object do
    %Object{
      id: "state",
      name: "State",
      description: "Top-level controller state",
      children: [
        %Property{
          id: "state.controller_mode",
          name: "ControllerMode",
          type: :string,
          observable: true,
          description:
            "idle | manual | auto | fault. Jogging is permitted in manual and " <>
              "refused in every other mode — a grant answers whether this " <>
              "person may ever jog, and this answers whether the machine is in " <>
              "a state where jogging is what should be happening. Read-only " <>
              "and deliberately so: on a machine this is a keyswitch, and a " <>
              "client that could turn it in order to be allowed to move the arm " <>
              "would not have been interlocked so much as asked politely. " <>
              "`fault` is reported whenever any axis is faulted, whatever the " <>
              "selector says, because an operator looking at a faulted machine " <>
              "is not helped by being told it is in manual."
        },
        %Property{
          id: "state.fault_present",
          name: "FaultPresent",
          type: :boolean,
          description: "True if any active fault is present on the controller"
        }
      ]
    }
  end
end
