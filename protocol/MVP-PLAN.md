# The remaining six: touchpoints, order, and the decisions that are not obvious

Status: IN PROGRESS. Task 0 and service 4 are implemented; the rest stands. Written after measuring the code
rather than remembering it; every claim about what exists has a file behind it.

Six services stand between here and V1:

| | service | blocked by |
|---|---|---|
| 1 | CANopen adapter to `servo-rs` | ~~a drive seam that does not exist~~ — done, see Task 0 |
| 2 | Digital I/O | where the I/O physically is — undecided |
| 3 | I/O statements | 2 |
| 4 | ~~Program upload over the wire~~ — DONE (`702500c`) | — |
| 5 | Variables & expressions | nothing |
| 6 | Branching, loops, labels | 5 |

They fall into two tracks that do not touch each other. **Hardware** is 1 → 2 → 3
and is where all the risk is. **Language** is 4 → 5 → 6 and is where all the
typing is. Nothing in the language track needs a real drive, so it can be built
against the simulator and be finished before hardware arrives.


## 0. The prerequisite nobody has named: there is no drive seam

Measured, not assumed:

```
apps/exproto/lib/exproto/source/exdrive.ex   12 call sites
apps/exmove/lib/exmove/cartesian_stream.ex    5
apps/exmove/lib/exmove/robot.ex               4
apps/exproto/lib/exproto/program/run.ex       3
apps/exmove/lib/exmove/path_executor.ex       2
apps/exmove/lib/exmove/mastering.ex           2
apps/exdash/lib/exdash.ex                     2
… 4 more, 1 each                             11 modules, 5 apps
```

`Exdrive.Drive` is called **directly** from every layer above it. There is no
behaviour, no adapter, no indirection. A CANopen implementation cannot be
"added" — there is nowhere to add it.

The good news is that the surface is small. Nine functions are used from
outside `exdrive`:

```
status  set_target_position  set_target_velocity  set_mode
enable  control_word  quick_stop  fault_reset  master
```

**Task 0 — DONE.** The behaviour is `EMotion.Drive`, not `ExDrive.Axis`: the
namespace was reconciled in the same pass, because `E-Motion` was the old name and
the Studio had been `EMotion.*` all along. `Exdrive.Drive` is its first
implementation, `EMotion.Axis` is the façade the 28 call sites now go through,
and `EMotion.Drive.for/1` selects a module per axis from config, defaulting to
the simulator.

`protocol/DESIGN.md` proposed a different shape for this contract — `read/3`,
`write/4`, `state/1`, in object-dictionary terms. It lost, because a PWM
actuator has no object dictionary and would have had to fake one. That section
has been rewritten with the argument. The object-dictionary callbacks were not
discarded; they became `EMotion.Drive.ObjectDictionary`, an optional second
behaviour, which is also where the SDO tunnel in `METRONOME.md` lands.

Of the two things flagged to get right while the file was open:

* **Axis ids — settled.** `EMotion.Drive.normalize_id/1` is the one answer:
  both spellings are accepted at the boundary and normalised immediately, and
  an unknown binary raises rather than growing the atom table. Implementations
  no longer each get to decide.
* **`ExProto.Controller.axes/1` starts phantom drives — still open.** It
  matches any `axes.<x>.<field>` node id, so `axes.tcp.*` and `axes.cartesian.*`
  start drives named `"tcp"` and `"cartesian"`. Harmless against a simulator;
  against a bus it means two node ids that map to no hardware. The seam does
  not fix this, because supervision is still implementation-specific — nothing
  above `exdrive` calls a concrete drive any more, but `ExProto.Controller`
  still *starts* `Exdrive.Drive` children directly. That is the next piece of
  the hardware track, not this one.


## 1. CANopen adapter to `servo-rs`

### What the firmware already fixes

From `servo4257-rs/crates/cia402/src/pdo.rs`, the mapping is compiled in and
not dynamically remappable:

```
SYNC          0x080
RPDO1  0x200+n   controlword (u16) + target position (i32)     6 bytes
RPDO2  0x300+n   target velocity (i32) — feed-forward, NOT optional
TPDO1  0x180+n   statusword (u16) + position actual (i32)      6 bytes
TPDO2  0x280+n   velocity actual (i32) + following error (i32) 8 bytes
```

The controlword rides in the same frame as the setpoint on purpose, so a stop
cannot be delayed relative to a target it needs to override. `0x1600`/`0x1A00`
are readable so a master can *discover* the mapping, and writes are accepted
only if they agree with it.

