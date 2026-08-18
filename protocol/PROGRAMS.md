# Programs, points, frames and tools

What a stored program is, what a taught point is, why frames come first, what
makes a tool swappable, and where code is allowed to live.

Written before any of it exists, because the last document in this directory was
written the same way and its first two sections turned out to be wrong in ways a
single measurement would have caught. So this one leans on evidence where
evidence is available — four vendors who have each shipped this for thirty years
— and marks the rest as guesses to be checked rather than decisions to be
defended.

## Two ideas

**Everything that makes a taught path adapt at runtime is a frame.**

Vision finding a part, a conveyor carrying one past, a fixture that was bumped
and re-taught, a force search that locates a surface — all four are the same
operation. Compute a frame, apply it to a path that was taught once and never
edited again. That is why frames come first, and why they are not a convenience
for teaching. They are the extension point everything interesting hangs off.

**A program is data. Code extends the vocabulary that data is written in.**

Not "programs are written in a language". A program is a sequence of validated
records, every one of which the controller can check before it runs and refuse
before it moves. Code — real Elixir, compiled and deployed — adds new kinds of
record. It never becomes the body of one.

Those two ideas carry the whole document. Everything below is consequence.

## What the incumbents actually do

Not a survey. Patterns that FANUC, ABB, KUKA and Yaskawa arrived at
independently, which is the strongest available evidence that they are properties
of the problem rather than of a vendor.

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

**The graphical vocabulary is extended by code, not replaced by it.** ABB's
Wizard is drag-and-drop blocks with a standard palette, and *"for situations
where highly specialized blocks are required, experts can easily create custom
blocks with the Skill Creator"*. A URCap contributes **program nodes** that
appear in the tree beside the built-in ones. Two vendors, two decades apart,
same answer: the escape hatch produces new vocabulary.

And one that only ABB makes explicit, which is the most immediately useful:

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
    block editor (primary)          frames        ← authoritative
    teaching (secondary)            tools         ← authoritative
                                    points        ← authoritative
    text export (third)             programs      ← authoritative
    extension SDK ───deploy──────►  extensions    ← authoritative
    a cached copy ───push/pull───►  execution
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
  * `user` — named, stored, re-teachable. Done: rows in the controller's
    database, resolved through `ExMo.Cell`, and refused rather than silently
    treated as base when the name is not there.

A frame is six numbers and a name, which made this the smallest piece of work in
this document and the one the rest of it needs. Built: the table, the resolver,
the `frame` argument on every Cartesian motion, and the projection — `cell` in
the Information Model, with `teach_frame`, `forget_frame` and `list_frames`
behind `write_configuration`.

The projection is **not** a node per frame, and the reason is worth recording
because the earlier draft of this section assumed one. A model node per stored
row means the address space changes shape when somebody teaches a fixture. OPC
UA can express that; this build's model is compiled once at boot and cannot,
and making it dynamic to publish six numbers would be a large change bought
cheaply nowhere else. So listing is a method that returns rows, and the node
tree stays a fact about the build rather than about the database. The one node
that *is* published is `cell.tool`, because what is fitted is machine state
rather than a row somebody might add.

Re-teaching a frame must move every point that references it and nothing else.
That single property is what makes frames worth having, and it is the first
test — asserted against poses expressed in the frame, since points do not exist
yet, which is the same claim one layer down.

Not in scope here, and named so they are not accidentally designed out:

  * **Dynamic frames** — a frame whose value is written at runtime by vision or
    by a conveyor encoder. Same storage, different lifecycle, and the grant is
    different too: teaching a frame is configuration, updating one at line rate
    is not.
  * ~~**Frame hierarchy**~~ — built after all, because it was cheaper now than
    the migration would have been later: `parent_id` is resolved, cycles are
    refused at write, and there is a depth cap for rows this suite did not
    write.

## 2. Tools, and swappable EOATs

