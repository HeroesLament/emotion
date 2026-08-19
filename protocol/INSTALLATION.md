# The installation, the program, and the things that belong to one arm

This document decides what travels and what stays. It exists because the
obvious split — "programs move, everything else stays" — is one category short,
and the missing category is the one where getting it wrong is silent.

`PROGRAMS.md` §"The layering" already settled where the truth lives: **the
controller holds**, Studio keeps an offline copy, and the two are reconciled by
an explicit push or pull that a person asks for. This is the other half of that
sentence: *what*, exactly, is in each artifact.


## Three categories, not two

    ┌─ cell ──────────────┐  frames, tools
    │  where the fixture  │  portable to an identical cell
    │  is, what is on     │  frames, tools
    │  the flange         │
    └─────────────────────┘

    ┌─ robot model ───────┐  the chain, joint limits, home
    │  what kind of arm   │  portable to the same model of arm
    │  this is            │  robots, joint_settings
    └─────────────────────┘

    ┌─ this unit ─────────┐  mastering offsets, kinematic correction
    │  facts about one    │  NEVER portable — tied to a serial number
    │  serial number      │  masterings, and a gap
    └─────────────────────┘

    ┌─ program ───────────┐  statements and the points they name
    │  what this job      │  travels freely, that is the point
    │  does               │  programs, statements, statement_refs, points
    └─────────────────────┘

The first three are the **installation**. The fourth travels.

The line between the second and third is the one this document exists for. They
look alike — both are "robot stuff", both are configured at commissioning, both
are boring until they are wrong. But one describes a *model* of arm and the
other describes *this* arm, and copying the second between two arms of the same
model produces a machine that runs cleanly and works in the wrong place.

### "This unit" is at least two units

Added after a second pass over the vendors, because the first draft quietly
assumed a machine is one thing. It is not: **an arm and a control box are
separately swappable, and a per-unit fact belongs to one or the other.**

ABB puts its Absolute Accuracy compensation file in the *controller* and
markets exactly that as making robots exchangeable. UR puts its factory
kinematic calibration on the *arm*, and you extract it from there. Same
category of fact, opposite homes, and each vendor's failure mode follows from
which they chose.

For an Arctos this resolves in our favour and for a reason `MASTERING.md`
already gives: the MKS board is bolted to the joint, so the offset is "a
property of this board bolted to this motor bolted into this joint" and travels
with the arm. Nothing has to be done about it today. But the controller's
database is separate hardware from the arm, and a document that does not say so
is one migration away from someone restoring a control box and assuming the arm
came with it.


## Points travel with the program. This is not obvious and both vendors agree.

A point is job data, not cell data. KUKA pairs a `.dat` to every `.src` and
writes taught positions into it; UR puts waypoints in the `.urp`. Neither keeps
taught positions in the shared cell artifact.

The reasoning holds up on its own: a point is *where this job happens*, and two
programs in the same cell legitimately have different ideas about where they
work. Frames and tools are the opposite — they describe the room and the flange,
and every program in the cell is describing the same room.

`PROGRAMS.md` §3 left open whether points are program-local, global, or both,
noting that "every vendor ended up with both, which is a hint." The hint reads
clearly from here: **program-local by default, travelling with the program**,
with a way to promote one to cell-scope when several programs genuinely share
it. KUKA's `$CONFIG.DAT` is that promotion.


## The two verbs

An installation artifact carries two kinds of content and they need different
verbs, because they have different failure modes.

**Configuration — restore.** Frames, tools, joint settings, the chain. Restoring
is routine, and copying to a second identical cell is a real and useful thing to
do. A wrong value here tends to fault, or to be visibly wrong the first time
something moves.

**Per-unit facts — replace, deliberately.** Mastering offsets, and eventually
kinematic correction. Backing them up is valuable. *Restoring* them is a
hardware procedure: someone has changed a board and is telling the controller
what the old one knew. It is per-axis, grant-gated, and it is never part of
"restore this installation."

`MASTERING.md` states the consequence of getting this wrong more plainly than
this document could:

> A controller that pushed a stored offset back at boot would eventually push a
> stale one, and the failure is silent — every joint would still report a
> plausible angle, every move would still execute cleanly, and the work would
> land somewhere other than where it was taught. Nothing faults. You find out at
> the workpiece.

