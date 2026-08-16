# Programs, points and frames

What a stored program is, what a taught point is, and why frames come first.

Written before any of it exists, because the last document in this directory was
written the same way and its first two sections turned out to be wrong in ways a
single measurement would have caught. So this one leans on evidence where
evidence is available — four vendors who have each shipped this for thirty years
— and marks the rest as guesses to be checked rather than decisions to be
defended.

## The one idea

**Everything that makes a taught path adapt at runtime is a frame.**

Vision finding a part, a conveyor carrying one past, a fixture that was bumped
and re-taught, a force search that locates a surface — all four are the same
operation. Compute a frame, apply it to a path that was taught once and never
edited again.

That is why frames come first, and why they are not a convenience for teaching.
They are the extension point that everything interesting hangs off. A controller
without them can be told where to go; a controller with them can be told where to
go *relative to something that moved*.

## What the incumbents actually do

Not a survey. Four patterns that every one of FANUC, ABB, KUKA and Yaskawa
arrived at independently, which is the strongest available evidence that they are
properties of the problem rather than of a vendor.

**A program is statements over named points.**

    FANUC     L P[3] 500mm/sec CNT100
    ABB       MoveL p10, v100, z10, tool0 \WObj:=wobj1;
    Yaskawa   MOVL C00001 V=100.0 PL=2
    KUKA      LIN P3 Vel=2 m/s CPDAT1

Every line names a point and carries its own speed and termination. Not a stream
of coordinates — a sequence of references. `ExMove.CartesianStream`'s queue
already takes a feedrate and a blend radius per motion, which is the same shape
one layer down.

**Points and logic are stored apart.** KUKA is the most explicit: `.src` holds
the code and `.dat` holds the taught points, as a file pair. Yaskawa splits the
job from its position variables. The reason is organisational rather than
technical — teaching edits data, programming edits logic, and on a real cell
those are different people on different days.

**A point is stored relative to a frame, and the frame reference travels with
it.** FANUC positions are relative to the active UFRAME and UTOOL. The payoff is
the one every integrator quotes: when a fixture moves, you re-touch one frame and
all hundred taught points are good again. ABB puts `\WObj:=` and a tool on every
motion instruction rather than in ambient state.

**Something always runs beside the motion program.** Yaskawa's Concurrent I/O
"starts when the controller is powered up and runs constantly, in parallel with
any INFORM jobs". KUKA has the SPS submit interpreter, FANUC has Background
Logic, ABB has semi-static tasks. A motion program is never the only thing
executing, on any of them.

And one that only ABB makes explicit, which is the most useful of the lot:

**The joint configuration is stored with the point.** ABB's `robtarget` carries
`confdata`. Without `ConfJ`/`ConfL` enforcement the wrist can flip 180° at the
same Cartesian target, and the reported path deviation is 15–30mm. Our jog cannot
do this — velocity IK is differential and stays on the branch it starts on, which
`CARTESIAN.md` §5 already argues. A *taught point replayed as a pose* absolutely
can.

## Where vision comes in, which is not where it looks

FANUC's iRVision has exactly two idioms: **fixed frame offset**, where the vision
result offsets the robot within a user frame, for picking; and **tool offset**,
for correcting a part that was picked blind, when placing. Results land in vision
registers and the taught path is *shifted*. It is never regenerated. ABB applies
a `cameratarget` the same way.

So a vision system does not produce points. It produces a frame, and the program
that uses it was taught without knowing vision existed.

One distinction not to collapse, because FANUC deliberately does not: the frame
*node* is configuration, taught once and written behind a grant. A vision offset
is a *runtime argument to a move* — `VOFFSET,VR[1]` on the motion line, not a
mutation of UFRAME. Conflating them makes a cell where two parts in flight share
one mutable frame, and the second one moves the first one's path.

`axes.move_linear` therefore eventually wants an optional frame **and** an
optional offset. Not now. But nothing built now should make it awkward.

## The layering

`DESIGN.md` leaves this open: *"Where the cell model lives. Its own copy, or one
pushed by the Studio? Pushing means the controller cannot run a program alone;
holding means two copies that can disagree."*

Answered, and the deciding argument is in the question. **The controller holds.**
A program that only exists in Studio is not a stored program, it is a document —
and the property that makes a controller a controller is that it runs the cell
with the laptop closed.

