# ROS 2 Integration

**Status:** design. Nothing in this document is implemented.
**Scope:** how E-Motion presents itself to a ROS 2 graph, as a `controller_manager`.

The wire primitives this depends on — CDR, code generation, QoS, discovery,
service and action machinery — belong to `ros2_ex`, a standalone library that
knows nothing about E-Motion. See [ROS2_EX.md](ROS2_EX.md). This document is about
what E-Motion does with them.

---

## The position

E-Motion is a `controller_manager`.

Not a hardware component underneath someone else's `controller_manager` — the
thing itself. When a ROS 2 system asks the graph "who is managing the controllers
on this robot," E-Motion answers, and it answers with the same eleven services and
the same message types that `ros-controls/ros2_control` answers with. From the
outside there is a `/controller_manager` node with an `update_rate`, controllers
in known lifecycle states, claimed command and state interfaces, and a
`joint_trajectory_controller` you can send a `FollowJointTrajectory` goal to.
MoveIt does not care what language any of that is written in. Neither does rviz,
`ros2 control list_controllers`, or the twelve-line Python script somebody on the
integration team wrote.

This is a choice about *which* seam to be compatible with, and the two seams in
ros2_control lead to opposite places:

- The **plugin seam** (`hardware_interface::SystemInterface`) is a C++ ABI,
  loaded by pluginlib into the `controller_manager` process, `read()` and
  `write()` called synchronously from its update loop. Compatibility here means
  E-Motion is a shared library that C++ calls into. That is not a thing the BEAM
  does, and it would put `controller_manager` in charge of the machine.
- The **wire seam** — topics, services, actions — is a set of names and CDR byte
  layouts. Compatibility here means E-Motion is a peer on the graph. This is the seam
  every tool in the ecosystem actually talks to, because `ros2 control`, MoveIt,
  rviz, rqt, and `ros2 bag` are all clients of the wire, not of the plugin ABI.

We take the wire seam. E-Motion owns the machine and speaks ROS 2 as a northbound
protocol, the same way it already speaks OPC UA and JSON-RPC. This is not a
compromise of the standalone framework thesis — it is the third projection.

---

## Why the equivalence is real

It would be easy to read "E-Motion is a controller_manager" as marketing. It isn't,
and the reason is that `controller_manager` is mostly *not* a control algorithm.
Read what it actually does:

1. A **plugin registry** — pluginlib loads controller shared objects by class
   name from a parameter.
2. A **lifecycle state machine driver** — it walks each controller through
   unconfigured → inactive → active → finalized and refuses illegal transitions.
3. A **resource arbiter** — it hands out exclusive claims on command interfaces
   and refuses a controller that wants one someone else holds.
4. A **process supervisor with a fault policy** — `handle_exceptions`,
   `fallback_controllers`, `deactivate_controllers_on_hardware_self_deactivate`,
   `strictness`, overrun detection.
5. And then it calls `update()` on the active controllers at `update_rate`.

Items 1 through 4 are a hand-rolled, single-process, C++ reimplementation of
things OTP has shipped since 1998: a module registry, a `gen_statem`, a
`Registry` with monitored claims, and a supervision tree with a restart strategy.
`controller_manager` writes its own crash handling because a segfault in one
controller takes the whole process with it. E-Motion's equivalent gets it from the
runtime, and gets it *more* correct — a controller process that dies releases its
interface claims because the monitor fires, not because someone remembered to
write the cleanup path.

Item 5 is the one that deserves an honest answer, and E-Motion already has it.

### The real-time story

The BEAM is soft real-time. It is not going to hold a 1 kHz current loop with
bounded jitter, and nobody should claim otherwise.

It does not have to, because that is not where E-Motion's cyclic loop lives.
`Metronome` is the host side of a USB link to the ULX3S ECP5, and the FPGA holds
the trajectory look-ahead buffer, interpolates each servo cycle, and runs the
CANopen cyclic engine — SYNC plus RPDO/TPDO — entirely on its own clock. The host
streams setpoint and motion windows down and reads feedback windows up. The
determinism lives in gateware; the BEAM does trajectory-rate planning,
supervision, and buffer management.