A tool is six numbers and a name, exactly as a frame is — the transform from the
last link's flange to the tool centre point. Structurally it is the same table
with a different meaning, and the temptation to unify them should be resisted:
they are looked up by different questions, they are re-taught by different
procedures, and a point references one of each.

The tool *was* a **field on `ExMove.Chain`**, plumbed through to the NIF as
`tool: (f64,f64,f64,f64,f64,f64)`. That was compile-time geometry. It is a row
now, and the moment it became one the concept the arm had been missing fell out:
**the fitted tool is machine state, not a constant.** Fitting one on a running
controller moves the reported tool centre point without the arm moving, which is
the whole claim in one observation.

That is what makes an end-of-arm tool swappable, and the general programming
consequences are worth naming now even though nothing at the effector is being
designed yet:

  * **A taught point knows which tool was fitted.** This is not optional and it
    is not an optimisation. FANUC records `UTOOL` alongside `UFRAME` with every
    taught position for exactly one reason: a pose taught with one tool fitted
    does not describe the same physical location with another. A point stored
    without its tool is a point that silently means something else after a
    changeover. `tool_id` is therefore as mandatory on a point as `frame_id`.
  * **Something selects the fitted tool.** A statement kind — `set_tool` — and a
    program-level default, in the same way a frame is selected. Selection is
    state that outlives the statement, which means it is also state a program
    must not inherit accidentally from whatever ran before it.
  * **A mismatch is detectable, and detected early.** Replaying a point taught
    with tool A while tool B is fitted is the failure this model exists to catch.
    Because both are rows with real foreign keys, the check is a comparison, and
    it belongs where the statement is *stored* and again where it is *reached* —
    the first catches authoring, the second catches a changeover nobody told the
    controller about.
  * **The Cartesian limits already follow the tool.** `CARTESIAN.md`'s 250 mm/s
    cap is a cap on TCP speed, and TCP is a function of the fitted tool. Swapping
    to a longer tool changes the achievable joint rates for the same tool speed
    with no other change in the program. This is not new work — the Jacobian
    already takes the tool — but it is the reason the fitted tool must be known
    to the *stream*, not only to the program.

Deliberately not in scope, and named so they are not designed out: tool mass and
inertia (needed for payload and for collaborative force limits), tool I/O and its
signal namespace, a tool changer as a commanded device, and tool-frame hierarchy
for a multi-station effector. All of them are additional columns or additional
tables on a `tools` row that exists; none of them are possible without it.

## 3. Points

A taught point is **a pose, the frame it was taught in, the tool that was
fitted, and the joint solution the arm was actually in**.

The fourth of those is where we can do better than the incumbents rather than
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

## 4. Programs: three layers

The authoring order is decided: **Studio blocks first, teaching second, text
third.** Everything in this section follows from that, and from the second of
the two ideas at the top.

### Layer 1 — blocks, which are the program

A program is a sequence of **statements**, and a statement is a record: a kind,
and typed arguments. Drag-and-drop editing is the primary way they are authored,
which settles a question this document previously left open — you cannot
drag-and-drop text, so the structure is authoritative and any text form is a
rendering of it. See §8.

The starting kinds, deliberately few:

    move_joint    point, speed, termination
    move_linear   point, feedrate, termination
    move_arc      via, point, feedrate, termination
    wait          seconds | until a signal
    set           an output
    call          another program

Every motion statement carries its own feedrate and termination, which maps onto
the queue that exists today without changing it. FINE and blended termination are
already built and already tested; a program is a thing that fills the queue.

**Arguments are typed, and the types are the point.** A point socket accepts only
a point; a frame socket only a frame; a duration only a duration. That one
decision buys three things at once: the block editor knows what may be dropped
where, the database can hold foreign keys and refuse to delete a frame a program
uses, and a statement can be validated when it is stored rather than when the arm
is already moving.

Branching — labels, jumps, conditionals — comes after. It is the difference
between a sequence and a language, and the sequence is worth having on its own.
Note that until branching lands a program is a **list**, not a tree, which makes
the first increment considerably smaller than "structured editor" suggests.