Two copies that can disagree is a real cost and it is paid rather than avoided:
Studio keeps an offline copy so a cell can be programmed with no controller
present, and the copies are reconciled by an **explicit** push or pull that a
person asks for. Never an implicit sync. A tool that silently uploaded on save
would make opening a file a way to change a machine.

    Studio                          Controller
    ─────────                       ──────────
    offline cells                   frames        ← authoritative
    projects, layouts               points        ← authoritative
    a cached copy of ────push/pull──programs      ← authoritative
      frames/points/programs        execution
    simulation, preview             the queue

Studio's own storage is SQLite and is nobody else's business. Note that
`studio/mix.exs` currently justifies depending on `exlink` rather than `exproto`
partly on the grounds that the latter "would drag in the OPC UA server, SQLite
and Argon2 — a desktop application shipping a database in order to draw an arm".
Once Studio ships SQLite that clause is no longer true. The split is still right
for the other two reasons, and the comment needs correcting rather than quietly
outliving its argument.

## 1. Frames

  * `base` — the arm's origin. Done.
  * `tool` — the current TCP orientation, re-resolved per tick. Done.
  * `user` — named, stored, re-teachable. **Not built. This is the next thing.**

Model nodes under `frames.<name>`, readable by anyone and writable behind
`write_configuration`. A frame is six numbers and a name, which makes this the
smallest piece of work in this document and the one the rest of it needs.

Re-teaching a frame must move every point that references it and nothing else.
That single property is what makes frames worth having, and it is the first test.

Not in scope here, and named so they are not accidentally designed out:

  * **Dynamic frames** — a frame whose value is written at runtime by vision or
    by a conveyor encoder. Same storage, different lifecycle, and the grant is
    different too: teaching a frame is configuration, updating one at line rate
    is not.
  * **Frame hierarchy** — a frame defined relative to another, which is how a
    fixture on a positioner is described. Every vendor has it. Adding a parent
    reference later is cheap; assuming there is never one is not.

## 2. Points

A taught point is **a pose, the frame it was taught in, and the joint solution
the arm was actually in**.

The third of those is where we can do better than the incumbents rather than
merely matching them. ABB encodes a discrete configuration index — quadrant and
turn counters — because RAPID has to describe a branch compactly. We have the
whole joint vector at teach time and can simply store it, six floats, and seed
the solver with it on replay. That is not an encoding of the branch, it *is* the
branch, and it removes the failure mode rather than describing it.

It also makes the online/offline split from `CARTESIAN.md` fall out for free:
replay seeds from the taught solution and stays on that branch, while offline
`solve_with_restarts` is free to explore, because nothing is moving.

Points are named. Whether they are program-local, global, or both is an open
question below — every vendor ended up with both, which is a hint.

## 3. Programs

A named, stored sequence of statements. Starting set, deliberately small:

    move_joint    point, speed, termination
    move_linear   point, feedrate, termination
    move_arc      via, point, feedrate, termination
    wait          seconds | until a signal
    set           an output
    call          another program

Each motion statement carries its own feedrate and termination, which maps onto
the queue that exists today without changing it. FINE and blended termination are
already built and already tested; a program is a thing that fills the queue.

Branching — labels, jumps, conditionals — comes after. It is the difference
between a sequence and a language, and the sequence is worth having on its own.

**Execution is a process.** It fills the queue, watches for completion, and stops
on a fault. The queue enforces the rate ceiling, the joint limits, the tool speed
cap and the singularity policy exactly as it does for a jog, because those are
properties of the machine and not of who asked.

### Mode gets its second job

`ExProto.Mode` currently answers one question: jogging is manual-only. Programs
are the other half, and it is the same interlock rather than a new one.

    manual   jog permitted        program refused
    auto     jog refused          program permitted

Which is how all four vendors work, and it is why the mode enum already reads
`idle | manual | auto | fault`. The grant vocabulary anticipated this too:
`execute_program`, `load_program` and `edit_program` have been in
`ExAuth.Grant` since it was written, unused.

### Program source is not on the RPC link

`README.md` in this directory already decided this: *"Bulk transfer — program
source, logs, motion traces — is not on this link. It is plain HTTP on the same
host so it stays curl-able and does not compete with live telemetry."*

So the model carries what a pendant renders — a program's name, its state, the
line it is on, its fault — and the source itself is uploaded and downloaded over
HTTP. A program that is thousands of lines does not belong in a JSON-RPC frame
competing with a 30 Hz position stream.

## 4. The parallel logic context

Every incumbent has one. We should not build a ladder editor, and we should not
assume the motion program owns the machine either — because that assumption is
the one that is expensive to undo.

