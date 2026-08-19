# E-Motion Information Model — Machine Examples

This document shows what controller definitions and their projected Information Model address spaces look like for three representative machines. The point is to show that the same handful of primitives — `axis`, `behaviors`, and behavior definitions — scale cleanly from the simplest single-axis machine to a full 6-DOF arm with manipulator channels.

In every case the OPC UA address space, REST API, and WebSocket feed are derived automatically from the model. Nothing is defined twice.

---

## Example 1 — Mini lathe (leadscrew + spindle)

The simplest case: one linear axis and one rotary axis.

### Controller definition

```elixir
defmodule MiniLathe do
  use EMotion.Controller

  axis :z,       type: :linear, unit: :mm,  limits: {-300.0, 0.0}, home_pos: 0.0
  axis :spindle, type: :rotary, unit: :rpm,  limits: {0.0, 3000.0}

  behaviors [
    EMotion.Behaviors.MiniLathe.Home,
    EMotion.Behaviors.MiniLathe.SetSpindleSpeed,
    EMotion.Behaviors.MiniLathe.Threading
  ]
end
```

### Projected address space

```
E-Motion
├── Axes
│   ├── Z
│   │   ├── Position          (float, mm,  read-only,  observable)
│   │   ├── TargetPosition    (float, mm,  read/write)
│   │   ├── Velocity          (float, mm/s, read-only, observable)
│   │   ├── DriveState        (string, observable)
│   │   ├── FaultCode         (uint16)
│   │   └── AtHome            (boolean, observable)
│   └── Spindle
│       ├── Position          (float, RPM, read-only,  observable)
│       ├── TargetPosition    (float, RPM, read/write)
│       ├── Velocity          (float, RPM/s, read-only, observable)
│       ├── DriveState        (string, observable)
│       ├── FaultCode         (uint16)
│       └── Direction         (string: cw | ccw | stopped, read/write, observable)
├── Behaviors
│   ├── Catalog
│   │   ├── Home
│   │   │   ├── Supported, Description
│   │   │   └── Invoke
│   │   │       inputs:  axis_id (string), feed_rate (float)
│   │   │       outputs: accepted, job_id, result_code, message
│   │   ├── SetSpindleSpeed
│   │   │   ├── Supported, Description
│   │   │   └── Invoke
│   │   │       inputs:  rpm (float), direction (string)
│   │   │       outputs: accepted, result_code, message
│   │   └── Threading
│   │       ├── Supported, Description
│   │       └── Invoke
│   │           inputs:  standard (string), tpi (float), pitch_mm (float),
│   │                    start_z, end_z, clear_z, target_depth, pass_depth,
│   │                    spindle_rpm (float), direction (string), correlation_id
│   │           outputs: accepted, job_id, passes_cut, result_code, message
│   └── Runtime
│       └── ActiveBehavior
│           ├── Id, Name, JobId
│           ├── Phase, Progress
│           ├── CurrentPass, TotalPasses, DepthAchieved
│           ├── ZPosition, SpindleRpm, FeedRate, SyncLocked
│           └── FaultCode, FaultMessage
└── State
    ├── ControllerMode   (string: idle | manual | auto | fault)
    └── FaultPresent     (boolean)
```

**Axis properties generated automatically** from the two `axis` declarations. Threading runtime fields come from the `EMotion.Behaviors.MiniLathe.Threading` definition. Total nodes: ~45.

---

## Example 2 — 3-axis CNC mill (X/Y/Z + spindle)

Three linear axes, a spindle, and behaviors for homing, probing, and tool change.

### Controller definition

```elixir
defmodule CNCMill do
  use EMotion.Controller

  axis :x,       type: :linear, unit: :mm,  limits: {-500.0, 0.0}, home_pos: 0.0
  axis :y,       type: :linear, unit: :mm,  limits: {-400.0, 0.0}, home_pos: 0.0
  axis :z,       type: :linear, unit: :mm,  limits: {-200.0, 0.0}, home_pos: 0.0
  axis :spindle, type: :rotary, unit: :rpm,  limits: {0.0, 24000.0}

  behaviors [
    EMotion.Behaviors.CNCMill.HomeAll,
    EMotion.Behaviors.CNCMill.ProbeWorkpiece,
    EMotion.Behaviors.CNCMill.ToolChange
  ]
end
```

### Projected address space

```
E-Motion
├── Axes
│   ├── X  (Position, TargetPosition, Velocity, DriveState, FaultCode, AtHome)
│   ├── Y  (Position, TargetPosition, Velocity, DriveState, FaultCode, AtHome)
│   ├── Z  (Position, TargetPosition, Velocity, DriveState, FaultCode, AtHome)
│   └── Spindle
│       ├── Position, TargetPosition, Velocity, DriveState, FaultCode
│       ├── Direction         (string: cw | ccw | stopped)
│       └── Load              (float, %, observable — via :extra on axis declaration)
├── Behaviors
│   ├── Catalog
│   │   ├── HomeAll
│   │   │   └── Invoke
│   │   │       inputs:  sequence (string: xyz | zyx | custom), feed_rate (float)
│   │   │       outputs: accepted, job_id, result_code, message
│   │   ├── ProbeWorkpiece
│   │   │   └── Invoke
│   │   │       inputs:  probe_axis, direction, feed_rate,
│   │   │                expected_distance, correlation_id
│   │   │       outputs: accepted, job_id, contact_position (float),
│   │   │                result_code, message
│   │   └── ToolChange
│   │       └── Invoke
│   │           inputs:  tool_number (uint16), correlation_id
│   │           outputs: accepted, job_id, result_code, message
│   └── Runtime
│       └── ActiveBehavior
│           ├── Id, Name, JobId, Phase, Progress, RetryCount
│           ├── ActiveAxis        (string)
│           ├── ToolInSpindle     (uint16)
│           └── FaultCode, FaultMessage
├── WorkCoordinates
│   ├── G54  (X, Y, Z — float, read/write)
│   ├── G55  (X, Y, Z — float, read/write)
│   └── ActiveOffset  (string: G54 | G55 | …, read/write)
└── State
    ├── ControllerMode
    ├── FaultPresent
    ├── FeedOverride      (float, %, read/write)
    └── SpindleOverride   (float, %, read/write)
```