So `masterings` is in the installation *file* and is not in the installation
*restore*. That looks inconsistent and is not: a backup answers "what did this
arm know in March", which is exactly what a shadow is for, and `compare/3`
already exists to ask it. What a backup must not do is answer it by writing.


## Checked against the field, and corrected by it

This split was proposed with two categories and the vendors supplied the third.

**Universal Robots keeps per-unit calibration out of the installation
entirely.** Each robot is calibrated at the factory and the data is extracted
*from the robot*; the `.installation` holds TCPs, payload, mounting, safety,
environment coordinate systems and fieldbus, and not that. The ROS driver ships
a dedicated tool to pull it, because without the right one "end effector
positions might be off in the magnitude of centimeters".

The cost of UR's choice is that the fact is easy to lose. It lives on the robot,
it is not in the artifact anyone backs up, and recovering it needs a separate
tool that a person has to know exists.

**KUKA keeps it on the robot but reachable through the deployable project.**
Machine data — `$MACHINE.DAT`, `$ROBCOR.DAT` under `.../R1/MADA/` — holds
`$TRAFONAME[]` and `$ROBTRAFO[]`, the kinematic transformation, and is robot-type
specific. A mismatch gives position deviation errors and axis configuration
faults, and mastering becomes unreliable. It belongs to the physical robot, and
it is edited and redeployed through WorkVisual.

The cost of KUKA's choice has a forum thread named after it: **"Machine.dat
changes are reverted when project is changed and deployed (WorkVisual)."**
Someone corrects a robot-specific hardware fact on the machine; a routine
project deploy silently puts it back. That is the accident this document is
arranged to make unavailable.

So the arrangement here sits between them deliberately:

* unlike UR, per-unit facts are in the backup and legible, rather than hidden on
  the machine behind a tool you have to know about;
* unlike KUKA, no routine deploy or restore can touch them, because replacing
  one is a different verb with its own grant.


### A second pass, over three vendors

The three-category split survived. Two details did not.

**All three separate the encoder zero from the kinematic correction**, with
different data, a different procedure and a different tool for each. ABB
recalibrates resolver offsets with a Calibration Pendulum after maintenance,
while the Absolute Accuracy parameters arrive as a factory file for the
controller. FANUC keeps mastering in `$MASTER_COUNTS` and `sysmast.sv`, apart
from accuracy compensation. The two verbs above were arrived at independently
three times, which is about as much confirmation as a design decision gets.

**FANUC's field practice is this document, reached the other way round.** The
guidance for an arm swap is to restore *only* mastering data and never a full
controller image; `sysmast.sv` exists as a separate artifact for exactly that.
Restoring an image onto different hardware gives joint-angle mismatches and
SRVO-062/275 alarms. We got to "in the backup, not in the restore" by reasoning
about a silent failure. They got there by having it.

**And FANUC faults where we are silent, which is not inevitable.** Those alarms
fire because FANUC's absolute encoders carry identity — the encoder says which
one it is, so a mismatch is *detected* rather than inferred. "Nothing faults.
You find out at the workpiece" describes our situation, not the state of the
art. See the open items below: `servo-rs` already derives LSS serials from the
MCU UID, so binding a mastering record to a board identity would turn a swapped
board from something reasoned about into something reported.

## The artifacts

    .emp   a program        statements + the points they name
    .emi   an installation  cell + robot model + per-unit facts

Both are exports. **The controller's SQLite is the store**, and these are how a
copy of it leaves or arrives. UR loads its installation as a file because that
file *is* its store; ours is not, and pretending otherwise would produce two
copies that can disagree — the thing `PROGRAMS.md` §"The layering" pays a real
cost to avoid everywhere else.

Both are canonical JSON carrying a content hash of their printed form, per the
program bundle already built: a name is a label, the hash is the identity, and
two artifacts wearing the same name are told apart rather than reconciled.

**Accounts and tokens are not in either.** They live in the same database and
they are credentials, not configuration. An installation file is something a
person emails to a colleague.


## What falls out: the push rule

A program push installs statements and points, and **refuses if it names a frame
or tool the controller does not have**, naming the one it wanted.

