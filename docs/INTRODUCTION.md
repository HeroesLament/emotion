# Introduction to ExMo

ExMo is an open industrial motion controller framework built entirely in Elixir/OTP. It is designed to run anything from a single-axis leadscrew on a mini lathe to a 9-DOF arm with multiple manipulator channels — a developer-friendly alternative to ROS2 that brings OTP's supervision, fault tolerance, and concurrency model to real-time motion control.

The reference hardware uses a Raspberry Pi CM5 communicating over SPI to a ULX3S ECP5 FPGA, which bridges to CAN FD via an MCP2518FD controller. The architecture is transport-agnostic: drives, sensors, and actuators attach through swappable transport adapters.

---

## Design philosophy

ROS2 is powerful but brings significant operational complexity — a C++/Python ecosystem, a separate middleware layer (DDS), and a steep on-ramp for anyone outside robotics. ExMo's thesis is that Elixir/OTP already provides most of what ROS2 offers at the infrastructure level:

| ROS2 concept | ExMo equivalent |
|---|---|
| Node | OTP `GenServer` / `gen_statem` |
| Topic | `Phoenix.PubSub` or process messaging |
| Action | Behavior (`ExMo.Behavior`) — long-running, observable |
| Service | Synchronous `GenServer.call/3` |
| Lifecycle node | `gen_statem` with explicit state machine |
| Parameter server | Application config + ETS |
| rosbridge | ExHMI OPC UA / REST / WebSocket projections |

The goal is a framework where adding a new axis, sensor, or manipulator channel is an Elixir module — not a build system adventure. A complete machine controller looks like this:

```elixir
defmodule MiniLathe do
  use ExMo.Controller

  axis :z,       type: :linear, unit: :mm,  limits: {-300.0, 0.0}, home_pos: 0.0
  axis :spindle, type: :rotary, unit: :rpm,  limits: {0.0, 3000.0}

  behaviors [
    ExMo.Behaviors.MiniLathe.Home,
    ExMo.Behaviors.MiniLathe.SetSpindleSpeed,
    ExMo.Behaviors.MiniLathe.Threading
  ]
end
```

That declaration is a valid OTP supervisor, a full Information Model contributor, and a behavior registry entry. No boilerplate, no parallel data structures.

---

## Hardware stack (reference implementation)

```
Host (Elixir/OTP)
  └── SPI
       └── ULX3S ECP5 FPGA
             └── SPI
                  └── MCP2518FD CAN FD controller
                        └── CAN FD bus
                               └── Drives / actuators (n axes)
```

The transport layer is abstracted behind `ExDrive.Transport` — a CAN FD adapter, an EtherCAT adapter, or a mock simulator all satisfy the same interface.

---

## OTP applications

### ExDrive
Single-axis drive abstraction. The CiA 402 state machine is implemented as a `gen_statem` and models the standard drive lifecycle (Not Ready → Switch On Disabled → Ready To Switch On → … → Operation Enabled). Each axis runs as an independent supervised process. The real transport layer (`ExDrive.Transport.CAN`) is pending; a simulator is available for development.

### ExMove
Kinematics engine. Parses a robot's URDF, builds a kinematic chain, and exposes:
- Forward kinematics (`ExMove.FK`) — joint angles → TCP pose
- Inverse kinematics (`ExMove.IK`) — TCP pose → joint angles, backed by a Rust NIF using a Jacobian solver
- Path execution (`ExMove.PathExecutor`) — streams `%Frame{}` structs to drives
- Lookahead (`ExMove.Lookahead`) — velocity blending across waypoints

The number of joints is read from the URDF — ExMove is not hardcoded to any axis count.

### ExGCode
GCode parser that reads standard G0/G1/G2/G3 moves and fixture offsets, and emits a stream of `%ExGCode.Frame{}` structs for consumption by ExMove.

### ExDash
Lightweight terminal dashboard for live monitoring of drive state, joint positions, and controller mode.

### ExOpcUA
Pure-Elixir, zero-NIF OPC UA server and client. Implements the binary TCP transport (`opc.tcp`), SecureChannel (currently None security), and Session layers from scratch.

**Server** — `GenServer`-based listener, per-connection `gen_statem`, and a `NodeManager` that holds the address space as an ETS table. Supports Browse, Read, Write, and Publish (monitored items / subscriptions).

**Client** — four composable `gen_statem` processes:

| Process | Responsibility |
|---|---|
| `Transport` | TCP framing, HEL/ACK handshake |
| `Session` | OPN, CreateSession, ActivateSession, frame routing |
| `Channel` | Read / Write / Browse, one in-flight request at a time |
| `SubManager` | Subscription lifecycle, publish loop, change callbacks |

All of Browse, Read, Write, Subscribe, and Unsubscribe are confirmed working end-to-end.

### ExHMI
Northbound gateway. Owns the ExMo Information Model and projects it onto external protocols. Currently targets OPC UA; REST and WebSocket projections are planned.

---

## The ExMo Information Model