### Layer 2 — expressions, which are small and cannot bite

Some arguments want a little logic: `count < 10`, `part_present and not fault`.
That is real and it should be supported, and it should not be Elixir.

A small pure expression language — comparisons, arithmetic, boolean operators,
references to signals and variables — evaluated with no side effects, no process
spawning, no filesystem, and no way to reach a drive. Spreadsheet-formula-shaped.
It covers most of what people reach for code for, and it cannot take the machine
down, which is the entire reason it is a separate layer rather than "just let
them write Elixir here".

### Layer 3 — extensions, which are real Elixir and contribute blocks

Compiled Elixir modules that register **new statement kinds**. `ExMo.Behavior` is
already this, one rename away: a definition with a name, typed inputs, observable
runtime fields and named fault classes is exactly a block's signature.

A `PickWithVision` block, a `TorqueSeek` block, the K1C unload — each is an
extension publishing a typed signature, and each appears in the palette beside
`MoveL`. This is what ABB's Skill Creator and Universal Robots' URCaps both do,
and it is why the two authoring stories in this project are not in competition:
**blocks are the vocabulary, and Elixir is how you add words to it.**

Extensions are deployed, not edited. They are compiled, versioned, and installed
the way firmware is — not hot-edited on a machine that is running. The grant for
doing so is an open question below; it is closer to `warm_restart` than to
`edit_program`.

### Why a program body must never be Elixir

Stated plainly because the pull toward it is strong and the cost is not obvious.

Arbitrary Elixir running on the controller can call
`Exdrive.Drive.set_target_velocity/2` directly. One line. That bypasses the joint
rate ceiling, the joint-limit stop, the tool speed cap, the singularity refusal,
the mode interlock and the hold watchdog — every guard in `CARTESIAN.md`, all of
which exist because motion arrives through the queue and nowhere else.

There is no sandbox on the BEAM. A program body would have `File`,
`:erlang.halt/0`, process spawning, ETS, and a scheduler shared with a 200 Hz
Cartesian stream. And the argument is not about malice: it is that a *bug* in a
program becomes a runtime fault rather than a refused command, which is the exact
inversion of what a controller is for.

The three layers exist so that the answer to "I need to do something the blocks
cannot express" is *add a block*, and the code that adds it is reviewed,
compiled, and deployed rather than typed into a running machine.

### The statement-kind registry

The consequence of layer 3 that has to exist on day one: statement kinds are
**registered**, with a name, typed parameters, and whatever a block editor needs
to render them. Built-in kinds register through the same door extensions use.

Building the registry later, once six kinds are hard-coded across a projection, a
source, an executor and an editor, is the expensive version of this. Building it
first, when every entry in it is built in, costs almost nothing.

### Mode gets its second job

`ExProto.Mode` currently answers one question: jogging is manual-only. Programs
are the other half, and it is the same interlock rather than a new one.

    manual   jog permitted        program refused
    auto     jog refused          program permitted

Which is how all four vendors work, and it is why the mode enum already reads
`idle | manual | auto | fault`. The grant vocabulary anticipated this too:
`execute_program`, `load_program` and `edit_program` have been in
`ExAuth.Grant` since it was written, unused.

### Program bodies are not on the RPC link

`README.md` in this directory already decided this: *"Bulk transfer — program
source, logs, motion traces — is not on this link. It is plain HTTP on the same
host so it stays curl-able and does not compete with live telemetry."*

So the model carries what a pendant renders — a program's name, its state, the
statement it is on, its fault — and the body itself is uploaded and downloaded
over HTTP as a canonical serialisation. A program of a thousand statements does
not belong in a JSON-RPC frame competing with a 30 Hz position stream.

## 5. Execution

A program that cannot run is a document. This section is the engine, and it is
mostly a set of decisions about *when* things happen rather than about how.

### The two pointers, and why V1 has one and a half