That is not a safety rail bolted on; it is the categories doing their job. A
point is job data and installing one is what pushing a program means. A frame is
a claim about where a fixture physically sits, and a laptop asserting one it has
never measured is the same class of act as pushing a mastering offset — it
runs cleanly and lands in the wrong place.

The refusal is also the useful behaviour: it tells an operator the cell has not
been commissioned for this job yet, which is true and actionable, rather than
inventing a fixture at the origin.


## Not covered, and named so it is not designed out

* **Per-unit kinematic correction.** We have nowhere to put this arm's deviation
  from nominal. `robots` and `joint_settings` describe a model; UR's factory
  calibration and KUKA's `$ROBCOR.DAT` describe a unit. This compounds
  `PROGRAMS.md` gap 1 — the chain is `ExMove.Library.demo()`, compile-time, so
  "half the cell's geometry lives in a database and half lives in a release" —
  and the gap is larger than it first reads: it is not only that the chain is
  not a row, it is that there is no row for the *difference* between the
  nominal chain and this arm.

  **And the slot is not six numbers per joint.** ABB's Absolute Accuracy
  compensates "mechanical properties as well as deflection due to load (adopts
  to tool data)" — the correction takes the fitted tool as an input, because an
  arm holding a welder at full reach sags. Designing this as a static per-joint
  transform would design out the half that matters at the end of a long arm,
  and it would be discovered by a weld that is right near the base and wrong at
  the far corner of the fixture.

  For a printed Arctos this may stay theoretical: part tolerance plausibly
  swamps a geometric term, and there is no metrology to measure one with. The
  slot should exist anyway, shaped to take a load as well as a pose. A machine
  that later gets measured should not need a migration to record the result.

* **Board identity, so a swap is reported rather than inferred.** `compare/3`
  can tell that an axis's number changed; it cannot tell *why*. FANUC's
  encoders carry identity and their controller raises SRVO-062/275 on a
  mismatch, which is why a swapped arm alarms there and would be silent here.

  `servo-rs` already derives LSS serials from the MCU UID, so the identity
  exists and is not read. Recording it alongside the offset would turn
  `{:changed, axis, was, now}` into `{:board_swapped, axis, was_serial,
  now_serial}` — a different finding wanting a different response, and the one
  case where `restore_mastering` is the correct next action rather than a
  question. Cross-repo: the drive has to report it before the controller can
  store it.

* **Multi-robot cells.** One installation per controller is assumed throughout.
  A controller aggregating several arms has one cell and several units, which
  the three categories already anticipate but nothing here has been tested
  against.


## How we would know it is right

* **A program push into an uncommissioned cell is refused by name.** Push a
  program naming `fixture_a` at a controller that has no such frame, and get
  back which frame was missing rather than a program that runs to the wrong
  place.
* **An installation restore does not change any drive's zero.** Restore a
  backup onto a controller whose masterings differ, and assert the drives'
  offsets are untouched and the difference is *reported*.
* **A backup taken in March answers a question asked in June.** Compare a dated
  installation against the live controller and get the same three answers
  `ExStore.Masterings.compare/3` gives — changed, lost, new — for an axis that
  was re-mastered in between.
* **Two arms of the same model can share a cell and a robot model and nothing
  else.** Export from one, import to the other, and assert frames, tools and
  joint settings arrived and mastering did not.
* **A restore onto an arm that already knows its zero is refused.** Not
  "discouraged" and not "logged": refused, so the stale push cannot be
  performed by someone who has not read this document.

## What has since been built

Recorded here rather than left implied, so the open list above stays a list of
things that are actually open.

* `cell.installation` — the whole snapshot in one read, behind `backup`, and
  `.emi` as its file. One call rather than four, because five round trips can
  straddle a change and a fingerprint over that is worse than none.
* Import — `plan/2` before `install/2`, frames before tools before joints,
  parents before children. Mastering and the robot description skipped **with
  reasons carried**, because a skip an operator cannot see is a skip they will
  assume did not happen.
* `cell.define_point` — a point that arrived from a file, marked `defined`
  rather than `taught`, with the joint vector required and never solved for.
* The program push, refusing whole when the cell lacks a frame or tool it
  names.
* `cell.restore_mastering` — per axis, behind `restore`, and refused unless the
  axis is unmastered. That last clause is what makes the failure this document
  is about unreachable rather than merely documented.