Also fixed: node id and bitrate live in the drive's IDENT page, a fresh board
parks at `0xFF` (CiA 305 unconfigured) and answers only LSS, and serials are
derived from the MCU UID so Fastscan can separate them.

> **Superseded in part by `protocol/FIELDBUS.md`.** The topology is decided:
> separate CAN networks per joint group, J1&ndash;J3 and J4&ndash;J6. Three axes a bus
> turns the budget below from impossible into comfortable (500 Hz at ~49 % a
> bus at 1 Mbit/s), and it moves the cyclic engine onto the metronome, because
> two buses have two SYNCs and two SYNCs are two time bases. Read that document
> first; the single-bus arithmetic here is kept because it is how the
> conclusion was reached.

### The finding that decides the architecture

An SDO round trip is ~1 ms on that bench, so setpoints must be PDOs. Fine. But
count the frames for a six-axis fleet.

A standard CAN data frame is `47 + 8N` bits before stuffing. Per 1 kHz cycle,
six axes, all four PDOs:

| bitrate | per cycle (with stuffing) | 1 kHz | 500 Hz | 250 Hz |
|---|---|---|---|---|
| 500 kbit/s | ~5.35 ms | 535 % | 268 % | 134 % |
| 1 Mbit/s | ~2.68 ms | 268 % | 134 % | **67 %** |

**A six-axis CSP fleet at 1 kHz does not fit on classical CAN at any bitrate
these boards support.** It needs ~4.6 Mbit/s. This is not a tuning problem.

Note `docs/CONFIG_PERSISTENCE.md`'s own estimate — "at 500 kbit/s a 6-byte
frame is ~130 µs" — implies 65 bits for a frame that is at least 95. It
undercounts frame overhead by roughly 1.7×. **Measure this on the bench before
building against either number.**

Dropping TPDO2 (velocity actual + following error) to every fourth cycle brings
1 Mbit/s to ~48 % at 250 Hz, which is a workable envelope. Two buses of three
axes is the other lever, and it also halves the blast radius of a bus fault.

### Which changes the mode

At 250 Hz the master is not streaming per-tick setpoints, so **csp (mode 8) is
the wrong mode**. `servo-rs` already anticipates this: `crates/boundary/src/ipbuf.rs`
is a segment ring for **ip (mode 7)**, built before the mode itself —

```rust
pub struct Segment {
    pub pos: i32,   // target position at the end of this segment, counts
    pub vel: i32,   // velocity across the segment, counts/s — feed-forward
    pub ticks: u32, // duration in control-loop ticks
    pub seq: u32,   // so a GAP is visible as a gap, not as a jump in position
}
```

That `seq` field is the safety property a slower master needs, and it is
already there.

**This is the same fork the metronome discussion parked.** The note then was:
*if the FPGA interpolates, `CartesianStream` must emit path segments rather
than per-tick setpoints.* The CAN budget forces the identical change with no
FPGA involved. They converge, and building segment emission once serves both.

### Touchpoints

| where | change |
|---|---|
| new app `apps/excan` | SocketCAN (Linux) / slcan; frame in, frame out; nothing above the link layer |
| new app `apps/excanopen` | NMT, SYNC producer, SDO client, PDO encode/decode, LSS, EMCY, heartbeat |
| new `ExDrive.CANopen` | implements the Task-0 behaviour; owns node id ↔ axis id |
| `ExMove.CartesianStream` | emit **segments** rather than per-tick setpoints (the big one) |
| `ExStore.Cell.JointSetting` | **gear ratio and counts-per-rev have no home today** |
| `EMotion.Cell` / mastering | counts ↔ radians at the adapter boundary only |
| `ExProto.Controller` | start an adapter per axis instead of a simulated drive |
| `apps/metronome` | the SYNC producer is the metronome's job if it is fitted |

### Counts ↔ radians is its own service and it is not trivial

`joint_angle = (counts − master_offset) / (65536 × gear_ratio) × 2π`, and
**`gear_ratio` exists nowhere in E-Motion.** It is a commissioning fact — a
property of this joint on this machine — so it belongs beside `soft_lower` in
`joint_settings`, next to `counts_per_rev` and a direction sign.

Do the conversion in the adapter and nowhere else. The moment a radian-to-count
factor appears in `exmove` or `exhmi`, there are two of them.

### How to prove it without the arm on

1. A loopback CAN pair (`vcan0`) and a **software drive that speaks the wire
   protocol** — the existing simulator behind a CANopen skin. Everything above
   is then testable at full rate with no hardware.
2. One motor on the bench, no linkage: enable, jog, master, read back.
3. One joint of the arm.
4. Six.