To blend one move into the next the queue has to be fed before the arm arrives,
which means the interpreter runs ahead of the machine. The instant it does there
are two positions in a program — where the interpreter is and where the arm is —
and a `wait` executed at the interpreter's position happens *before the arm gets
to the line above it*.

Every vendor met this and each exposed it: KUKA has an advance-run pointer and
`$ADVANCE` to bound it, FANUC documents which instructions stop look-ahead, ABB
drains the queue at particular statements. It is not an implementation detail —
"when does this line actually happen" is a semantic every program ever written
against the controller depends on, which makes it the most expensive thing in
this document to change later.

**V1: motion statements look ahead, everything else is a barrier.** The executor
keeps a bounded number of motion statements in the queue, so blending works
between consecutive moves exactly as `CARTESIAN.md` built it. Any statement that
is not motion — `wait` now, `set` and branching later — stops the interpreter
until the arm has caught up and the queue is empty.

That buys the property people actually expect: blending happens between moves and
nowhere surprising, and `wait 2 seconds` means the arm stands still for two
seconds rather than two seconds beginning somewhere earlier. The full two-pointer
model stays available later; going the other way — quietly making every
non-motion statement's timing something the programmer must reason about — would
break programs that already exist.

### One run, and it is a process

One program runs at a time. Not a limitation to be lifted casually: a second
concurrent program means two things commanding one arm, and the honest version of
that is coordinated motion across motion groups, which this build does not have.
A second `start` is refused while one is running rather than queued.

A run is a supervised process, and its death is a stop. The stream is released on
the way out, which commands zero on every joint — the same path a dropped client
takes, tested since the jog watchdog landed. A program that crashes must not
leave an arm moving, and on the BEAM that is a `terminate` rather than a promise.

**Nothing about a run depends on a client.** That is the property that separates
a controller from a document, and it is worth one test of its own: start a
program, disconnect the only client, and assert it finishes.

### The states, and what moves between them

    idle      no run
    running   the interpreter is advancing
    held      stopped where it was, resumable
    faulted   a statement was refused; stopped, not resumable
    done      the last statement completed

`hold` stops the arm immediately by releasing the stream. `resume` **re-issues
the statement the run was on, from wherever the arm is standing** — which for a
linear move is exactly the remainder of the original line, because resolved-rate
motion is differential and the target is absolute. It is not exact for an arc: the
via point may be behind the arm, and a circle recomputed through a via already
passed is a different path. So **resume during an arc is refused**, naming the
statement, and the operator restarts it. Fast where it can be exact, loud where it
cannot.

`stop` abandons the run. There is no resume from a stop; the next run starts at
the top, or at a statement somebody chose.

`step` runs exactly one statement and returns to `held`. Every pendant has it and
it costs nothing here, because the interpreter is already a state machine driven
one statement at a time.

A statement that is refused — a singularity, a joint limit, an unreachable point —
**faults the run and stops**. It does not skip and it does not retry. The refusal
the queue already produces is the reason the run stopped, and it is published as
such rather than translated.

### The mode interlock, in its second direction

Already stated in §4 and repeated here because this is the half that enforces it:
a program is refused in manual, exactly as a jog is refused in auto. Turning the
selector out of auto while a program is running **stops the program**, in the same
way it already releases every jog hold.

### The tool a point was taught with

Decided, having been left open when points landed: **a move to a point taught
with a tool other than the one fitted is refused**, and the refusal names both
tools. A statement may carry an explicit opt-in for the cases where somebody
genuinely means it — a probe that works with anything bolted on.

Recomputing the pose through the fitted tool was the alternative and it is the
more dangerous kind of convenient: it drives the arm at a location it was never
taught to reach with that tool, and the first time a longer tool cannot get there
the same way, it will try. Refusing is annoying exactly once per changeover
nobody told the controller about, and the annoyance is the feature.

### What a pendant can see

The run publishes, as ordinary model nodes: its program, its state, the index of
the statement it is on, the reason it faulted, and the number of statements. That
is what a pendant highlights a line with, and it is subscribable like everything
else, so a client watching a program run receives the line changing rather than
polling for it.