On the BEAM this is the easiest thing in the document to get right and the
easiest to get wrong by not thinking about it. A supervised process that watches
signals and reacts is not a feature to build, it is what the runtime already is.
What matters now is only that the program model does not assume it is the sole
executing context: nothing may claim the arm implicitly, and holds stay the way
motion is claimed.

## 5. Where G-code and behaviours fit

**`ExGCode` is an importer, not the program model.** G-code is the CAM lineage:
it streams coordinates, with no named points, no frames, no per-line termination
and no logic. Every vendor supports it as an import path and none uses it as the
native model. The parser exists and is 299 lines with no tests; what it needs is
to produce a *program* rather than a stream of `%Frame{}`, because a stream of
frames goes around the queue and therefore around every limit and every report
that `CARTESIAN.md` spent its length establishing.

**`ExMo.Behavior` is the extension mechanism**, and Universal Robots names the
pattern most clearly. A URCap contributes **installation nodes** — system-level,
one instance, configuration — and **program nodes**, which appear as statements
inside a program. We have arrived at the same split without naming it:
`RemovePreviousPrint` is a program node, and user frames are installation.

Naming it suggests the shape: a behaviour becomes a statement a program can
contain, and the K1C unload stops being a special top-level thing and becomes a
line in a program that also moves the arm.

## 6. Storage

**One controller database.** Frames, points and programs join accounts and tokens
in the existing repo. One file to back up — and `backup` is already a declared
grant — one migration path, one thing to get right on a Nerves image.

`ExAuth.Repo` then outgrows its name, since it stops being the credential store
and becomes the controller store. Renaming it is a mechanical change that should
happen at the moment the first non-credential table lands, not two months later
when it is a hundred call sites.

Studio's SQLite is separate and unrelated. Two databases, on two machines, with
an explicit copy between them.

## 7. How we would know it is finished

The tests are the specification, and the first one is the one that makes frames
worth having:

  * **Re-teaching a frame moves its points.** Teach a frame, teach three points
    in it, move the frame, and assert all three points move with it — and that a
    point in a different frame does not.
  * **A replayed point does not flip.** Teach a point at a pose reachable two
    ways, replay it, and assert the arm is in the joint solution it was taught
    in and not the mirror of it. This is the test that fails without the taught
    joint vector, and it is the one ABB's `confdata` exists for.
  * **An offset shifts the path by exactly the offset.** The vision case, without
    a camera: apply a known offset to a frame and assert every point in it moved
    by that much and no more.
  * **A program runs with nobody watching.** Start it, disconnect the only
    client, assert it completes. This is the property that distinguishes a stored
    program from a document and it cannot be tested by accident.
  * **A program is refused in manual, a jog is refused in auto.** Both directions,
    because an interlock tested in one direction is half an interlock.
  * **A blended two-line program does not stop at the corner.** Already true at
    the queue level; the test here is that a *program* preserves it, rather than
    inserting a stop between statements by accident.

## Order

1. **User frames.** Smallest, and everything else references them. Vision is the
   reason to do them first rather than last.
2. **Points**, with the frame reference and the taught joint solution.
3. **Program storage** — name, statements, HTTP upload, model nodes for state.
4. **Program execution** — the process that fills the queue, and the mode
   interlock in its second direction.
5. **Behaviours as statements**; G-code as an importer.
6. Branching, dynamic frames, frame hierarchy, the parallel logic context.

## Open questions

- **Text or tree.** KUKA and ABB store program *text* and parse it; Universal
  Robots stores a *tree* and renders it. A pendant edits through forms either
  way, so the question is what is authoritative on disk. Text diffs, reviews and
  greps; a tree cannot be syntactically invalid. This changes the storage schema
  and should be settled before the schema is written.
- **Points global or program-local.** Everyone ended up with both — FANUC's `P[]`
  against `PR[]`, Yaskawa's local against global position variables. Starting
  with program-local only is the smaller thing, and the migration to both is a
  nullable column.
- **What a taught point stores when the arm is at a singularity.** The joint
  vector is fine; the pose is the thing that stops being invertible. Probably
  nothing to do, but it should be tried before it is assumed.
- **Whether behaviours and programs unify** or stay two mechanisms that meet at a
  statement boundary. Unifying is elegant and might be wrong: a behaviour is a
  supervised FSM with fault classes, and a program is a sequence. Elegance has
  already cost this project a damping ladder.
