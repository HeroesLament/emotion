# Mastering: how the controller learns where the joints are

Status: IMPLEMENTED. `exdrive` models it, `exstore` shadows it, `exmove`
enforces it, `exproto` exposes it. 698 tests.

The firmware side is `servo4257-rs/docs/MASTERING.md`. This is the other half:
what the controller does with a fleet of drives that may or may not know where
they are.


## The finding this started from

The controller asked each drive "are you mastered?" and nothing could answer,
because nothing had the concept. Reading the firmware turned up something
worse: `0x6064` there is a delta accumulator seeded to zero at the first tick,
and the encoder is single-turn at the MOTOR, so through a gearbox neither the
offset nor the turn count is recoverable at power-up on its own.

The simulator was wrong in both directions at once. It had a `:homing` mode the
firmware does not implement, and it had no mastering at all — so a simulated
fleet could never exercise the one thing the controller most needs to get
right.


## Two positions, and never conflating them

```
actual_position   the drive's own accumulator. Always a number. Never
                  meaningful on its own.
joint_position    that number related to a declared zero. `nil` exactly when
                  nobody may act on it.
```

Everything that computes a POSE reads the second: forward kinematics, teaching
a point, Cartesian motion, running a program. Everything that moves an axis
*relative to where it is* reads the first: joint jog, which is how an
unreferenced axis gets recovered.

`ExMove.Mastering` is the only module that decides which is which, so the rule
cannot be written twice and drift once.


## Three states, which are not severity levels

| state | what is missing | what it may do |
|---|---|---|
| `:unmastered` | nobody ever declared a zero for this joint | jog in accumulator space; master |
| `:unreferenced` | the zero is known, the turn count is not | **joint jog** — driving to the witness mark IS the recovery |
| `:referenced` | nothing | everything |

Keeping `:unreferenced` and `:unmastered` apart is not pedantry. They have
different recoveries, and an operator told only "not ready" has to go and find
out which. Every refusal in the stack names the joint and the missing fact.


## Where the number lives, and why it is not here

The drive owns the offset. On real hardware the magnetic encoder is on the
driver board, so the offset is a property of *this board bolted to this motor
bolted into this joint*: a board swap legitimately invalidates it, and it must
travel with the hardware rather than with a controller database.

A controller that pushed a stored offset back at boot would eventually push a
stale one, and the failure is silent — every joint would still report a
plausible angle, every move would still execute cleanly, and the work would
land somewhere other than where it was taught. Nothing faults. You find out at
the workpiece.

So `masterings` is a **shadow**, and the migration says so at the top. It is
insert-only, has no unique index per axis, and has no apply path. It exists for
three things a shadow is genuinely good for:

* **backup and restore** — a replacement board can be given the old number
  deliberately, by a person who knows they are doing it;
* **history** — when did this change, and who changed it;
* **drift detection** — see below.

`ExStore.Masterings.compare/3` is the reason the table exists. It answers three
different questions rather than one:

```
{:changed, axis, was, now}   the dangerous one. Every point taught on this
                             robot has moved by the difference.
{:lost, axis, was}           the axis had a zero and now reports none.
                             A replaced board, or a wiped page.
{:new, axis, now}            first time. Expected after commissioning,
                             worth a mention any other time.
```

An axis that agrees is absent, so an empty list means the fleet is exactly as
it was left. `ExProto.Controller` runs this at startup and logs what it finds.
A log line is the minimum; an operator confirmation before the first program
runs is the eventual answer.


## Modelling forgetfulness honestly

`Exdrive.Flash` holds two things per axis, and the design turns on their being
different:

* **`:rotor`** — where the arm physically is. Metal remembers. It survives a
  power cycle because it is not information.
* **`:record`** — the MASTER page: the offset, and where the drive believed the
  rotor was at the last save.

A drive coming up compares the two. Inside tolerance, the record is good and
the turn count is restored. Outside it, somebody moved the joint while the
power was off.

The tolerance is a **quantisation allowance, not a movement allowance** —
1 mrad, ~0.057°. It has to clear simulated noise and nothing else; anything a
human would call "it moved" must trip it. Widening it does not make an axis
more robust, it makes the aliasing hole bigger.

Drift is reported even when it passed. A drift that creeps toward the limit
over months is a slipping coupling, and swallowing it because it passed is how
that finding is lost.

`terminate/3` writes the record and does not run on a kill. That asymmetry is
the model of a bulk-capacitor save versus yanking the plug, and it is the only
way a test can produce an axis that comes back not knowing where it is. The
drive deliberately does NOT trap exits, so that a kill really is a power cut.


## The simulator's factory step

`Exdrive.Drive` takes `master_on_first_boot: true` (default), which masters an
axis at zero **only when the flash page is blank**. A real drive ships
unmastered because nobody has bolted it into a joint yet; a simulated arm has
no witness mark to drive to, and the alternative is every dev session starting
by mastering six axes by hand.

