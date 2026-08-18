# The robot, and where its description lives

What a kinematic chain is on this controller, why it arrives as a URDF, and
what a URDF is deliberately not allowed to decide.

Written after finding the same arm described three times in one repository, in
three files that do not agree with each other. That is the problem this
document exists to close, and it is worth stating plainly before any design.

## Three descriptions of one arm

  * `apps/exmove/priv/arctos.urdf` — the real Arctos geometry, exported from
    CAD, parsed by a loader nothing on the controller path calls.
  * `ExMove.Library.demo/0` — invented proportions, in code, used by the
    controller and the Studio. Its own docstring says it "goes away when the
    URDF loader lands".
  * `ExMo.Schema.Registry.@arm_axes` — six axes with limits which, per the
    comment above them, "mirror the demo chain".

Three is worse than two. Two copies disagree loudly the first time somebody
edits one; three disagree in a pattern where the majority looks authoritative.
And the failure they produce is the quiet kind this suite keeps running into: a
tool centre point that reads plausibly and is wrong, because the forearm is
20 mm longer than the controller believes.

**One description. It is a URDF, and the controller stores it.**

## The document is the source, not a table

Frames and tools are rows, and that was right: they are authored on a pendant,
by a person, one at a time, and re-teaching one is the operation the table
exists for. A robot description is not authored that way. It comes out of CAD,
whole, and nobody re-teaches a link length on a pendant.

So the URDF **document** is stored, byte for byte, and the chain is derived
from it at boot. The argument is what happens to the parts we do not model yet.
A URDF carries visual meshes, collision geometry, inertia and materials; this
build models none of them and the Studio's viewport will want all of them.
Normalising to rows on import throws them away, and re-importing after we grow
the columns means asking the customer for a file they exported eighteen months
ago.

It goes in the controller database with everything else, for the reason
`PROGRAMS.md` §7 already gave: one file to back up, and `backup` is a declared
grant.

## The mechanism is not the machine

A URDF describes a mechanism. It does not describe an installation, and the
difference is where V1 draws its most useful line.

    URDF says                          commissioning says
    ─────────                          ──────────────────
    link lengths                       which drive is joint 3
    joint axes and origins             what the encoder counts per radian
    mechanical travel limits           the soft limit inside them
    the manufacturer's rated speed     what this machine may do in this cell
    joint names                        where home is

The right-hand column is per-installation, changes without the CAD changing,
and must never require editing a file that came from CAD — an integrator who
has to hand-edit a vendor's URDF to slow an axis down has been handed a
maintenance problem disguised as a configuration system.

So: a `joint_settings` table keyed by URDF joint name. This is also where the
`:joint_limits` block in `config/config.exs` finally belongs — it is currently
a fact about one machine living in a compiled release, which is the same
mistake in miniature.

Where the two disagree about travel, the tighter one wins, and the controller
says which one it took. A soft limit wider than the mechanism is not a
permission, it is a typo.

## Changing the robot is a restart

`@arm_axes` is what generates `axes.j1` … `axes.j6` in the Information Model.
If the chain is data then the number of axes is data, and the address space is
therefore a function of the stored URDF.

The model is compiled once at boot. So **loading a different robot takes a
controller restart**, and that is the rule rather than a limitation to be
apologised for:

  * teaching a frame is live, because a frame is a value inside a fixed shape;
  * loading a robot changes the shape, and a client holding subscriptions to
    `axes.j5` on a five-axis arm is holding a stale address space.

`warm_restart` is already a declared grant. The alternative — a dynamic address
space — is a real thing OPC UA can express and a large change to buy nothing
V1 needs.

## What V1 parses, and what it refuses

Supported: `revolute`, `continuous`, `prismatic` and `fixed` joints, with
`origin` (`xyz`, `rpy`), `axis`, and `limit` (`lower`, `upper`, `velocity`,
`effort`). One serial chain, from the root link to a named tip.

Refused, by name, with the offending element in the message:

  * **A branch.** Two joints with the same parent link is a tree, and this
    build solves a chain. Naming the link where it forks is the difference
    between a bug report and a support call.
  * **Multiple roots, or none.** A cycle is the second of these.
  * **`xacro` markup.** It is a macro language, not URDF. Run `xacro` first;
    the controller is not going to grow a macro expander.
  * **`mimic` joints.** A coupled axis is a real thing on real grippers, and
    pretending the joint is independent puts the arm somewhere else.
  * **An unknown joint type**, rather than treating it as fixed.

Ignored for now and deliberately not discarded — they stay in the stored
document: `visual`, `collision`, `inertial`, `material`, `transmission`,
`gazebo`. The Studio draws cylinders between joint origins today, so nothing
regresses by not reading meshes yet, and the file will still have them when it
does.

## Parsing

With `saxy`: pure Elixir, no NIF, cross-compiles to a Nerves target without
argument. The existing loader is regex-over-XML, which is defensible for a file
we wrote and a liability for one a customer exports — comments, namespace
prefixes, entities and attribute order are all things a CAD tool emits and a
regex mis-reads silently.

It also has a real defect worth recording, because it is the kind that passes
every test written against the file it was developed on: it ignores `parent`
and `child` entirely and takes chain order from the order joints appear in the
document. URDF makes no such guarantee. **The chain is built by walking the
tree from the root**, and the test for it is a fixture whose joints are
deliberately shuffled.

## How we would know it is right

  * **A shuffled URDF produces the same chain.** The test the current loader
    fails.
  * **Forward kinematics against a hand-computed pose**, on the real Arctos
    numbers rather than on invented ones.
  * **The Jacobian finite-difference test runs against the loaded chain.** It
    is the strongest correctness check in the suite and it costs nothing to
    point at a second chain.
  * **A branch is refused, naming the link.** Assert the message, not just the
    error — the message is the feature.
  * **A soft limit tighter than the mechanism stops the arm at the soft one**,
    and a soft limit wider than the mechanism is refused at commissioning
    rather than obeyed at speed.
  * **The three descriptions become one.** `Library.demo/0` survives only as a
    test fixture, and `@arm_axes` is derived from the loaded chain rather than
    declared beside it.

## Order

1. **The parser**, with the tree walk and the refusals. Pure, no storage.
2. **Storage** — the stored document, and `joint_settings` beside it.
3. **The cutover** — `ExMo.Cell.chain/0` from the store, `@arm_axes` derived,
   drives started from the loaded chain, `Library.demo/0` demoted to a fixture.
4. **Loading over the protocol.** A URDF is a document, not an argument, so it
   arrives over HTTP like a program body will and for the same reason: it does
   not belong in a JSON-RPC frame competing with a 30 Hz position stream. Until
   that exists, a mix task loads one and `cell.robot` reports which is loaded.

## Open questions

- **What a tool means on a chain whose tip is a URDF link.** Today the tool is
  a transform from the last joint's frame. A URDF may end in a flange link with
  its own origin, and "the flange" then has two candidate definitions.
- **Whether `joint_settings` should refuse a URDF that renames a joint.** An
  edited CAD export that renames `joint3` silently orphans its commissioning
  row, which is exactly the class of quiet failure this document opened with.
- **Prismatic axes are parsed and never tested.** The Arctos is all-revolute,
  so the first prismatic joint this build sees will be a customer's.