The program *body* stays off the RPC link, per §4.

## 6. The parallel logic context

Every incumbent has one. We should not build a ladder editor, and we should not
assume the motion program owns the machine either — because that assumption is
the one that is expensive to undo.

On the BEAM this is the easiest thing in the document to get right and the
easiest to get wrong by not thinking about it. A supervised process that watches
signals and reacts is not a feature to build, it is what the runtime already is.
What matters now is only that the program model does not assume it is the sole
executing context: nothing may claim the arm implicitly, and holds stay the way
motion is claimed.

## 7. G-code is an importer

G-code is the CAM lineage: it streams coordinates, with no named points, no
frames, no per-line termination and no logic. Every vendor supports it as an
import path and none uses it as the native model.

`ExGCode` exists, is 299 lines, and has no tests. What it needs is to produce a
*program* — statements over generated points — rather than a stream of
`%Frame{}`, because a stream of frames goes around the queue and therefore around
every limit and every report that `CARTESIAN.md` spent its length establishing.

Behaviours are not in this section any more. They are layer 3 of §4.

## 8. Storage, and the text question resolved

**One controller database.** Frames, tools, points, programs and registered
extensions join accounts and tokens in the existing repo. One file to back up — and `backup`
is already a declared grant — one migration path, one thing to get right on a
Nerves image. `ExAuth.Repo` then outgrows its name and should be renamed the
moment the first non-credential table lands, not two months later at a hundred
call sites.

Statements are **rows**, not a blob: `(program_id, seq, kind, args)` with foreign
keys to points and frames. Typed sockets make those keys real, which is what
allows the database itself to refuse to delete a frame a program still uses.

### The schema

    frames          id, name, parent_id?, x y z rx ry rz, mutable
    tools           id, name, x y z rx ry rz
    points          id, name, program_id?, frame_id, tool_id, pose[6], joints[6],
                    mutable
    programs        id, name
    statements      id, program_id, parent_id?, seq, kind, args_json
    statement_refs  statement_id, arg_name, → points | frames | tools | programs
    extensions      id, name, version, module

Seven tables, and every one of them is a decision that was argued for above
rather than a shape that fell out of an ORM:

  * **`id` for identity, `seq` for order.** Renumbering a program must not
    invalidate a jump, which is precisely what FANUC's `JMP LBL[]` — a label, not
    a line number — exists to avoid. Inserting a statement rewrites `seq`; it
    never touches an `id`.
  * **Literals in `args_json`, references in `statement_refs`.** A feedrate is a
    number and belongs in the row. A point is an entity, and putting its id in
    JSON makes the foreign key a comment. Splitting them is what turns "refuse to
    delete a frame a program uses" from a policy into a constraint.
  * **`kind` is a validated string, not an enum.** Validated against the live
    registry (§4), so a program that references an extension whose module is not
    loaded still *loads*, and names the kind it is missing. An enum in a
    migration would make every extension a schema change.
  * **`parent_id` on statements is nullable and unused today.** Nesting is
    deferred, not designed out; adding the column later means migrating every
    program that exists.
  * **`mutable` on frames and points**, because the real axis is not private
    against shared — it is **taught-constant against runtime-mutable**, which is
    what FANUC's `P[]`/`PR[]` split actually encodes. A vision offset writes a
    mutable frame; a taught fixture origin is not writable at line rate by
    anything. The grant follows the column.
  * **`program_id` nullable on points** is the global/local question left open
    above, resolved as a column rather than as two tables.

Argument types carry **physical dimension**, not just primitive type:
`:velocity`, `:length`, `:angle`, `:duration`, `:point`, `:frame`, `:tool`,
`:signal`. A block editor that knows a socket wants a velocity can offer units;
one that knows it wants a `:tool` can offer the fitted one first.

### What this schema does not yet answer