It is an option rather than a hardcoded convenience because the CANopen adapter
that talks to real hardware must never pass it. And because it only fires on a
blank page, backdriving, erasing and re-mastering all still behave — the
interlock still means something.


## Where the refusals are

| place | refuses | why there |
|---|---|---|
| `ExMove.JointState.read/1` | `{:unreferenced, axis}` | every pose in the system starts here |
| `ExMove.CartesianStream.hold/3` | at admission | a stream that quietly never moves is worse than a refusal |
| `ExMove.CartesianStream` enqueue | at admission | `move_linear` and `move_arc` both land here |
| `ExProto.Program.Run` start | before the program is fetched | refusing halfway down leaves the arm somewhere nobody chose |
| `Exdrive.Drive.master/2` | while the output stage is on | on real hardware a flash write stalls the current loop |

Joint jog is deliberately absent from that list.

The drive-side refusal is worth its own note: it lives in the drive rather than
in a cell-level "is anything moving" check, which would let you master a
stationary-but-*enabled* axis — exactly the case that stalls a current loop.
The firmware answers SDO abort `0x08000022` to the same request.


## The protocol surface

```
cell.referenced        property, boolean, read_state
cell.mastering         method  -> [type.axis_mastering], read_state
cell.master_axis       method  (axis, at) -> offset, CALIBRATE
```

`cell.master_axis` is behind `calibrate` rather than `write_configuration`,
because `calibrate` is described as "write calibration constants and joint
offsets" and this is literally that. Writing a joint offset is not something an
operator does with a pendant in their hand.

`at` defaults to zero and supports a witness mark deliberately outside the
working range — some marks are at a hard stop, and "this is minus ninety
degrees" has to work as well as "this is zero".

`type.axis_mastering` carries the state as a **word**, not a boolean. A pendant
showing "not ready" for both `unreferenced` and `unmastered` cannot tell an
operator what to do next.


## Units

Radians, throughout. The firmware works in encoder counts; the counts/radians
conversion belongs to the CANopen adapter that talks to a real drive, not to
the model of one, and not to anything above it. `Exdrive.Drive`'s existing
contract — SI throughout, no unit field anywhere — is unchanged by this.


## Testing

* `Exdrive.MasteringTest` — 34 tests in exdrive. Every one is a power cycle:
  clean power-down, kill, backdrive, erase, re-master, and the boot resolution
  as a pure function.
* `ExMove.MasteringTest` — what an unreferenced axis is and is not allowed to
  do, and that the report names every bad joint rather than the first.
* `ExStore.MasteringsTest` — the shadow, and `compare/3`'s three findings.
* `ExProto.Source.CellMasteringTest` — the wire.
* `ExProto.Program.RunTest` — a program refused at the top.

The tests that took the longest to get right were the ones that establish their
precondition rather than assume it. A test asserting a refusal, which does not
check the condition the refusal depends on, passes for exactly as long as
nothing else in the VM has re-mastered the axis — and then reports the wrong
thing when something does.


## OPEN

* **A supervisor shutdown does not save.** `terminate/3` only runs on
  `:gen_statem.stop`, because the drive does not trap exits — and that is
  deliberate, so a kill can model a power cut. But it means a clean application
  shutdown does not write the record either, which a real cell would want.
  Needs a shutdown path that is distinguishable from a kill.
* **`:homing` is still there.** `Exdrive.Drive` has a homing mode with
  `homing_method` and `homing_complete`, and the firmware implements no homing
  at all — no `0x6098/99/9A`. It grants nothing now that mastering exists, and
  it should go, but removing it touches `ExProto.Source.Exdrive`'s
  `operating_state` and is its own change.
* **`joint_settings.home`** is still stored and read by nothing. It predates
  this and its meaning has now moved into the drive; either it becomes the
  shadow's per-joint witness-mark angle or it goes.
* **No axis-level property.** `axes.jN.mastering` would let a pendant colour a
  single joint without calling `cell.mastering`. The cell-level report covers
  the need for now.
* **A swap is inferred, not reported.** `compare/3` can say an axis's number
  changed; it cannot say a board was replaced. FANUC's encoders carry identity
  and their controller alarms on a mismatch, which is why a swapped arm faults
  there and would be silent here. `servo-rs` already derives LSS serials from
  the MCU UID, so the identity exists and is not read — see `INSTALLATION.md`.

* **The audit only logs.** An operator confirmation before the first program
  runs after a `{:changed, ...}` finding is the version that actually stops the
  bad part being made.
* **Restore is not wired.** The shadow can describe what a replacement board
  should be given; nothing writes it back yet. That wants `0x607C` on the real
  drive and a deliberate, grant-gated action here. `INSTALLATION.md` records why
  it is a separate verb from restoring an installation rather than part of one.
