defmodule EMotion.Schema.Registry do
  @moduledoc """
  Builds the static root E-Motion Information Model.

  Contributions from behaviors are merged here. Later, this can be made
  dynamic — behavior modules register themselves, device modules contribute
  printer/drive fragments, etc. For now it's explicit and inspectable.
  """

  alias EMotion.Cell.Loaded

  alias EMotion.Schema.{
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
  alias EMotion.Behaviors.K1C.RemovePreviousPrint

  @doc "Returns the uncompiled root model with all registered fragments."
  @spec base_model() :: Model.t()
  def base_model do
    rpp_def = RemovePreviousPrint.definition()
    rpp_catalog = FromBehavior.catalog_object(rpp_def)
    rpp_runtime = FromBehavior.runtime_properties(rpp_def)

    %Model{
      id: "emotion",
      name: "E-Motion Information Model",
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
        values: EMotion.Schema.FromAxis.states()
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
      "type.stored_program" => %StructType{
        id: "type.stored_program",
        name: "StoredProgram",
        description: "A stored program, without its body.",
        fields: [
          %ResultField{name: "name", type: :string, description: "The program's name"},
          %ResultField{
            name: "statements",
            type: :int32,
            description: "How many statements it has"
          }
        ]
      },
      "type.statement" => %StructType{
        id: "type.statement",
        name: "Statement",
        description:
          "One statement of a program: what kind it is, and every argument it " <>
            "was given. Structure rather than a rendering, so a client can " <>
            "reconstruct the statement rather than only display it — see " <>
            "PROGRAMS.md \u00a7\"Why structure is authoritative and text is a " <>
            "rendering\".",
        fields: [
          %ResultField{name: "seq", type: :int32, description: "Its place in the body, from zero"},
          %ResultField{name: "kind", type: :string, description: "Which statement kind"},
          %ResultField{
            name: "args",
            type: {:array, {:ref, "type.statement_arg"}},
            description:
              "Every argument, literal and reference alike, in exactly the shape " <>
                "`program.append` accepts. Handing this straight back reproduces " <>
                "the statement, which is what makes a program exportable."
          },
          %ResultField{
            name: "refs",
            type: {:array, {:ref, "type.statement_ref"}},
            description:
              "What this statement depends on, by kind. Derived from the same " <>
                "rows as `args`, so it cannot disagree \u2014 it exists so a client " <>
                "can answer \"which points does this program use\" without " <>
                "fetching the kind registry to find out which sockets are " <>
                "references."
          }
        ]
      },
      "type.statement_kind" => %StructType{
        id: "type.statement_kind",
        name: "StatementKind",
        description:
          "One statement kind and its sockets. `motion` is not decoration: it " <>
            "is what the executor reads to decide whether a statement may be " <>
            "queued ahead of the arm or has to wait for it, so an editor can " <>
            "show which lines blend and which are barriers.",
        fields: [
          %ResultField{name: "name", type: :string, description: "Its name, as stored"},
          %ResultField{name: "label", type: :string, description: "For a human"},
          %ResultField{name: "description", type: :string, description: "What it does"},
          %ResultField{name: "motion", type: :boolean, description: "Whether it moves the arm"},
          %ResultField{
            name: "params",
            type: {:array, {:ref, "type.statement_param"}},
            description: "Its sockets, in order"
          }
        ]
      },
      "type.statement_param" => %StructType{
        id: "type.statement_param",
        name: "StatementParam",
        description:
          "One socket of a statement kind. `type` carries physical dimension " <>
            "rather than storage width — `velocity`, `length`, `angle`, " <>
            "`duration` are not `number` with a comment — and `point`, `frame`, " <>
            "`tool`, `program` are the types that become references rather than " <>
            "values.",
        fields: [
          %ResultField{name: "name", type: :string, description: "The socket name"},
          %ResultField{name: "type", type: :string, description: "Its declared type"},
          %ResultField{name: "required", type: :boolean, description: "Whether it must be given"},
          %ResultField{name: "default", type: :string, description: "Its default, rendered, or empty"},
          %ResultField{name: "description", type: :string, description: "What it means"}
        ]
      },
      "type.joint_setting" => %StructType{
        id: "type.joint_setting",
        name: "JointSetting",
        description:
          "What commissioning says about one joint, keyed by the URDF's name " <>
            "for it. A property of this model of arm rather than of this unit — " <>
            "see INSTALLATION.md on why that distinction is worth keeping.",
        fields: [
          %ResultField{name: "joint", type: :string, description: "The URDF's name for it"},
          %ResultField{name: "axis", type: :string, description: "Which drive drives it"},
          %ResultField{name: "max_vel", type: :double, description: "Ceiling, rad/s"},
          %ResultField{name: "max_acc", type: :double, description: "Ceiling, rad/s²"},
          %ResultField{name: "soft_lower", type: :double, description: "Soft limit, rad"},
          %ResultField{name: "soft_upper", type: :double, description: "Soft limit, rad"},
          %ResultField{name: "home", type: :double, description: "Where home is, rad"}
        ]
      },
      "type.installation_robot" => %StructType{
        id: "type.installation_robot",
        name: "InstallationRobot",
        description:
          "The robot description this controller was commissioned with. The " <>
            "URDF travels as text because that is what it is; nothing here " <>
            "describes how THIS unit differs from nominal, which is a gap " <>
            "INSTALLATION.md names rather than fills.",
        fields: [
          %ResultField{name: "name", type: :string, description: "Its name"},
          %ResultField{name: "urdf", type: :string, description: "The description, verbatim"}
        ]
      },
      "type.statement_ref" => %StructType{
        id: "type.statement_ref",
        name: "StatementReference",
        description:
          "A statement's dependency on something with its own life: a point, a " <>
            "frame, a tool or another program. Travels by name because that is " <>
            "what a person taught; the controller stores a foreign key, which " <>
            "is what refuses the referent's deletion later.",
        fields: [
          %ResultField{name: "arg", type: :string, description: "The socket it fills"},
          %ResultField{
            name: "kind",
            type: :string,
            description: "What sort of thing: point, frame, tool or program"
          },
          %ResultField{name: "name", type: :string, description: "Which one, by name"}
        ]
      },
      "type.statement_arg" => %StructType{
        id: "type.statement_arg",
        name: "StatementArgument",
        description:
          "One argument to a statement: the socket it fills, and its value as " <>
            "text. Values travel as text because that is what a form field " <>
            "produces; what each one MEANS is declared by the statement kind, " <>
            "so a `:velocity` socket parses its value as a speed and a " <>
            "`:point` socket keeps it as the name of a taught point. The " <>
            "conversion is driven by the declared type, never guessed from the " <>
            "string \u2014 a point legitimately named \"12\" must not become a number.",
        fields: [
          %ResultField{name: "name", type: :string, description: "The socket, e.g. \"point\""},
          %ResultField{name: "value", type: :string, description: "Its value, as text"}
        ]
      },
      "type.stored_point" => %StructType{
        id: "type.stored_point",
        name: "StoredPoint",
        description:
          "A taught point: where the arm was, expressed in the frame it was " <>
            "taught in, with the tool that was fitted and the joint solution " <>
            "it was actually in.",
        fields:
          stored_pose_fields() ++
            [
              %ResultField{
                name: "frame",
                type: :string,
                description: "The frame the pose is expressed in; `base` when it has none"
              },
              %ResultField{
                name: "tool",
                type: :string,
                description:
                  "The tool that was fitted when this was taught, or empty for a bare flange"
              },
              %ResultField{
                name: "joints",
                type: {:array, :double},
                description:
                  "The joint solution the arm was in, radians, base to tip. Replaying " <>
                    "these is the one way to reach a taught pose that cannot arrive on " <>
                    "the mirror-image configuration."
              },
              %ResultField{
                name: "mutable",
                type: :boolean,
                description: "Whether a running program may write this point"
              },
              %ResultField{
                name: "source",
                type: :string,
                description:
                  "How it got its numbers: `taught` if the arm was here and " <>
                    "somebody said so, `defined` if a file did — a program " <>
                    "pushed from a studio, or a backup. Not a quality ranking; " <>
                    "a different fact is missing in each, and a pendant that " <>
                    "cannot tell them apart cannot warn anybody that a program " <>
                    "moves to places this arm has never been to."
              }
            ] ++ base_pose_fields()
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
      "type.axis_mastering" => %StructType{
        id: "type.axis_mastering",
        name: "AxisMastering",
        description:
          "What one joint says about its own zero. `state` is the useful " <>
            "field and its three values are different missing facts rather " <>
            "than severity levels: `unmastered` means nobody ever declared a " <>
            "zero for this joint; `unreferenced` means the zero is known but " <>
            "the turn count was lost, which is what happens when the joint " <>
            "was moved while the power was off; `referenced` means nothing is " <>
            "missing. Only the last permits Cartesian motion, taught points or " <>
            "a program. Joint jog stays available in all of them, because " <>
            "driving to the witness mark is how an axis is recovered.",
        fields: [
          %ResultField{name: "axis", type: :string, description: "The drive"},
          %ResultField{
            name: "state",
            type: :string,
            description: "unmastered | unreferenced | referenced | unreadable"
          },
          %ResultField{
            name: "offset",
            type: :double,
            description: "Accumulator value at joint zero, radians. Zero when unknown."
          },
          %ResultField{
            name: "drift",
            type: :double,
            description:
              "Radians the joint appears to have moved while the power was " <>
                "off. Reported even when it was inside tolerance: a drift " <>
                "that creeps toward the limit over months is a slipping " <>
                "coupling, and swallowing it because it passed is how that " <>
                "finding is lost."
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

  # Where the point is *now*, in the base, with its frame resolved through
  # whatever the frame's parents currently say. Computed rather than stored, and
  # published beside the stored pose rather than instead of it, because the two
  # answer different questions: the stored numbers are what a person taught and
  # stay true when the fixture moves, and these are where the arm would
  # actually go if it were sent there this second.
  defp base_pose_fields do
    for {axis, label} <- [
          {"x", "Position along base X, metres"},
          {"y", "Position along base Y, metres"},
          {"z", "Position along base Z, metres"},
          {"rx", "Roll about base X, radians"},
          {"ry", "Pitch about base Y, radians"},
          {"rz", "Yaw about base Z, radians"}
        ] do
      %ResultField{
        name: "base_" <> axis,
        type: :double,
        description: label <> ", with the point's frame resolved as it stands now"
      }
    end
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
      id: "emotion",
      name: "EMotion",
      children: [
        axes_object(),
        behaviors_object(rpp_catalog, rpp_runtime),
        cell_object(),
        programs_object(),
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


  # ── Programs ──────────────────────────────────────────────────────────────

  # What a pendant renders while a program runs, and the handful of commands
  # that drive one. The *body* is not here: `PROGRAMS.md` §4 keeps it off this
  # link, because a program of a thousand statements has no business in a frame
  # competing with a 30 Hz position stream.
  defp programs_object do
    %Object{
      id: "program",
      name: "Program",
      description:
        "The stored program this controller is running, and the commands that " <>
          "run it. A program runs in auto and is refused in manual, the mirror " <>
          "of a jog — and once started it does not depend on the client that " <>
          "started it, which is the property that makes this a controller " <>
          "rather than a document.",
      children: [
        %Property{
          id: "program.name",
          name: "Name",
          description: "The program that is loaded, or empty when none is",
          type: :string,
          read_grant: :read_state
        },
        %Property{
          id: "program.state",
          name: "State",
          description:
            "idle | running | held | faulted | done. `held` is stopped and " <>
              "resumable; `faulted` is stopped because a statement was refused " <>
              "and is not. `done` is distinct from `idle` on purpose: a program " <>
              "that finished and one that was never started should not look the " <>
              "same.",
          type: :string,
          read_grant: :read_state
        },
        %Property{
          id: "program.statement",
          name: "Statement",
          description:
            "The index of the statement the *arm* is on, which is not always " <>
              "the one the interpreter has reached — motion is queued ahead so " <>
              "moves can blend. This is the line a pendant highlights.",
          type: :int32,
          read_grant: :read_state
        },
        %Property{
          id: "program.statements",
          name: "Statements",
          description: "How many statements the loaded program has",
          type: :int32,
          read_grant: :read_state
        },
        %Property{
          id: "program.kind",
          name: "Kind",
          description: "The kind of statement being executed, or empty",
          type: :string,
          read_grant: :read_state
        },
        %Property{
          id: "program.reason",
          name: "Reason",
          description:
            "Why the run faulted, in the controller's own words — a refused " <>
              "move, a tool that does not match what the point was taught with. " <>
              "Empty unless the state is `faulted`.",
          type: :string,
          read_grant: :read_state
        },
        program_start(),
        program_hold(),
        program_resume(),
        program_step(),
        program_stop(),
        program_list(),
        program_show(),
        program_create(),
        program_delete(),
        program_append(),
        program_replace(),
        program_remove(),
        program_move(),
        program_kinds(),
        program_validate()
      ]
    }
  end

  # ── Editing a program over the wire ───────────────────────────────────────
  #
  # Statement at a time, not whole-body, and that is the recorded decision
  # rather than a shortcut. `protocol/README.md`: "Bulk transfer — program
  # source, logs, motion traces — is not on this link. It is plain HTTP on the
  # same host so it stays curl-able and does not compete with live telemetry."
  # A thousand-statement body does not belong in a frame competing with a 30 Hz
  # position stream; a single edit made by a person with an editor open does.
  #
  # Every one of these refuses while that program is running. The danger is not
  # the engine reading a changed body — `ExProto.Program.Run` captures the body
  # at start deliberately — it is the operator believing the thing they just
  # edited is the thing that ran.
  #
  # All are guarded by `edit_program`, which already exists and is already
  # distinct from `load_program` (choose what runs) and `execute_program`
  # (start it). Someone may be allowed to run a cell's programs without being
  # allowed to change them, which is the usual arrangement.

  # An editor cannot offer sockets it does not know about, and nothing exposed
  # the kind registry over the wire until this. `program.kind` is the kind of
  # the statement currently EXECUTING, which is a different question.
  defp program_kinds do
    %Method{
      id: "program.kinds",
      name: "StatementKinds",
      description:
        "Every statement kind this build knows, with its sockets. This is what " <>
          "a block editor is built from: a socket that declares `:point` can " <>
          "offer the taught points and refuse everything else, one that " <>
          "declares `:velocity` can offer units.\n\n" <>
          "It is a method rather than a static document because the registry is " <>
          "populated by compiled extensions — a controller with an extension " <>
          "loaded knows kinds this one does not, and an editor that hardcoded " <>
          "the list would silently refuse them.",
      async: false,
      call_grant: :read_state,
      output_args: [
        %ResultField{
          name: "kinds",
          type: {:array, {:ref, "type.statement_kind"}},
          description: "Every kind, with its sockets"
        }
      ]
    }
  end

  # Separate from `program.append` on purpose, and the split is the one the
  # error channel forces: `ExProto.Source`'s vocabulary is a fixed set of
  # atoms, so a refusal cannot carry which socket was wrong. An editor told
  # only "rejected" cannot put the cursor anywhere.
  #
  # So asking is a QUERY that succeeds and describes, and doing is a COMMAND
  # that succeeds or is refused. Which is also how an editor really behaves:
  # validate as somebody types, commit when they stop.
  defp program_validate do
    %Method{
      id: "program.validate",
      name: "ValidateStatement",
      description:
        "Would this statement be accepted? Answers without storing anything, " <>
          "naming the socket that fails and why.\n\n" <>
          "`ok` false with an empty `socket` means the kind itself is unknown. " <>
          "A socket named with a reason means that argument: a missing " <>
          "required value, a value that is not a number, a point that does not " <>
          "exist, or a socket this kind does not declare.",
      async: false,
      call_grant: :read_state,
      input_args: [
        %Argument{name: "kind", type: :string, required: true, description: "The statement kind"},
        %Argument{
          name: "args",
          type: {:array, {:ref, "type.statement_arg"}},
          required: false,
          description: "The arguments to check"
        }
      ],
      output_args: [
        %ResultField{name: "ok", type: :boolean, description: "Whether it would be accepted"},
        %ResultField{name: "socket", type: :string, description: "Which argument failed, or empty"},
        %ResultField{name: "reason", type: :string, description: "Why, in words, or empty"}
      ]
    }
  end

  defp program_create do
    %Method{
      id: "program.create",
      name: "CreateProgram",
      description:
        "Creates an empty program. Names are unique, so this refuses rather " <>
          "than silently adopting an existing one — an editor that thinks it " <>
          "made a new program and is in fact appending to an old one is the " <>
          "worst version of this call.",
      async: false,
      call_grant: :edit_program,
      input_args: [
        %Argument{name: "name", type: :string, required: true, description: "The new program"}
      ]
    }
  end

  defp program_delete do
    %Method{
      id: "program.delete",
      name: "DeleteProgram",
      description:
        "Deletes a program and its statements. Refused while it is running. " <>
          "Points, frames and tools it referenced are untouched — the " <>
          "references were what protected THEM from deletion, not the other " <>
          "way round.",
      async: false,
      call_grant: :edit_program,
      input_args: [
        %Argument{name: "name", type: :string, required: true, description: "The program"}
      ]
    }
  end

  defp program_append do
    %Method{
      id: "program.append",
      name: "AppendStatement",
      description:
        "Adds a statement to the end of a program.\n\n" <>
          "Validated when it is stored, not when it is reached: an unknown " <>
          "kind, a missing required argument, a socket the kind does not " <>
          "declare, or a point that does not exist are all refused here, while " <>
          "somebody is editing, rather than at the moment the arm is already " <>
          "moving. That is the entire return on typed parameters.\n\n" <>
          "References travel as names — `point: \"weld_start\"` — because that " <>
          "is what a person taught. The controller stores a foreign key, which " <>
          "is what refuses the point's deletion later.",
      async: false,
      call_grant: :edit_program,
      input_args: [
        %Argument{name: "program", type: :string, required: true, description: "The program"},
        %Argument{
          name: "kind",
          type: :string,
          required: true,
          description: "A statement kind this build knows; see `program.kinds`"
        },
        %Argument{
          name: "args",
          type: {:array, {:ref, "type.statement_arg"}},
          required: false,
          description: "Its arguments, by socket name"
        }
      ],
      output_args: [
        %ResultField{name: "seq", type: :int32, description: "Where it landed, from zero"}
      ]
    }
  end

  defp program_replace do
    %Method{
      id: "program.replace",
      name: "ReplaceStatement",
      description:
        "Replaces the statement at `seq`, keeping its place. The new kind and " <>
          "arguments are validated exactly as an append's are; the old " <>
          "statement's references are discarded and the new ones resolved.",
      async: false,
      call_grant: :edit_program,
      input_args: [
        %Argument{name: "program", type: :string, required: true, description: "The program"},
        %Argument{name: "seq", type: :int32, required: true, description: "Which statement"},
        %Argument{name: "kind", type: :string, required: true, description: "The new kind"},
        %Argument{
          name: "args",
          type: {:array, {:ref, "type.statement_arg"}},
          required: false,
          description: "Its arguments, by socket name"
        }
      ]
    }
  end

  defp program_remove do
    %Method{
      id: "program.remove",
      name: "RemoveStatement",
      description:
        "Removes the statement at `seq`. Everything below it slides up, so " <>
          "sequence numbers stay contiguous and an editor never has to render " <>
          "a hole.",
      async: false,
      call_grant: :edit_program,
      input_args: [
        %Argument{name: "program", type: :string, required: true, description: "The program"},
        %Argument{name: "seq", type: :int32, required: true, description: "Which statement"}
      ]
    }
  end

  defp program_move do
    %Method{
      id: "program.move",
      name: "MoveStatement",
      description:
        "Moves the statement at `seq` to position `to`, sliding the rest " <>
          "along. Reordering is an edit like any other and is refused while " <>
          "the program is running.",
      async: false,
      call_grant: :edit_program,
      input_args: [
        %Argument{name: "program", type: :string, required: true, description: "The program"},
        %Argument{name: "seq", type: :int32, required: true, description: "Which statement"},
        %Argument{name: "to", type: :int32, required: true, description: "Its new place"}
      ]
    }
  end

  defp program_start do
    %Method{
      id: "program.start",
      name: "Start",
      description:
        "Runs a stored program from its first statement. Refused outside auto, " <>
          "refused while another program is running, and refused if the program " <>
          "uses a statement kind this build does not know — that last one " <>
          "meaning an unloaded extension makes a program fail to start rather " <>
          "than fail halfway down it.\n\nReturns as soon as the run is " <>
          "accepted. Watch `program.state`.",
      async: true,
      call_grant: :execute_program,
      input_args: [
        %Argument{name: "name", type: :string, required: true, description: "The program to run"}
      ]
    }
  end

  defp program_hold do
    %Method{
      id: "program.hold",
      name: "Hold",
      description:
        "Stops the arm where it is and keeps the run. The interpreter rewinds " <>
          "to the oldest statement whose motion had not finished, because that " <>
          "is where the arm actually is.",
      async: false,
      call_grant: :execute_program
    }
  end

  defp program_resume do
    %Method{
      id: "program.resume",
      name: "Resume",
      description:
        "Re-issues the held statement from wherever the arm is standing. For a " <>
          "straight move that is exactly the remainder of the original line. " <>
          "Refused during an arc, whose via point may be behind the arm — a " <>
          "circle recomputed through a via already passed is a different path, " <>
          "and drawing it quietly would be worse than refusing.",
      async: false,
      call_grant: :execute_program
    }
  end

  defp program_step do
    %Method{
      id: "program.step",
      name: "Step",
      description: "Runs exactly one statement and holds again.",
      async: false,
      call_grant: :execute_program
    }
  end

  defp program_stop do
    %Method{
      id: "program.stop",
      name: "Stop",
      description:
        "Abandons the run and stops the arm. There is no resume from a stop; " <>
          "the next run starts at the top.",
      async: false,
      call_grant: :execute_program
    }
  end

  defp program_list do
    %Method{
      id: "program.list",
      name: "ListPrograms",
      description: "Every stored program, with how many statements it has.",
      async: false,
      call_grant: :read_state,
      output_args: [
        %ResultField{
          name: "programs",
          type: {:array, {:ref, "type.stored_program"}},
          description: "Stored programs, by name"
        }
      ]
    }
  end

  defp program_show do
    %Method{
      id: "program.show",
      name: "ShowProgram",
      description:
        "A program's body: every statement, in order, with its kind, its " <>
          "literal arguments and what it references. This is the readable " <>
          "rendering — the canonical transfer of a large body is HTTP, per " <>
          "PROGRAMS.md §4.",
      async: false,
      call_grant: :read_state,
      input_args: [
        %Argument{name: "name", type: :string, required: true, description: "The program to show"}
      ],
      output_args: [
        %ResultField{
          name: "statements",
          type: {:array, {:ref, "type.statement"}},
          description: "The body, in order"
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
        %Property{
          id: "cell.referenced",
          name: "Referenced",
          description:
            "True when every joint of the loaded arm knows where it is. The " <>
              "precondition for anything that builds a pose: Cartesian " <>
              "motion, teaching a point, running a program. Deliberately NOT " <>
              "a precondition for joint jog — an unreferenced axis still has " <>
              "an accumulator, and driving it to the witness mark is exactly " <>
              "how it is recovered. Read `cell.mastering` for which joint.",
          type: :boolean,
          read_grant: :read_state
        },
        mastering(),
        master_axis(),
        restore_mastering(),
        installation(),
        commission(),
        teach_point(),
        define_point(),
        forget_point(),
        list_points(),
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

  # Teaching is a capture, not an argument list. The client says what to call
  # the place the arm is standing; the controller reads where that is. A method
  # that took a pose would be a different thing entirely — offline programming
  # — and would have no joint solution behind it, which is the part that makes
  # a point replayable without flipping.
  defp teach_point do
    %Method{
      id: "cell.teach_point",
      name: "TeachPoint",
      description:
        "Records where the arm is now, under a name. The pose is stored in " <>
          "the frame given, so re-teaching that frame moves this point with " <>
          "it; the tool that is fitted is recorded alongside, because a pose " <>
          "taught with one tool does not describe the same physical location " <>
          "with another; and the joint solution the arm is actually in is " <>
          "stored too, which is what lets a replay reach the pose on the " <>
          "configuration it was taught on rather than the mirror of it.\n\n" <>
          "Re-teaching an existing name moves the point. A position that was " <>
          "taught slightly wrong and taught again is the same position.",
      async: false,
      call_grant: :write_setpoint,
      input_args: [
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "Lowercase, starting with a letter"
        },
        %Argument{
          name: "frame",
          type: :string,
          required: false,
          default: "base",
          description:
            "The frame to express the pose in. Teach in the frame the work is " <>
              "in, and re-teaching that frame after the fixture moves brings " <>
              "every point taught in it along."
        },
        %Argument{
          name: "mutable",
          type: :boolean,
          required: false,
          default: false,
          description:
            "Whether a running program may write this point. A vision result " <>
              "writes a mutable point; a taught approach position is not " <>
              "writable by a program at all."
        }
      ],
      output_args: [
        %ResultField{name: "name", type: :string, description: "The point that was taught"},
        %ResultField{
          name: "frame",
          type: :string,
          description: "The frame it was expressed in"
        },
        %ResultField{
          name: "tool",
          type: :string,
          description: "The tool that was fitted, or empty for a bare flange"
        }
      ]
    }
  end

  defp forget_point do
    %Method{
      id: "cell.forget_point",
      name: "ForgetPoint",
      description: "Deletes a taught point.",
      async: false,
      call_grant: :write_setpoint,
      input_args: [
        %Argument{name: "name", type: :string, required: true, description: "The point to delete"}
      ]
    }
  end

  defp list_points do
    %Method{
      id: "cell.list_points",
      name: "ListPoints",
      description:
        "Every taught point, with the frame and tool it was taught with and " <>
          "the joint solution behind it. Poses are as stored — in their own " <>
          "frame — because that is the number a person taught and the one " <>
          "that stays true when the fixture moves.",
      async: false,
      call_grant: :read_state,
      output_args: [
        %ResultField{
          name: "points",
          type: {:array, {:ref, "type.stored_point"}},
          description: "Taught points, by name"
        }
      ]
    }
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

  defp restore_mastering do
    %Method{
      id: "cell.restore_mastering",
      name: "RestoreMastering",
      description:
        "Gives one axis an offset that came off the board being replaced.\n\n" <>
          "This is not `master_axis` and the difference is the point of the " <>
          "method existing. Mastering says \"the arm is at this angle, work " <>
          "out your offset\". This says \"your offset is this number\", which " <>
          "is only ever true when the number came from the hardware being " <>
          "swapped out.\n\n" <>
          "**Refused unless the axis is currently unmastered.** A board that " <>
          "already knows its zero is exactly the case where writing one is " <>
          "wrong, so the refusal makes the failure impossible rather than " <>
          "discouraged. `MASTERING.md`: a controller that pushed a stored " <>
          "offset back \"would eventually push a stale one, and the failure is " <>
          "silent — every joint would still report a plausible angle, every " <>
          "move would still execute cleanly, and the work would land somewhere " <>
          "other than where it was taught. Nothing faults. You find out at the " <>
          "workpiece.\"\n\n" <>
          "Behind `restore`, which is a maintainer grant, and per axis rather " <>
          "than per installation: restoring an installation must never carry " <>
          "mastering with it, and the way to guarantee that is for there to be " <>
          "no call that does several at once.",
      async: false,
      call_grant: :restore,
      input_args: [
        %Argument{name: "axis", type: :string, required: true, description: "Which joint"},
        %Argument{
          name: "offset",
          type: :double,
          required: true,
          description: "The offset the replaced board reported, radians"
        }
      ],
      output_args: [
        %ResultField{name: "offset", type: :double, description: "What the drive now holds"}
      ]
    }
  end

  defp define_point do
    %Method{
      id: "cell.define_point",
      name: "DefinePoint",
      description:
        "Records a point that arrived from somewhere else — a program file " <>
          "pushed from a studio, or a backup — rather than from where the arm " <>
          "is standing.\n\n" <>
          "This is the counterpart to `teach_point` and the difference is the " <>
          "whole reason it is a separate method. Teaching means the arm was " <>
          "here and somebody said so. This means a file said so. The stored " <>
          "point records which, so a pendant can later show that a program " <>
          "moves to places this arm has never been to.\n\n" <>
          "**The joint solution is required.** It is not solved here and not " <>
          "defaulted. `move_joint` commands the six angles that were recorded " <>
          "rather than solving anything, so a point whose angles came from a " <>
          "solver would have a branch nobody chose, replayed as though " <>
          "somebody had — which is the configuration flip the taught joint " <>
          "vector exists to remove. A pose pushed from a controller carries " <>
          "the vector that was measured there; a pose computed from geometry " <>
          "does not, and planning one is a different feature.\n\n" <>
          "Behind `load_program`, because installing a program's points is " <>
          "part of loading the program. Re-defining an existing name moves it, " <>
          "the same way re-teaching does.",
      async: false,
      call_grant: :load_program,
      input_args:
        [
          %Argument{name: "name", type: :string, required: true, description: "What to call it"}
        ] ++
          pose_arguments("the point") ++
          [
            %Argument{
              name: "joints",
              type: {:array, :double},
              required: true,
              description:
                "The joint solution this pose was measured in, base to tip. " <>
                  "Required: see above on why it is not solved for."
            },
            %Argument{
              name: "frame",
              type: :string,
              required: false,
              description: "The frame the pose is expressed in. Refused if absent from the cell."
            },
            %Argument{
              name: "tool",
              type: :string,
              required: false,
              description: "The tool it was measured with. Refused if absent from the cell."
            }
          ],
      output_args: [
        %ResultField{name: "name", type: :string, description: "The point that was defined"},
        %ResultField{name: "created", type: :boolean, description: "Whether it is new"}
      ]
    }
  end

  defp commission do
    %Method{
      id: "cell.commission",
      name: "Commission",
      description:
        "Records what commissioning says about one joint: which drive drives " <>
          "it, its velocity and acceleration ceilings, its soft limits, and " <>
          "where home is. Replaces what it said before.\n\n" <>
          "Refused when the joint is not one the robot has, and when a soft " <>
          "limit falls outside the mechanical travel the robot description " <>
          "declares — a soft limit wider than the metal is not a limit.\n\n" <>
          "This is how an installation is restored, one joint at a time. " <>
          "Frames and tools already had a way in, because `teach_frame` and " <>
          "`teach_tool` take six numbers rather than a pose the arm is " <>
          "standing in; a joint's ceilings had none. Note what is still " <>
          "absent and `INSTALLATION.md` says why: nothing here re-commissions " <>
          "the robot description itself, and nothing writes a mastering " <>
          "offset.",
      async: false,
      call_grant: :write_configuration,
      input_args: [
        %Argument{name: "joint", type: :string, required: true, description: "The URDF's name for it"},
        %Argument{name: "axis", type: :string, required: false, description: "Which drive drives it"},
        %Argument{name: "max_vel", type: :double, required: false, description: "Ceiling, rad/s"},
        %Argument{name: "max_acc", type: :double, required: false, description: "Ceiling, rad/s²"},
        %Argument{name: "soft_lower", type: :double, required: false, description: "Soft limit, rad"},
        %Argument{name: "soft_upper", type: :double, required: false, description: "Soft limit, rad"},
        %Argument{name: "home", type: :double, required: false, description: "Where home is, rad"}
      ],
      output_args: [
        %ResultField{name: "joint", type: :string, description: "The joint that was commissioned"}
      ]
    }
  end

  defp installation do
    %Method{
      id: "cell.installation",
      name: "Installation",
      description:
        "Everything about this machine that is not a program, in one " <>
          "consistent read: the robot it was commissioned with, what " <>
          "commissioning said about each joint, the frames and tools of the " <>
          "cell, and what every drive says about its own zero.\n\n" <>
          "One call rather than five on purpose. An installation is a " <>
          "snapshot, and five round trips can straddle a change — a frame " <>
          "taught between the third call and the fourth produces a backup of " <>
          "a machine that never existed, and a fingerprint over it means " <>
          "nothing.\n\n" <>
          "Behind `backup` rather than `read_state`, because taking a " <>
          "machine's configuration off it is a maintenance act. The three " <>
          "kinds of thing in here are not equivalent and `INSTALLATION.md` " <>
          "says which is which: the cell and the robot model are portable, " <>
          "and `mastering` belongs to this unit and must never be restored " <>
          "onto another arm.",
      async: false,
      call_grant: :backup,
      output_args: [
        %ResultField{
          name: "robot",
          type: {:ref, "type.installation_robot"},
          description: "The description this controller was commissioned with"
        },
        %ResultField{
          name: "joints",
          type: {:array, {:ref, "type.joint_setting"}},
          description: "Commissioning, in the chain's own order, base to tip"
        },
        %ResultField{
          name: "frames",
          type: {:array, {:ref, "type.stored_frame"}},
          description: "The cell's named places"
        },
        %ResultField{
          name: "tools",
          type: {:array, {:ref, "type.stored_tool"}},
          description: "The cell's end-of-arm tools"
        },
        %ResultField{
          name: "mastering",
          type: {:array, {:ref, "type.axis_mastering"}},
          description:
            "What each drive says about its zero. Backed up so it can be " <>
              "compared and so a board swap can be told what the old one " <>
              "knew — never restored as part of restoring an installation."
        }
      ]
    }
  end

  defp mastering do
    %Method{
      id: "cell.mastering",
      name: "Mastering",
      description:
        "What every joint says about its own zero, in chain order. Read this " <>
          "after a power cycle and before trusting a taught point.",
      async: false,
      call_grant: :read_state,
      output_args: [
        %ResultField{
          name: "axes",
          type: {:array, {:ref, "type.axis_mastering"}},
          description: "One entry per joint, base to tip"
        }
      ]
    }
  end

  defp master_axis do
    %Method{
      id: "cell.master_axis",
      name: "MasterAxis",
      description:
        "Declares that this joint is RIGHT NOW at `at` radians, and records " <>
          "it. This is the recovery for an unreferenced or unmastered axis: " <>
          "jog it to the witness mark, then say where that is.\n\n" <>
          "The drive keeps the number, not the controller. On real hardware " <>
          "the encoder is on the driver board, so the offset is a property of " <>
          "that board bolted to that motor bolted into that joint — a board " <>
          "swap legitimately invalidates it, and a controller that pushed a " <>
          "stored offset back at boot would silently relocate every taught " <>
          "point in the cell with nothing faulting. The controller writes a " <>
          "dated shadow row so the change has a predecessor, and that is all.\n\n" <>
          "Refused while the drive's output stage is on: on real hardware a " <>
          "flash write stalls the current loop, and a moving axis records a " <>
          "position that is already stale.\n\n" <>
          "Guarded by `calibrate`, which is the grant that exists for exactly " <>
          "this — writing joint offsets is not something an operator does " <>
          "with a pendant in their hand.",
      async: false,
      call_grant: :calibrate,
      input_args: [
        %Argument{
          name: "axis",
          type: :string,
          required: true,
          description: "The drive to master"
        },
        %Argument{
          name: "at",
          type: :double,
          required: false,
          description:
            "The joint angle this position is being declared to be. Defaults " <>
              "to zero. A witness mark deliberately outside the working range " <>
              "is supported — that is what this argument is for."
        }
      ],
      output_args: [
        %ResultField{
          name: "offset",
          type: :double,
          description: "The accumulator value now recorded as joint zero, radians"
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