Bus load measured with `candump` statistics at each step, against the table
above.


## 2. Digital I/O — the fork that has to be settled first

There is no I/O anywhere. `write_io` is a defined grant with nothing behind it.
Before any code, decide **where the pins are**:

| option | for | against |
|---|---|---|
| CiA 401 I/O node on the drive bus | one bus, one stack, deterministic, arrives with the CANopen work | another board to buy; adds bus load |
| Host GPIO (Pi, `circuits_gpio`) | trivial, no protocol | not on the motion bus, so no timing relationship to motion; a separate wiring story |
| Drive-hosted pins | no extra hardware | `servo-rs` has no I/O profile; would be new firmware and a new object range |

For the MVP the deciding question is narrower than "I/O": **how does the
gripper close?** Answer that and the rest follows. If it is a bus device, the
CiA 401 route is nearly free once the stack exists; if it is a UART gripper, it
is not an I/O service at all but a device driver, and it should be modelled as a
*tool with actions* rather than as `DO[1]`.

### Touchpoints once decided

* new `io` object in `EMotion.Schema.Registry` — signals as named nodes, not
  `DO[1]`; the point of an information model is that names travel
* `ExStore.Cell.Signal` — name, direction, address, invert, default; a signal a
  program refers to must be a **reference**, so `statement_refs` gains a
  `signal_id` column and the `exactly_one_referent` CHECK grows a term
* `ExProto.Source.IO` + a route in `ExProto.Source.Composite`
* `write_io` finally gates something


## 3. I/O statements

Three kinds, and the third is the interesting one:

| kind | motion? | note |
|---|---|---|
| `set_signal` | false | a barrier — the queue drains first, or the gripper closes while the arm is still moving to the pick |
| `wait_signal` | false | needs a timeout, and a timeout needs a fault path |
| `set_signal_at` | **true** | fire an output *at a point along a motion*, without stopping |

The first two are an afternoon on top of the existing kind registry. The third
is what makes a real cycle time — every incumbent has it (FANUC's `DO[1]=ON`
inside a motion's option block, ABB's `TriggL`) — and it does not fit the
current model, because `EMotion.Program.Kind`'s `motion?` flag is binary and
`ExProto.Program.Run` treats every non-motion statement as a barrier.

Recommendation: ship the first two for V1, and record `set_signal_at` as the
first thing that will bend the statement model, rather than bending it now.

Touchpoints: `EMotion.Program.Kinds` (+3 kinds), `EMotion.Program.Editor` (validate a
signal reference), `ExProto.Program.Run` (execute + timeout + fault),
`protocol/PROGRAMS.md` §5.


## 4. Program upload over the wire

The smallest of the six and the one with the most leverage: today a program can
only be authored by `mix emotion.program`, which means **Studio cannot put a
program on the controller**. That is a hole in the product, not in the code.

The engine, the store, the validation and the refusals all exist —
`EMotion.Program.Editor` already validates a statement against the kind registry
at store time. What is missing is an entry point.

### Touchpoints

* `EMotion.Schema.Registry` — `program.store` (whole program, replacing by name),
  `program.delete`, guarded by `load_program`/`edit_program`, which already exist
* `ExProto.Source.Program` — the handler; every refusal already has a shape
* a struct type for a submitted statement, mirroring `type.statement`

### The decisions

* **Whole program, not statement-at-a-time.** A half-uploaded program is a
  program, and the store would let it run. Replace atomically inside one
  transaction or refuse.
* **Refuse to replace a program that is running.** `ExProto.Program.Run` holds
  `state.program` and `state.body`; it captured them at start deliberately, so
  the danger is not the running program changing under itself but the operator
  believing the new one is what ran.
* **Return the statement index of the first refusal.** An editor that is told
  only "rejected" cannot put the cursor anywhere.


## 5. Variables & expressions

Nothing blocks this. It is the largest piece of *design* in the six, because it
is the first time the controller has a type system that is not about geometry.

### Scope for V1 — deliberately small

Three types: `number`, `bool`, `string`. Program-scoped, persisted, with an
initial value. No arrays, no structs, no user functions. That covers counting
parts, a retry limit, a part-present flag, and a message — which is what the
first hundred real programs need.

The one thing not to skip: **poses as values**. `p_target = offset(p_home, x: 0.05)`
is how palletising is written on every controller. If it does not fit V1, the
expression grammar must be able to grow it without a rewrite.

### Touchpoints

* `ExStore.Cell.Variable` — `program_id`, name, type, initial value; unique on
  `(program_id, name)`