The Information Model (IM) is the architectural centrepiece of ExHMI. It is the single source of truth for every node, variable, method, and event that ExMo exposes to the outside world. OPC UA, REST, and WebSocket are all *projections* of this model — nothing else maintains a parallel definition of the address space.

### Schema layer (`ExMo.Schema.*`)

The schema is a set of plain Elixir structs:

| Struct | Purpose |
|---|---|
| `Model` | Root container — id, name, version, type registry, root object |
| `Object` | A named node that can contain children (objects, properties, methods, events) |
| `Property` | A typed, readable/writable/observable value |
| `Method` | A callable with typed input and output arguments |
| `Event` | A named payload type (projection-deferred) |
| `Argument` | One input parameter of a method |
| `ResultField` | One output field of a method |
| `Enum` | A named set of string values |
| `StructType` | A named set of typed fields |
| `Type` | Primitive (`:boolean`, `:string`, `:int32`, `:uint16`, `:float`, `:double`) or composite (`{:enum, id}`, `{:struct, id}`, `{:array, t}`, `{:ref, id}`) |

### Compiler (`ExMo.Schema.Compiler`)

`Compiler.compile/1` takes a raw `Model`, normalises all node paths recursively, validates that all type references resolve, checks for duplicate sibling IDs, and returns `{:ok, compiled_model}` or `{:error, reasons}`.

### Controller DSL (`ExMo.Controller`)

`use ExMo.Controller` gives any machine module the `axis/2` and `behaviors/1` macros. At compile time they accumulate into module attributes. At runtime the framework generates:

- The OTP `Supervisor` children (one `ExDrive.Drive` per axis)
- `axes_fragment/0` — the `%Object{}` subtree for this machine's axes, derived automatically via `ExMo.Schema.FromAxis`
- `behaviors/0` — the list of behavior modules for the registry

`FromAxis` derives the standard property set for each axis from its spec alone — Position, TargetPosition, Velocity, DriveState, FaultCode for all axes, plus AtHome for linear axes and Direction for rotary axes. Custom properties are supported via the `:extra` option.

### Behavior contracts (`ExMo.Behavior`)

A *behavior* is a long-running, observable machine action — home an axis, execute a tool change, cut a thread. Each behavior module implements the `ExMo.Behavior` callback and declares:

- Input arguments (what the caller must supply to invoke it)
- Output arguments (what is returned when it completes)
- Runtime fields (live observables published during execution)
- Faults (typed failure modes with severity)

`ExMo.Schema.FromBehavior` automatically generates the Catalog entry (Supported, Description, Invoke method) and the Runtime properties from the behavior's definition. Adding a behavior to the registry is one line.

### Registry (`ExMo.Schema.Registry`)

`Registry.base_model/0` assembles the full model by merging axis fragments and behavior definitions from registered controller modules. The current default model exposes:

```
ExMo
├── Behaviors
│   ├── Catalog
│   │   └── RemovePreviousPrint (Supported, Description, Invoke)
│   └── Runtime
│       └── ActiveBehavior (Id, Name, JobId, Phase, Progress, …)
├── Printers
│   └── K1C_01 (ReadyForUnload, DoorState, BuildPlatePresent, UnloadLaneClear)
└── State (ControllerMode, FaultPresent)
```

### OPC UA projection (`ExMo.Projection.OPCUA`)

`OPCUA.project/1` walks the compiled model and emits a flat list of `NodeSpec` structs — one per node — each carrying the OPC UA node class, NodeId, parent reference, data type, access level, and method argument metadata.

NodeIds follow the pattern `ns=1;s=<dot-joined path>` — e.g. `ns=1;s=ExMo.Behaviors.Catalog.RemovePreviousPrint.Invoke`. The Objects folder root is `ns=0;i=85`. The current default model projects to 30 deterministic nodes.

```elixir
{:ok, model} = ExMo.InformationModel.compiled_model()
{:ok, nodes} = ExMo.Projection.OPCUA.project(model)

ExMo.Projection.OPCUA.find(nodes, "ns=1;s=ExMo.Behaviors.Catalog.RemovePreviousPrint.Invoke")
ExMo.Projection.OPCUA.filter(nodes, :variable) |> Enum.map(& {&1.node_id, &1.data_type})
```

---

## What is pending

- **Runtime binding** — `ExMo.Runtime.Binding` maps a live behavior snapshot onto the `ActiveBehavior` variable values and pushes them into the ExHMI address space
- **NodeManager integration** — feed the projected `NodeSpec` list into `ex_opcua`'s server so the OPC UA address space is generated from the model at startup
- **Method invocation routing** — an OPC UA `Call` request on `Invoke` launches the corresponding behavior
- **Registry dynamic merge** — `Registry.base_model/0` accepts controller modules and merges their `axes_fragment/0` and `behaviors/0` contributions automatically
- **Second behavior** (Home or ToolChange) to prove the registry merge pattern
- **ExDrive.Transport.CAN** — real CAN FD transport replacing the simulator
- **Security** — OPC UA `Basic256Sha256` behind a mix config flag
- **ExUnit coverage** — codec, server, and client tests for ex_opcua