This is precisely the split a serious ros2_control deployment already uses. A
`controller_manager` driving EtherCAT servos in CSP mode is not closing the
current loop either — the drive is, at 16 kHz, and the "real-time" loop is
feeding it setpoints over a fieldbus with its own distributed clock. E-Motion has the
same architecture with the buffer one hop further out. The claims we make on the
wire are therefore honest and checkable:

- `update_rate` reports the **FPGA's cyclic rate**, because that is the rate at
  which setpoints reach the drives. It is not a BEAM timer.
- Overrun and periodicity diagnostics report **metronome buffer fill and
  underrun**, not BEAM scheduler jitter. A buffer that never runs dry is the
  actual invariant; scheduler latency matters only insofar as it threatens it.
- We do not publish a periodicity statistic we cannot defend. If the honest
  number is "the host refills a 20 ms window every 5 ms and has never been later
  than 1.2 ms," that is what diagnostics say.

### The mapping

| ros2_control | E-Motion |
|---|---|
| `controller_manager` node | `EMotion.ROS2.ControllerManager` over the existing supervision tree |
| `update_rate` loop | FPGA cyclic engine; `Metronome` is the host side |
| `hardware_interface::SystemInterface` | `Exdrive.Transport` (CAN FD / USB metronome / simulator) |
| hardware component lifecycle | `Exdrive.Drive` `gen_statem` — the CiA 402 PDS FSA |
| `resource_manager` interface claims | `Registry` with monitored, auto-releasing claims |
| controller plugin (pluginlib class) | Elixir module under a controllers `DynamicSupervisor` |
| controller lifecycle | `gen_statem` per controller, driven by the CM services |
| `joint_state_broadcaster` | `EMotion.ROS2.Broadcaster.JointState` over `ExMove.Robot.state/1` |
| `joint_trajectory_controller` | `ExMove.PathExecutor` + `ExMove.Lookahead` behind an action server |
| URDF ingestion | `ExMove.URDF` → `ExMove.Chain`; `EMotion.Cell.chain/0` adds the fitted tool |
| `robot_description` topic | published from `EMotion.Schema.Registry.arm_chain/0`'s source URDF |
| `realtime_tools` lock-free buffers | BEAM message passing; conflating publisher per `ExProto.Publisher` |
| `fallback_controllers`, `handle_exceptions` | supervisor restart strategy |
| `ros2 param` | `rcl_interfaces` services over the Information Model |

The pleasing part is how little of this is new code. `Exdrive.Drive` is already a
lifecycle state machine with modes of operation and fault states.
`ExMove.PathExecutor` already consumes a stream of waypoints against a deadline
scheduler with an injected push function. `ExProto.Publisher` already solves
conflating subscription delivery, which is exactly what a `/joint_states`
broadcaster is — read at send time, no queue, a slow consumer sees fewer samples
rather than older ones.

What is missing is not the controller. It is the wire, and the wire is
`ros2_ex`'s job.

---

## `emotion_ros2`

A new umbrella app. Depends on `ros2_ex`; never the reverse.

```
apps/emotion_ros2/
  lib/emotion/ros2/
    control_surface/        # fixed ros2_control contract
      controller_manager.ex # the eleven services
      interfaces.ex         # <joint>/<interface> naming, claims
      broadcaster/
        joint_state.ex
      controller/
        joint_trajectory.ex # the FollowJointTrajectory action server
    projection.ex           # generated from the Information Model
    msgs/                   # output of `mix ros2.gen`, committed
```

### The invariant

**`ros2_ex` compiles and its full test suite passes with zero E-Motion apps
present.** If that ever stops being true, the split is decorative and the library
has quietly become an E-Motion component with delusions.

Two corollaries that are easy to get wrong:

- `controller_manager_msgs` and `control_msgs` are generated *here*, into
  `emotion_ros2/lib/emotion/ros2/msgs/`, and committed. They are not shipped by
  `ros2_ex`. ros2_control's message packages are E-Motion's business, not the
  library's.
- Nothing in `ros2_ex` may name a controller, an interface, or a lifecycle state
  from ros2_control's vocabulary. If a `ros2_ex` module needs to know what
  `switch_controller` means, the abstraction has leaked.

The test is mechanical and should be in CI: build `ros2_ex` in isolation.

---

## What we expose