Four gaps, recorded rather than discovered later:

  1. **The robot itself has no data model.** `ExMove.Library.demo()` is hardcoded
     and there is no URDF loader. This is the one that bites immediately: if the
     chain is compile-time and frames are rows, half the cell's geometry lives in
     a database and half lives in a release, and re-teaching a tool becomes a
     deploy. Doing tools as rows forces this question rather than deferring it.
  2. **No signals.** `wait until` and `set` both need a named I/O namespace, and
     `statement_refs` already has a column pointing at a table that does not
     exist.
  3. **No variables.** Counters and part indices are the first thing anyone asks
     for after motion works, and they are also the doorway the expression
     language walks through.
  4. **Point scope and mutability**, resolved above as columns, but untested —
     the migration is cheap and the semantics are not.

### Why structure is authoritative and text is a rendering

Blocks force it — you cannot drag-and-drop text. But the vendors' experience says
the same thing from a different direction, and it is worth recording because both
of the obvious answers have shipped and both are lossy **in the same place**.

KUKA's inline forms generate KRL, and the parameters needed to *reopen the form*
are stored as comment metadata after a `;FOLD` marker. The compiler ignores them;
the pendant reads them. Remove the comment and the program still runs but can no
longer be edited on the pendant. That is a structured record smuggled into a
comment because the text alone cannot round-trip the editor.

Universal Robots goes the other way: `.urp` is the editable format, and the
`.script` text export *has no waypoints* — the taught positions cannot be edited
from it.

Both lose the same thing: the taught data and the editor's own metadata. Both
tried to make one artifact carry logic and data, and that seam is where the loss
lands. KUKA's own `.src`/`.dat` split is the fix, applied inconsistently.

Keeping points, frames and statement arguments in their own tables means the
"body" is only the sequence, which is small and renders losslessly. And the
directions are not symmetric: rendering structure to text is **total** and always
succeeds, while parsing text to structure is **partial** and can fail. So:

  * **Write the printer now.** It is cheap, it cannot fail, and it buys `git
    diff` over a cell's programs, curl-able export, and reviewable change.
  * **Defer the parser** until somebody actually wants to author in a text
    editor. That is the expensive, breakable half and it blocks nothing.

Migration runs the same way round. Structure to text later is a printer over the
whole corpus and cannot fail; text to structure later is a parser over programs
people have hand-edited for years, some of which will not parse.

## 9. Studio

**Blocks are day one and primary.** A block editor is a tree editor, which is
what a widget toolkit is good at, and Cedar exists.

**Teaching is second.** Drive the arm, record a point: pose, active frame, and
the joint vector. Cobot-style hand guiding is the same operation with a different
input device.

**Text is third and is an export**, per §8.

**The Elixir SDK is a build-and-deploy loop, not a text editor.** Studio
scaffolds an extension project, builds it, deploys it to a controller, runs it
against the simulator and shows the result. You edit in your own editor.

This is a deliberate scoping decision rather than a limitation, and it is worth
the paragraph. A text editor widget with completion, diagnostics, hover and
selection is plausibly more UI work than the entire block editor, and it competes
with editors that are free and better at it. Expert — the official Elixir
language server, which absorbed ElixirLS, Lexical and Next LS — is also still
working toward its first release, so embedding it now means tracking a moving
target. URCap development works exactly this way: the IDE is yours, the loop is
the vendor's.

If an in-app editor is wanted later, it is for **extensions only, never for
programs**, and it comes after blocks. It is an IDE feature that happens to live
in a robot tool and should be scheduled as one.

## 10. How we would know it is finished