* `ExStore.Program.StatementRef` — a `variable_id` column, so deleting a
  variable a program uses is a **constraint**, exactly as it is for points
* `EMotion.Program.Kind` — the param type union gains `{:expr, type}`; today a
  param is a literal or a reference and there is no third case
* a new `EMotion.Program.Expr` — parse to an AST, type-check at **store** time,
  evaluate at run time. Store-time checking is the whole value: a program that
  cannot fail on a type error halfway down is the difference between this and a
  scripting language
* `ExProto.Program.Run` — a bindings map in the run state; `program.variables`
  as a published node so a pendant can watch a counter
* new kind `assign`

### Two decisions worth making now

* **No implicit conversion.** `1 + "1"` is a store-time refusal.
* **Evaluate at execution, not at queue.** A motion queued two statements ahead
  must not capture a variable's value early. This interacts directly with
  look-ahead and is the kind of thing that is invisible until a program uses a
  counter inside a blended sequence.


## 6. Branching, loops, labels

### The schema is already ready

`ExStore.Program.Statement` has `parent_id` (self-referencing) and `seq`.
`ExStore.Program.StatementRef` already has `program_id`, which is a subprogram
call waiting for a caller. **Nested blocks need no migration** — an `if` is a
statement whose body is its children.

That is not luck; it is the same instinct that put the URDF in a column.

### The interpreter decision, which is not obvious

`ExProto.Program.Run` is a **flat index over `state.body`** with a second
pointer — `in_flight` — tracking motions queued ahead of the arm. `resume`
re-issues at `state.index`. `step` advances one. Barriers drain the queue.

There are two ways to add control flow and only one of them survives that:

* **A tree walk with a frame stack** — natural to write, and it breaks
  everything. `state.index` stops being a position, `resume` has nothing to
  re-issue, and `in_flight` cannot name a statement.
* **Flatten at load time into a linear instruction list with jump targets.**
  `fetch_body/1` becomes a compiler: blocks become `jump_if_false` /
  `jump` with resolved indices. The index stays an index, `in_flight` stays a
  list of indices, `resume` and `step` are untouched, and the barrier rule needs
  one addition — **a jump is a barrier**, because a branch decided while three
  motions are queued ahead of the arm has already been decided wrongly.

Take the second. The two-pointer design was the expensive thing to get right;
control flow should be arranged not to disturb it.

### Scope for V1

`if / else`, `while`, `call` (another program, no arguments). No `goto`, no
labels — a jump table generated from structure cannot produce an unreachable
statement, and a hand-written label can.

Recursion is refused at store time by walking the call graph: `statement_refs`
already makes the graph a query.

### Touchpoints

`EMotion.Program.Kinds` (+3), `EMotion.Program.Editor` (block nesting, call-graph
check), `ExProto.Program.Run` (the flattener, `jump_if_false`, the jump
barrier), `ExStore.Programs` (fetch the tree, not a flat list), `type.statement`
(depth or parent, so an editor can render a block), `protocol/PROGRAMS.md`.


## Order, and what it buys

```
Track A — hardware, all the risk
  0  drive behaviour                 ~30 call sites, covered by existing tests
  1a CAN link + CANopen stack        against vcan0 and a simulated drive
  1b gear ratio / counts↔radians     joint_settings + adapter only
  1c segment emission                CartesianStream — shared with the metronome
  1d one motor on the bench
  2  digital I/O                     after the gripper question is answered
  3  I/O statements                  set_signal, wait_signal

Track B — language, all the typing, no hardware needed
  4  program upload                  smallest, unblocks Studio immediately
  5  variables & expressions         store-time type checking is the point
  6  branching                       flatten to jumps; a jump is a barrier
```

Do **4 first** regardless of track — it is the smallest of the six and it is
the one that stops Studio being a viewer.

The milestone that matters is not the end of this list. It is **0 → 1a → 1b →
1d: one motor, on the bench, moving under E-Motion over CAN, mastered.** Every
other item on the list is easier to judge once that has happened, and two of
them (the segment change, the I/O fork) may be decided differently by what it
teaches.


## Open questions this plan cannot answer

1. **How does the gripper close?** Decides item 2 entirely.
2. **What bitrate, and measured how?** The table above is arithmetic; the bench
   is the authority, and the firmware's own note disagrees with it by ~1.7×.
3. **ip mode is not implemented in `servo-rs`.** The segment ring exists; mode 7
   does not. Firmware work, and it lands in the same window as 1c.
4. **One bus or two?** Two of three axes halves the load and the blast radius,
   and costs a second interface on the host.