The MVP surface is defined by one acceptance test: **`ros2 control
list_controllers`, `ros2 control list_hardware_interfaces`, `ros2 topic echo
/joint_states`, and a MoveIt `FollowJointTrajectory` goal all work against E-Motion
with no shim, no bridge, and no ROS 2 installation on the target.**

Names and types below are verified against `ros-controls/ros2_control` and
`ros-controls/ros2_controllers` on `master`.

### `/controller_manager`

Eleven services, all `~/`-relative:

| Service | Type |
|---|---|
| `list_controllers` | `controller_manager_msgs/srv/ListControllers` |
| `list_controller_types` | `controller_manager_msgs/srv/ListControllerTypes` |
| `load_controller` | `controller_manager_msgs/srv/LoadController` |
| `configure_controller` | `controller_manager_msgs/srv/ConfigureController` |
| `cleanup_controller` | `controller_manager_msgs/srv/CleanupController` |
| `unload_controller` | `controller_manager_msgs/srv/UnloadController` |
| `switch_controller` | `controller_manager_msgs/srv/SwitchController` |
| `reload_controller_libraries` | `controller_manager_msgs/srv/ReloadControllerLibraries` |
| `list_hardware_components` | `controller_manager_msgs/srv/ListHardwareComponents` |
| `list_hardware_interfaces` | `controller_manager_msgs/srv/ListHardwareInterfaces` |
| `set_hardware_component_state` | `controller_manager_msgs/srv/SetHardwareComponentState` |

Plus `~/activity` (`ControllerManagerActivity`, KeepLast(1), reliable +
transient_local, published on every controller or hardware state change) and a
`robot_description` subscription (`std_msgs/msg/String`, transient_local). We
also *publish* the URDF, since E-Motion owns it.

`reload_controller_libraries` has no meaning for us. It should return
`ok: false` with a message saying so, rather than pretending. `load_controller`
maps to "start a supervised controller process from a module name in a registry"
— the pluginlib analogue is `Code.ensure_loaded?/1` against a whitelist, and the
whitelist is not optional.

### Interface naming

`list_hardware_interfaces` is the service that makes E-Motion legible, and it wants
ros2_control's `<joint>/<interface>` convention, not E-Motion's internal axis ids:

```
command_interfaces: joint_1/position, joint_1/velocity, ...
state_interfaces:   joint_1/position, joint_1/velocity, joint_1/effort, ...
```

Joint names must be the URDF joint names, exactly. This is the cheapest thing to
get right and the most annoying to get wrong, because every downstream tool keys
on it.

`Exdrive.Drive` is SI throughout — radians, rad/s, rad/s², N·m — which is already
REP-103 compliant, so interface values pass through unconverted. That is not
luck; it is why the units decision was made.

### Controllers

**`joint_state_broadcaster`** — publishes `/joint_states`
(`sensor_msgs/msg/JointState`), RELIABLE, claims state interfaces only, reads
through `ExMove.Robot.state/1`.

**`joint_trajectory_controller`**:

| Kind | Name | Type |
|---|---|---|
| Action server | `~/follow_joint_trajectory` | `control_msgs/action/FollowJointTrajectory` |
| Subscriber | `~/joint_trajectory` | `trajectory_msgs/msg/JointTrajectory` |
| Publisher | `~/controller_state` | `control_msgs/msg/JointTrajectoryControllerState` |
| Service | `~/query_state` | `control_msgs/srv/QueryTrajectoryState` |

The action maps onto `EMotion.Behavior` almost exactly — a long-running,
cancellable, observable operation with typed inputs, typed outputs, live runtime
fields, and named faults. `FollowJointTrajectory`'s goal is the input args, its
feedback is the runtime fields, and its result `error_code` is the fault taxonomy
(`PATH_TOLERANCE_VIOLATED`, `GOAL_TOLERANCE_VIOLATED`, `INVALID_JOINTS`, …).

A ROS action *is* an E-Motion behavior with a different serialization. That
correspondence should be load-bearing in the implementation, not a comment —
`ros2_ex`'s `handle_goal` / `handle_cancel` / `handle_execute` callbacks exist
precisely so an `EMotion.Behavior` can be adapted onto them in a few lines.

Execution is `ExMove.PathExecutor` fed from the goal's `JointTrajectoryPoint`
list with `ExMove.Lookahead` for blending. Tolerance checking is new work and
belongs to the controller, not the executor.