The tests are the specification, and the first one is the one that makes frames
worth having:

  * **Re-teaching a frame moves its points.** Teach a frame, teach three points
    in it, move the frame, and assert all three points move with it — and that a
    point in a different frame does not.
  * **A replayed point does not flip.** Teach a point at a pose reachable two
    ways, replay it, and assert the arm is in the joint solution it was taught
    in and not the mirror of it. This is the test that fails without the taught
    joint vector, and it is the one ABB's `confdata` exists for.
  * **Re-teaching a tool moves its points too, and only in the tool's own
    direction.** The frame test's mirror image, and the one that proves a tool is
    a transform rather than a label.
  * **A point taught with one tool is refused, or corrected, under another.**
    Whichever we choose, it must not be *ignored*. This is the swappable-EOAT
    test and the reason `tool_id` is on every point.
  * **An offset shifts the path by exactly the offset.** The vision case, without
    a camera: apply a known offset to a frame and assert every point in it moved
    by that much and no more.
  * **A program runs with nobody watching.** Start it, disconnect the only
    client, assert it completes. This is the property that distinguishes a stored
    program from a document and it cannot be tested by accident.
  * **A held program resumes on the line it was on**, and finishes where it would
    have. The linear case, where re-issuing is exact.
  * **Resume during an arc is refused**, naming the statement, rather than
    silently drawing a different circle.
  * **A `wait` waits where the program says it does.** Two moves either side of a
    `wait 1 second`, and the arm is standing on the first move's end point for
    that second — the assertion that the look-ahead barrier is real.
  * **A run that crashes leaves an arm that is not moving.** Kill the process
    mid-move and assert every joint is commanded zero.
  * **A program is refused in manual, a jog is refused in auto.** Both directions,
    because an interlock tested in one direction is half an interlock.
  * **A blended two-line program does not stop at the corner.** Already true at
    the queue level; the test here is that a *program* preserves it, rather than
    inserting a stop between statements by accident.
  * **A statement with the wrong argument type is refused when stored**, not when
    reached. Typed sockets are only worth having if the refusal is early.
  * **An extension's block is indistinguishable from a built-in one** — same
    registration, same validation, same execution path, same reporting. If the
    built-ins get a shortcut, extensions are second-class and the vocabulary
    stops being extensible in practice.

## Order

1. ~~**User frames.**~~ Done, with parents. Smallest, and everything else
   references them; vision is the reason they came first rather than last.
2. ~~**Tools**~~, in the same stroke: the same six numbers, and the chain's
   compile-time `tool` field moved into a row the stream reads. Both landed in
   the controller's database, which is `exstore` now rather than `exauth`.
   Both are on the protocol, under `cell`.
3. **Points**, with the frame reference, the tool reference and the taught joint
   solution.
4. **The statement-kind registry**, with the built-in kinds registered through
   it. Cheap now, expensive later.
5. **Program storage** — statements as rows, HTTP body transfer, model nodes for
   state. The printer lands here.
6. **Program execution** — the process that fills the queue, and the mode
   interlock in its second direction.
7. **Blocks in Studio**, against the registry.
8. **Extensions**: behaviours re-homed as registered statement kinds, and the
   deploy loop.
9. Expressions, branching, G-code import, dynamic frames, frame hierarchy, the
   parallel logic context, signals and variables.

## Open questions

- **Where the arm's own geometry lives**, which the `tools` table forces. Gap 1
  in §8 and the largest thing still unanswered in this document.
- **What happens when a point is replayed under the wrong tool** — refuse, or
  recompute the pose through the new tool and go there. Refusing is safe and
  annoying; recomputing is convenient and can move the arm somewhere nobody
  taught. Probably refuse by default with an explicit statement-level opt-in.
- **What grant deploys an extension.** It installs code that runs in the
  controller's VM, which is closer to firmware than to `edit_program`. Probably
  its own grant, granted alone, in the way `configure_safety` already is.
- **How far the expression language goes** before it becomes a language nobody
  meant to design. Comparisons and arithmetic are clearly in; function calls and
  user-defined variables are the edge.
- **What a taught point stores when the arm is at a singularity.** The joint
  vector is fine; the pose is the thing that stops being invertible. Probably
  nothing to do, but it should be tried before it is assumed.
- **Whether an extension can be written in the expression language** rather than
  Elixir, for the common case of a block that is just a parameterised sequence of
  other blocks. That would be a macro rather than an extension, and it might be
  the most useful thing in this document. It is also the easiest to get wrong.