The `Load` property on the spindle uses the `:extra` escape hatch on the axis declaration:

```elixir
axis :spindle, type: :rotary, unit: :rpm, limits: {0.0, 24000.0},
  extra: [
    %EMotion.Schema.Property{
      id: "spindle.load", name: "Load", type: :float,
      readable: true, writable: false, observable: true,
      description: "Spindle load (%)"
    }
  ]
```

`WorkCoordinates` and the `State` overrides are contributed as a custom fragment directly in the registry. Total nodes: ~80.

---

## Example 3 — Arctos 6-DOF arm + manipulator channels

Six rotary joints, TCP pose observability, two manipulator channels, and motion behaviors.

### Controller definition

```elixir
defmodule ArctosSixDOF do
  use EMotion.Controller

  axis :j1, type: :rotary, unit: :degrees, limits: {-170.0, 170.0}, home_pos: 0.0
  axis :j2, type: :rotary, unit: :degrees, limits: {-90.0,  90.0},  home_pos: 0.0
  axis :j3, type: :rotary, unit: :degrees, limits: {-180.0, 180.0}, home_pos: 0.0
  axis :j4, type: :rotary, unit: :degrees, limits: {-170.0, 170.0}, home_pos: 0.0
  axis :j5, type: :rotary, unit: :degrees, limits: {-120.0, 120.0}, home_pos: 0.0
  axis :j6, type: :rotary, unit: :degrees, limits: {-170.0, 170.0}, home_pos: 0.0

  axis :vacuum,       type: :rotary, unit: :rpm, limits: {0.0, 1.0}
  axis :tool_changer, type: :rotary, unit: :degrees, limits: {0.0, 360.0}

  behaviors [
    EMotion.Behaviors.Arctos.HomeAll,
    EMotion.Behaviors.Arctos.MoveTCP,
    EMotion.Behaviors.Arctos.RunTrajectory,
    EMotion.Behaviors.Arctos.Pick
  ]
end
```

### Projected address space

```
E-Motion
├── Axes
│   ├── J1  (Position, TargetPosition, Velocity, DriveState, FaultCode, Direction)
│   ├── J2  (…)
│   ├── J3  (…)
│   ├── J4  (…)
│   ├── J5  (…)
│   ├── J6  (…)
│   ├── Vacuum
│   │   ├── Position, TargetPosition, Velocity, DriveState, FaultCode, Direction
│   │   ├── Pressure      (float, kPa, observable — via :extra)
│   │   └── GripDetected  (boolean, observable — via :extra)
│   └── ToolChanger
│       ├── Position, TargetPosition, Velocity, DriveState, FaultCode, Direction
│       └── Locked        (boolean, observable — via :extra)
├── TCP
│   ├── X, Y, Z           (float, mm, read-only, observable)
│   ├── Roll, Pitch, Yaw  (float, degrees, read-only, observable)
│   └── ReachLimit        (boolean, observable)
├── Behaviors
│   ├── Catalog
│   │   ├── HomeAll    → Invoke (sequence, feed_rate)
│   │   ├── MoveTCP    → Invoke (x, y, z, roll, pitch, yaw, feed_rate, blend_radius, correlation_id)
│   │   ├── RunTrajectory → Invoke (trajectory_id, feed_override, correlation_id)
│   │   └── Pick       → Invoke (x, y, z, approach_vector, manipulator_channel, correlation_id)
│   └── Runtime
│       └── ActiveBehavior
│           ├── Id, Name, JobId, Phase, Progress, RetryCount
│           ├── ActiveJoint, FramesCompleted
│           ├── ManipulatorReady
│           └── FaultCode, FaultMessage
└── State
    ├── ControllerMode
    ├── FaultPresent
    ├── KinematicsMode    (string: joint | cartesian | teaching, read/write)
    └── EStopActive       (boolean, observable)
```

The `TCP` fragment and the extended `State` properties are custom registry contributions — the same pattern as `WorkCoordinates` in the mill example. Total nodes: ~130.

---

## The pattern

Every machine above follows the same structure. The framework handles all the plumbing:

```
axis declarations
  └── FromAxis.to_object/1
        └── standard properties (all axes)
        └── type properties (linear: AtHome, rotary: Direction)
        └── :extra properties (machine-specific)

behavior declarations
  └── FromBehavior.catalog_object/1  → Behaviors.Catalog.<Name>
  └── FromBehavior.runtime_properties/1 → Behaviors.Runtime.ActiveBehavior

registry merge
  └── controller.axes_fragment/0
  └── controller.behaviors/0
  └── custom fragments (TCP, WorkCoordinates, etc.)
        └── Compiler.compile/1
              └── Projection.OPCUA.project/1
                    └── NodeManager (OPC UA address space)
                    └── REST routes
                    └── WebSocket subscriptions
```

Adding a new machine means writing one controller module and however many behavior definitions it needs. The address space, API surface, and HMI all follow automatically.