Note that `MultiDOFJointTrajectory` fields must exist in the generated structs
and encode as empty sequences even though we do not execute them — CDR is
positional, so a field you skip is not a field you omit. Accept the goal and
reject it with `INVALID_GOAL`.

### A correction worth writing down

**ros2_control controllers do not expose lifecycle services on the wire.**
`ControllerInterfaceBase::init()` constructs the `LifecycleNode` with the
communication interface explicitly disabled, so there is no `~/change_state`, no
`~/get_state`, no `~/transition_event` on a controller node. Lifecycle is driven
*only* through the `controller_manager` services.

This is the most commonly-wrong claim in design documents on this subject and we
should not repeat it. It also makes the job smaller: controllers need parameter
services and their own topics, and nothing else.

Controllers *do* still expose all six `rcl_interfaces` parameter services under
their own node name, because the ordinary node machinery is intact.

---

## `EMotion.Projection.ROS2`

The Information Model already projects to OPC UA and JSON-RPC, with `Walker`,
`NodeSpec`, and `TypeMap` as the established shape. ROS 2 is the third
projection, with one honest caveat: **the mapping is lossier than the other two**,
because ROS 2 has no generic address space. There is no Browse. There is a flat
namespace of typed topics, services, and actions, and the types are fixed IDL,
not runtime-described.

| Schema | ROS 2 |
|---|---|
| `Object` | node namespace segment |
| `Property` (observable) | topic; a node parameter when it is configuration rather than telemetry |
| `Method` (sync) | service |
| `Method` (async, `EMotion.Behavior`) | **action** |
| `Event` | topic |
| `Enum` | integer constants on a generated message |
| `StructType` | generated `.msg` under an `exmo_msgs` package |
| axis `Property` set | the `<joint>/<interface>` command and state interface names |

The projection has two halves and they must stay separate modules:

- **`EMotion.ROS2.ControlSurface`** — fixed. Its types are defined by ros2_control
  and we do not get to invent them. Not generated from the IM.
- **`EMotion.Projection.ROS2`** — generated. Everything E-Motion-specific beyond the
  control surface: behaviors that are not trajectory execution, cell state, tool
  management, fault taxonomy. This is where the projection earns its keep.

Conflating them will make the generated half distort itself to fit the fixed
half, and the distortion will be permanent.

### Authorization

The ROS 2 graph is unauthenticated. ExAuth's principals, roles, and grants have
no wire representation on the ROS 2 side.

Proposal: the ROS 2 endpoint runs as a single configured ExAuth principal with an
explicit role, so ROS clients collectively inherit one grant set and the endpoint
can be denied write access entirely in a deployment that wants ROS 2 as a
telemetry consumer only. SROS2 is the eventual answer and is out of scope for
both this document and `ros2_ex` v0.1.

An unauthenticated ROS 2 endpoint on a machine that can move is a decision. It
should be made in a config file with a comment, not by default.

---

## Traps

The generic wire traps — QoS compatibility, latching, CDR alignment, `rt`/`rq`/
`rr` naming — live in [ROS2_EX.md](ROS2_EX.md), because they are the library's
problem to solve once. Three are E-Motion's.

**Joint naming and frames.** REP-103 and REP-105: right-handed, x-forward, SI
units, frame names `map` / `odom` / `base_link`, joint names matching the URDF
exactly. `Exdrive` is already SI in radians so most of this is free. Getting the
names right is most of what makes MoveIt and rviz work on the first attempt, and
it costs nothing to do at the start.

**What `update_rate` means.** Covered above, but worth restating as a trap: the
temptation is to report a BEAM timer's frequency because it is easy to measure.
Report the FPGA's rate and publish buffer-fill diagnostics. A ROS 2 integrator
reading `update_rate: 1000` is entitled to assume setpoints reach the drives at
1 kHz, and with the metronome architecture that assumption is true.

**Distro deltas.** Pick a target and say so in the README. The ones that bite:
`CleanupController` does not exist on Humble. Humble's `SwitchController` carries
deprecated `start_controllers` / `stop_controllers` / `start_asap`, its response
has no `message` field, and it lacks `AUTO` / `FORCE_AUTO` strictness.
`~/activity` is Jazzy+. Humble's JTC publishes a deprecated `~/state` alongside
`~/controller_state`. `/dynamic_joint_states` is gone on `master`. Recommend
targeting **Jazzy and Kilted**, with Humble a documented non-goal — note that on
Humble the `Gid` in `ros_discovery_info` is 24 bytes rather than 16, so Humble
support is a wire-format conditional in `ros2_ex`, not a flag.

**Type hashes read as zero.** `ros2_ex` v0.1 cannot publish endpoint USER_DATA,
so `ros2 topic info -v` against E-Motion shows `RIHS01_000…0` rather than a real type
hash. It is cosmetic on DDS — USER_DATA does not participate in endpoint matching
— but an integrator *will* notice it and ask. The reason and the fix are in
[ROS2_EX.md](ROS2_EX.md); the answer to give is "not yet, it doesn't affect
interop, and it's an upstream patch away."

---

## Milestones

Keyed to `ros2_ex` versions; E-Motion work cannot start ahead of the library
milestone it depends on.

**E0 — messages.** `mix ros2.gen` over `sensor_msgs`, `trajectory_msgs`,
`control_msgs`, `controller_manager_msgs`, `lifecycle_msgs`, `action_msgs`.
Committed into `emotion_ros2`. Requires ros2_ex M0.

**E1 — joint states.** `EMotion.ROS2.Broadcaster.JointState` over
`ExMove.Robot.state/1`, plus `robot_description` publication. Success is
`ros2 topic echo /joint_states` from another machine and a correctly-framed robot
in rviz. Requires ros2_ex M1 for the topic, M2 before anyone can debug it —
until `ros2 node list` shows the node, every failure here is invisible.

**E2 — the control surface.** The eleven `/controller_manager` services and the
interface claim registry. Success is `ros2 control list_controllers` and
`ros2 control list_hardware_interfaces` printing a correct picture of a live
E-Motion cell. Requires ros2_ex M3.

**E3 — trajectory execution.** `FollowJointTrajectory` on `ExMove.PathExecutor`,
with cancellation, feedback, and tolerance checking. Success is a MoveIt-planned
trajectory executing on the cell. Requires ros2_ex M4.

**E4 — the generated projection.** `EMotion.Projection.ROS2`, `exmo_msgs`,
`/diagnostics` from the fault taxonomy, `/tf` from `ExMove.FK`. Success is an
E-Motion behavior invocable as a ROS 2 action without anyone hand-writing its
message definitions.

---

## Open questions

- Which distro do we commit to? Recommend Jazzy and Kilted. If a named
  integration partner is on Humble that changes the answer and the generated
  message definitions.
- Does the FPGA cyclic rate change at runtime? If it does, `update_rate` is not a
  static parameter and we need to decide what a reader of it is entitled to
  assume.
- Is `switch_controller` genuinely dynamic, or a fixed set of controllers that
  can be activated and deactivated but not loaded and unloaded at will? The
  second is much easier to make safe and is what most vendor drivers effectively
  do.
- Do we publish `exmo_msgs` to the ROS index? It is the difference between "a
  robot you can drive" and "a robot you can drive idiomatically," and it is a
  maintenance commitment on top of `ros2_ex`'s.

---

## References

- [ros2_control `controller_manager.cpp`](https://github.com/ros-controls/ros2_control/blob/master/controller_manager/src/controller_manager.cpp) — the authoritative service list
- [`controller_manager_msgs`](https://github.com/ros-controls/ros2_control/tree/master/controller_manager_msgs)
- [`controller_interface_base.cpp`](https://github.com/ros-controls/ros2_control/blob/master/controller_interface/src/controller_interface_base.cpp) — lifecycle comm interface disabled
- [`joint_trajectory_controller.cpp`](https://github.com/ros-controls/ros2_controllers/blob/master/joint_trajectory_controller/src/joint_trajectory_controller.cpp)
- [`joint_state_broadcaster.cpp`](https://github.com/ros-controls/ros2_controllers/blob/master/joint_state_broadcaster/src/joint_state_broadcaster.cpp)
- [`control_msgs`](https://github.com/ros-controls/control_msgs) — `FollowJointTrajectory.action`
- [REP-103](https://www.ros.org/reps/rep-0103.html) (units and coordinate conventions) · [REP-105](https://www.ros.org/reps/rep-0105.html) (frame names)
- [ROS2_EX.md](ROS2_EX.md) — the library this depends on
