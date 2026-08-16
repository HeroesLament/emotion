# Cartesian motion

What "finished" looks like, and why the pieces sit where they do.

Written after shipping a Cartesian jog that moved the arm in the wrong
direction, so the reasoning here is mostly a record of what that cost.

## The layering

Three places, and the line between them is not "planning versus execution" —
it is **whether the machine moves**.

`ExMove` is the solver. Pure kinematics: a Jacobian, a damped pseudo-inverse,
forward kinematics, path generation. No processes, no clock, no policy. Both
sides link it, neither side calls it as a service.

The **controller** owns everything that moves the arm: the servo clock, the
frames, the joint limits, the singularity policy, the speed limit. Not because
it is the natural home for maths, but because those are the things that must
refuse, and a refusal has to come from whoever owns the drives.

**Studio** previews. Dragging a gizmo, editing a program, shading reachability,
simulating a path — all local, all at 60fps, none of it touching the machine.
What it commits is a *command*, not the sixty intermediate solutions it drew on
the way. Preview locally, commit remotely.

The tempting shortcut is Studio solving IK and sending joint setpoints. It is
wrong four ways: six joints means six holds and six deadlines, so one lapsing
stops one joint and leaves five running; joint targets computed across a
network are a staircase the arm chases; near a singularity the rates blow up
and the refusal has to come from whoever owns the limits; and TOOL and USER
frames are machine configuration, so a Studio solving in a frame the controller
does not share is the classic wrong-place bug. Underneath all of it, the same
command from a pendant, from Studio and from a stored program has to move the
arm identically, which it cannot if only one of the three has a solver.

## 1. The interpolator

This section previously said the 175mm we measured was chord error and that a
faster interpolator would fix it. That was wrong, and how it was wrong is worth
keeping.

**What it actually was.** The Jacobian was built with every column pivoting
about the previous joint's origin — one link too long on every lever arm. The
joint rates it produced satisfied that Jacobian exactly, and moved the arm at
0.175 m/s mostly sideways when 0.05 m/s in Z was asked for. Fixed in
`e177d76`, with the check that was missing: every column against a finite
difference of `FK.solve/2`.

The cheap discriminator, and the thing to reach for first next time: **run the
same motion at several rates.** Chord error falls off with dt. A defect that
reports 178.89mm at 10 Hz and 178.89mm at 1000 Hz is not an integration error,
and one sweep would have said so before any of the reasoning above it was
written. Rate invariance is a fingerprint.

**What chord error actually costs**, measured after the fix, jogging +Z for two
seconds from a bent pose and taking the worst lateral deviation:

    rate     0.05 m/s (jog)    0.25 m/s (ISO manual max)
    10 Hz          0.346mm                      12.63mm
    20 Hz          0.173mm                       6.69mm
    50 Hz          0.069mm                       2.82mm
    100 Hz         0.035mm                       1.44mm
    200 Hz         0.017mm                       0.73mm

First order in dt, as expected, and roughly quadratic in speed — a chord's sagitta
goes as the square of its length. At jog speed the client's 10 Hz is already
inside the millimetre this document sets as the bar. At the speed the machine is
actually allowed to run in manual, it is twelve times outside it.

So the stream still earns its place, and 200 Hz still looks right — but for the
speed at the top of the range rather than the one at the bottom, and that is the
number to design to. Each `solve_velocity` costs 36.6µs measured, so 200 Hz is
under 1% of a core per arm; the rate is not the constraint anyone thought it
might be.

The rest of the case for a stream never depended on the arithmetic at all, and
is the stronger half:

  * The watchdog should guard the hold and nothing else. A client's assertion
    rate is a fact about the network; the interpolation rate is a fact about the
    machine, and one should not be reading the other's value.
  * Everything in sections 2, 4 and 6 — damping, joint-limit stops, the tool
    speed limit — has to be evaluated on a clock the controller owns. There is
    currently no such clock, which is why none of them exist.

**Finished:** a `CartesianStream` process per arm. An assertion *refreshes the
intent* — frame, direction, speed — and nothing else. The stream re-solves from
the live joint pose at its own rate and writes joint velocity setpoints.

It goes in `exmove`, not `exdrive`: `exmove` already depends on `exdrive`
(`ExMove.Robot`, `ExMove.IpStream` and `ExMove.PathExecutor` all write setpoints
through `Exdrive.Drive`), so a `Exdrive.CartesianStream` needing the solver would
close a cycle. `ExMove.IpStream` is the shape to copy and is one directory away.

The stream stops on an explicit zero, on the hold lapsing, or on its own death.
The watchdog is unchanged: it still guards the hold, it just stops doubling as
the interpolator.

## 2. Singularity policy — measured, and not what this section first said

The plan here was three tiers: detect on manipulability, damp with a variable λ,
refuse below a κ floor. Two of the three did not survive contact with the arm.
Done in `3b59796`; what follows is what is actually there and why.

**Manipulability cannot tell you whether a command is hard.** Measured on the
demo chain, commanding 0.05 m/s in +Z:

    approaching full extension        approaching the wrist singularity
    j3       w          peak dq       j5      w          peak dq
    -0.4     0.0159     0.22          0.3     0.0012     0.0721
    -0.1     0.0057     1.19          0.05    0.0002     0.0721
    -0.02    0.0012     6.33          0.01    0.00004    0.0721
    -0.001   0.00006  128.49          0.0     0.0        0.0721

`w` collapses identically in both. In the first the arm is in real trouble; in
the second nothing happens at all, because the freedom being lost is a wrist
rotation and a translation never needed it. A κ floor would have stopped a
perfectly good jog for a reason invisible from the pendant — the exact failure
the reporting part of this section exists to prevent.

`w` is a property of the pose. Whether a command is achievable is a property of
the pose *and the direction asked for*.

**So the refusal is on the residual**, `|J·dq − v| / |v|` — the fraction of the
commanded twist the joints fail to deliver. At the wrist singularity it is
3.6e-12 for a translation and 0.098 for a rotation, at the same pose, which is
the distinction `w` cannot draw. Costs about 36 multiplies a tick.

**Variable damping loses to the scaling that was already here.** Damping bounds
joint rates by bending the answer away from the command, and the bend is not
small: at `j3 = -0.1` — 1.19 rad/s, no crisis — damping to a 0.5 rad/s ceiling
costs *half* the commanded twist. Uniform scaling meets the same ceiling with the
residual at zero: the tool exactly on the commanded line at 0.42× speed.

That is the argument already made against clamping per joint. The ratios between
joints are the direction; damping breaks them for the same reason clamping does,
just more politely. Speed is the cheaper thing to lose and the one an operator
can see going.

So λ is 1e-6 and no longer tunable — the smallest number that keeps a
rank-deficient 6×6 elimination from dividing by zero, and nothing else. It starts
to show at `j3 = -0.001`, where the residual reaches 1.8e-5, which is exactly
where it should start to show.

Losing the ability to damp *through* a singularity costs nothing: a jog should
not transit one, and joint jog is the way out, which the model description
already tells operators.

**What is there now**, per tick:

  * Scale the whole vector to the joint rate ceiling. Direction exact.
  * Refuse if the residual exceeds a quarter — the arm cannot go where it was
    pointed. Rare on this chain: five joints supply nine tenths of any
    single-axis rotation between them, so this is for commands with no
    achievable component at all rather than a guard that fires daily.
  * Refuse if the achievable tool speed falls under a fiftieth of what was asked.
    Approaching a boundary singularity that happens smoothly, which is
    physically correct and, on a pendant, indistinguishable from a hang.
  * A refusal writes zero rather than writing nothing, and does not latch. Being
    in an awkward pose is not a fault and should not need clearing.

**And it is reported**, which was always the half that mattered. Three nodes
under `axes.cartesian`, read-only and observable:

  * `state` — idle | tracking | limited | refused.
  * `speed_fraction` — the fraction of commanded tool speed being delivered.
  * `manipulability` — published for a viewport to shade reachability with, and
    deliberately not what the controller decides on.

Verified live: `idle → tracking → limited 0.571` while jogging +Z toward full
extension.

Still open: the ceiling is one number for every joint, read from a constant
rather than from the model. A machine with a linear axis needs it per axis, and
the axis model is where it belongs.

## 3. Frames

  * `base` — the arm's origin. Was the only one.
  * `tool` — done. The twist is rotated into the current TCP orientation before
    solving, both halves of it, and **re-resolved every controller tick** rather
    than frozen at the press. For a translation that makes no difference, since
    translating does not change orientation; for a rotation about a tool axis it
    is the difference between a spin and a cone.
  * `user` — named frames, stored on the controller as configuration because they
    are facts about the cell. Model nodes under `frames.<name>`, writable behind
    `write_configuration`. Not built; refused by the same clause that refuses a
    typo, which is honest about what this build has.

Unknown frame names are refused rather than quietly treated as base. A pendant
showing USER while the arm moves in WORLD is a bug found by a fixture.

The four jog modes on any commercial pendant — JOINT, WORLD, TOOL, USER — are
one joint method plus one Cartesian method with a frame argument, not four
mechanisms.

### The tool offset had never reached the solver

Fixed first, because `tool` frame is meaningless without it. The Jacobian NIF was
handed the joints and nothing else, so every Cartesian command solved for the tip
of the last joint rather than for the tool centre point. `ExMove.IK.solve/4` had
the same gap, so the two agreed with each other, and both agreed with the arm
only while the offset was identity — which it is on the demo chain, which is why
nothing complained.

What makes this one worth writing down is *how* it hides. A tool is rigidly
attached, so for a command with no angular component `v_tool` and `v_wrist` are
identical: the offset cancels and a Jacobian written about the wrong point still
produces exactly the right motion. Every translation test passes. Under rotation
they differ by `ω × r`, and solving about the wrist for "turn about this axis and
do not translate" holds the wrist still and swings the tool through an arc —
measured at 7.8 mm/s of linear velocity for a command that asked for none. On a
machine that looks like the tool orbiting the point it was supposed to pivot
about.

So the test that catches it has to be a rotation. Three of them now: the linear
rows against a finite difference of FK with a tool fitted, a pure-rotation tool
leaving the linear rows untouched (the composition-order check), and the orbit
above.

`max_reach/1` counts the tool as well, since it is used to reject targets before
iterating and a bound that stops at the wrist rejects points the arm can
comfortably touch.

## 4. Joint limits

Done in the stream, per tick. Predict `q + dq·dt`; if any joint would cross,
scale the whole vector so the arm lands on the boundary at the end of the tick
rather than a controller cycle past it.

This is the first thing that uses `dt`, and it is why the tick carries it. A
limit is a position, a tick commands a velocity, and the length of the tick is
the only thing that converts between them.

The whole vector, not the offending joint — the same rule as the rate ceiling
and for the same reason. Stopping one joint of six and letting the other five
run is a change of direction, and the operator asked for a direction.

Two things worth having found:

  * The joint is named by its **axis id**, not by `joint.id`. A `Chain` carries
    both and they are different mappings — what the chain calls a joint, and the
    drive it is bound to. They coincide on the demo arm, which is exactly the
    kind of coincidence that hides a wrong name until a machine with renamed
    axes reports a joint the client has never heard of.
  * Continuous joints are spelled two ways. `limit: nil` on the Elixir side and
    `limit_lo >= limit_hi` at the NIF boundary. Both are accepted, so that one
    description of a joint does not mean two things depending on which side of
    the language boundary is reading it. Reading either as a bound at the origin
    would refuse every jog on a chain with a continuous wrist.

Reported like everything else: `{:limited, {:joint_limit, axis}, fraction}` while
approaching, `{:refused, {:joint_limit, axis}}` on the boundary, and
`axes.cartesian.joint` names it. "The arm stopped" is a support call. Not
latched — jog the other way and the next tick tracks, because being at the end
of a joint's travel is not a fault.

Self-collision is the same class of problem and much larger: a capsule model per
link and a broad-phase check. Out of scope, named here because "the arm can move
through itself" is a real gap and should not be discovered by an arm.

## 5. Branch continuity

Velocity IK is differential, so a jog cannot flip elbow-up to elbow-down
partway through — the property comes for free from the method. Worth stating
because it is the reason a jog must never be implemented as "solve for a pose
and go there": that flip is a collision, and a solver picking a better-scoring
solution mid-move is exactly how it happens.

## 6. Cartesian speed limit

Done. 250 mm/s at the tool centre point, per ISO 10218, applied in the stream —
the only place that can, because it is the only place that knows the tool speed
being commanded.

It is the third uniform scale in the same tick, alongside the joint rate ceiling
and the joint-limit stop, and it composes with them the same way: all three are
fractions of the same raw motion, so the binding one is the smallest.

**But only two of the three describe the arm**, and that turns out to matter.
Rate and joint limits are the machine saying what it *cannot* do; the speed cap
is policy saying what it *may not*. The refusal test — "the achievable fraction
has collapsed, so say so rather than creep" — must be computed from the first two
alone. Commanding 10 m/s scales to a fortieth of what was asked, which is below
the refusal floor and is also the cap working exactly as designed. A limit doing
its job must never look like a machine that has failed.

Translation only. A rotation about the tool centre point moves that point at zero
by definition, so this never binds on one, while points out on the tool body are
moving at ω×r. That gap is real and is not closed here. Nor are the two halves
summed under one norm: rad/s and m/s are not comparable, and adding them would
slow a spin for being fast in the wrong unit.

Always on, because manual is the only mode this controller has. `state.controller_mode`
is declared in the model and nothing serves it — see section 7. When it is real
this becomes the manual value and auto gets its own.

Functional, not protective. It runs on the same BEAM as the thing it guards, so
it is a convenience against a slipped decimal point in a pendant and not a
safety-rated speed limiter. The E-stop is a hardware circuit. See
`protocol/DESIGN.md` on the split.

Reported as `{:limited, :tool_speed, fraction}`, so a pendant can say the arm is
at the manual limit rather than leaving an operator to wonder why 1 m/s produced
250 mm/s.

## 7. Mode

Done. `ExProto.Mode` holds the selector; `state.controller_mode` publishes it;
jogging is refused outside manual.

`state.controller_mode` had been declared in the model since it was written and
no source ever answered it, so a client could browse to a node marked readable
and then be told it does not exist — the browse contradicting the read inside one
session. That is worse than omitting the node: a client cannot tell "this
controller has no such thing" from "this controller is broken".

**Not writable over the protocol**, and that is the whole point. On a machine the
selector is a keyswitch, and it is a keyswitch precisely so software cannot turn
it. A client that could put a controller into manual in order to be allowed to
jog has not been interlocked; it has been asked politely. So the mode is
published read-only and moved by `select/1` from the console — which on hardware
becomes a discrete input, and this module becomes the thing that reads it rather
than the thing that stores it.

**Leaving manual releases every hold**, and releasing a hold commands zero.
Nothing new stops the arm: the watchdog has known how to do that since it was
written, and mode is simply another reason for it to fire. One stopping mechanism
with several triggers beats several mechanisms that all have to be correct.

### An interlock that can refuse a stop is not an interlock

Found by deadlock, which was the polite version of the problem.

The mode process calls the watchdog to release holds; the watchdog re-enters the
source to command zero; the source asked the mode whether jogging was permitted —
of a process that was mid-change and could not answer. That is a hang. But undo
the hang naively, by letting the mode answer, and the answer is *no*: the zero
that stops the arm is itself a jog assertion, and the interlock refuses it. The
selector leaves manual, the arm is told to stop, the interlock prevents the stop,
and the arm carries on moving in AUTO because it was told not to move.

So every assertion whose value is neutral is permitted in every mode, checked
*before* anything is asked of the mode. That is both the correct rule and the one
that does not re-enter. It generalises: any future interlock on a held command
gates the command and never the release.

### Fault

Reported as `fault` whenever any axis is faulted, whatever the selector says —
an operator looking at a faulted machine is not helped by being told it is in
manual. Kept separate underneath, because a fault is a condition the machine is
in and not somewhere an operator turned a key to; conflating them would mean
clearing a fault left the selector wherever the fault had put it.
`state.fault_present` is the same question asked directly, and it also never had
a source.

### Fail closed

A controller with no mode process is not in manual. `selected/1` answers `:idle`
when it cannot reach one, because the failure that matters is the one where the
guard is missing and the arm moves anyway.

### Errors

`WrongMode`, -32014, carrying the mode in its data. A client refused with a
generic rejection can only say the controller said no; one told the mode can say
what is true — the machine is in AUTO — and an operator can go and turn the key
rather than filing a bug.

### Still open

The manual speed limit in section 6 is always on rather than keyed to this. It
should be the manual-mode value, with auto getting its own, and that is a small
change now that mode is real.

## 8. Beyond jogging

`axes.move_linear` is done. `move_arc` and the queue are not.

### What a move is that a jog is not

A jog is an assertion that somebody is still holding a button, so it needs a
deadline and dies without one. A move has its end inside it — the arrival — and
needs nothing to keep talking for it to finish.

That difference cuts both ways and the second edge is worth stating plainly: **a
client that disappears mid-move does not stop the arm.** That is correct for a
command with a defined end, and it is exactly the property the watchdog exists to
deny a jog. Anyone who wants a move stopped sends something else on the same
object.

### The stream already was this

`move_linear` reuses the whole tick: the same rate ceiling, the same joint-limit
stop, the same tool speed cap, the same reporting. What changes is only where the
twist comes from — an error to a target rather than a direction from a client.
Closed loop, re-solved from the live pose every tick, like everything else here;
a precomputed path would be open loop and would drift exactly where the arm was
already struggling.

Translation and rotation are **synchronised**: time-to-go is
`max(distance/feedrate, angle/angular_feedrate, dt)` and both errors are divided
by it, so whichever needs longer sets the pace and they arrive together. A move
that got there and then turned would be two moves wearing one command's name.

The `dt` floor in that max is the whole deceleration story. Within one tick of
the target the remaining error is covered in exactly that tick rather than at a
feedrate that would carry the arm past it. No ramp, and none wanted — a ramp is a
fact about the drives, and they have one.

### Arriving is a state, not a silence

`{:done, :reached}`, published as `axes.cartesian.state = "done"`. A finished move
and a move that was never asked for must not look the same to a client.

Which produced the one real bug in this section. On arrival the goal is cleared,
and the next tick then found no goal, fell through to the held-jog path, solved
for a twist of zeros and reported `tracking` — an arm standing perfectly still,
described as one following a command. The internal clock stops ticking on
arrival so it never saw this; an external one keeps being told to tick, which is
what the tests use and what a fieldbus does.

### The queue, and blending

Moves queue. A second one runs after the first rather than replacing it — a
controller that dropped the move it was running whenever a new one arrived would
make a two-line program depend on how fast the client sent it.

A **jog clears the queue**, and that is the one asymmetry worth stating. An
operator taking hold of the arm has taken hold of it; queued moves firing
afterwards because nobody thought to cancel them is how a machine surprises
somebody.

Termination is FINE by default — settle on the point — and a blend radius makes
it CNT: within that radius the move gives way to the next one and the corner is
rounded instead of stopped in. The mechanism is two lines: `finished?` returns
true early, and `advance` starts the next motion **on the same tick**. That
second part is what makes a blend a blend, because the arm never spends a tick
with nothing to do and so never decelerates into the corner it was told to round.

A blend with nothing queued behind it is ignored and the move settles on its
point. Rounding a corner into nothing is just stopping short.

Two distances, and they are different on purpose. Blending asks how much *path*
is left, because that is what a corner is made of. Arrival asks how far the tool
is from the *point*, because that is what arriving means. On a straight move they
are the same number; on an arc they are not, and using path length for arrival
makes the tolerance depend on the radius — a tight arc reaching it comfortably
and a wide one never quite getting there. That was a real bug and it is why they
are two calls.

### `move_arc`

Three points define the circle: where the arm is when the move starts, a via
point, and the end. That is the form every teach pendant uses and the only one
that can be taught by driving the arm somewhere three times. Three points that do
not define a circle — collinear, or two of them coincident — are refused rather
than approximated, because an arc that quietly becomes a straight line is a
program doing something other than what it says.

The waypoint is one tick ahead along the circle, measured from where the arm
**actually is**. So an arm slowed by a rate ceiling falls behind *along the path*
rather than cutting across it: the waypoint follows the arm, the arm does not
chase a clock.

**The geometry is computed once**, when the motion becomes current, and kept.
This is the one place in this module where "re-solve from the live pose every
tick" is wrong, and it is wrong loudly: the first of the three points is where
the arm is, so recomputing each tick changes the circle under the arm as it moves
along it. The arm runs to the via point, the three points go degenerate there,
and it stops dead mid-arc and jitters. Measured exactly that, before the fix.
Live feedback belongs in the error term, not in the definition of the path.

Orientation is driven toward the end orientation, paced by the remaining arc
length so it arrives with the position. It is not slerped along the path — the
tool ends up right and gets there smoothly, but a specific orientation partway
round is not something this promises, which is why the via point takes a position
and no rotation.

### The drive mode, checked every tick

The stream used to set `profile_velocity` once, when it started. That is fine
until something else changes it — and something does: writing a position setpoint
puts that drive into `profile_position`, deliberately, because otherwise the
write is silently discarded.

A stream that outlives such a write then spends its whole life commanding
velocities into drives that ignore them. The arm does not move, every status
reads healthy, and the stream cheerfully reports `tracking`. Found on a live
controller by a `move_arc` that sat perfectly still and complained about nothing.

So the mode is checked every tick and set only when wrong. It costs nothing: the
drive's status was already read that tick for the joint position.

The general shape is worth keeping in mind — **state set once at startup is a
bet that nothing else touches it**, and on a controller with several ways to
command the same drive that bet loses quietly.

### Still open

Program execution. A queue that a client fills one call at a time is not a
program; it has no names, no branches, no way to be stored, edited or resumed.
That is a separate document and it is the next one.

## 9. Studio

  * Cartesian pendant: X/Y/Z and Rx/Ry/Rz pairs plus a frame selector, same
    hold-to-run pattern as the joint jog, one held command on the arm.
  * TCP readout — done.
  * Gizmo: local IK at 60 fps for preview, committing a `move_linear` on
    release. The one genuinely Studio-side solver, and it moves nothing.

## 10. How we would know it is finished

The tests are the specification, and the first one is the one that would have
caught what we shipped:

  * **The Jacobian against FK.** Every column, finite-differenced, at several
    bent poses. Done — `apps/exmove/test/exmove_jacobian_test.exs`. It is first
    because it is the one that would have caught what shipped, and because it is
    the only one that can: `J·dq == twist` compares J with itself, and every
    test below runs *through* the Jacobian and so inherits whatever it says.

  * **Straightness.** Jog +Z for two seconds; assert maximum deviation from the
    commanded line stays under a millimetre — at the manual speed limit, not at
    jog speed, which is where the margin actually is.
  * **Speed.** Done. `|Δp|/Δt` within a few percent of what was asked for, and
    within a few percent of the *limit* when more than the limit was asked for.
  * **Singularity.** Done — `exmove_singularity_test.exs`. Approach both kinds;
    assert the rates diverge at one and not the other, that the residual sees
    the difference and manipulability does not, and that the stream reports
    limited before it reports refused.
  * **Limits.** Done — `exmove_cartesian_stream_test.exs`. Jog into a joint
    limit; assert the arm stops on the boundary and not past it, that it slowed
    before it stopped rather than arriving at speed, that it names the joint,
    and that jogging away is not refused.
  * **Frames.** Done. The same twist in base and in tool produces different
    motion — at a pose chosen because the tool's +Z is 91.7° off the base's,
    measured. The bent pose the rest of the suite uses has them 5.7° apart,
    where a frame argument that did nothing would still pass.
  * **Hold.** Already covered by the watchdog tests, and unchanged by any of
    this.

## Order

1. ~~The Jacobian~~ — done, `e177d76`. It was the measured defect, and it
   was not what this document first said it was.
2. ~~`CartesianStream`~~ — done, `93090fd`. Needed for manual-speed accuracy,
   and needed before anything in 3, 4 or 6 had a clock to run on.
3. ~~Straightness and speed tests~~ — done, same commit, and the 10 Hz case
   asserts the bad number so the two rates cannot quietly become one again.
4. ~~Variable damping, κ floor, rate-limit reporting~~ — done, `3b59796`, and
   the first two of those three turned out to be the wrong things to build.
5. ~~Joint-limit stop~~ — done. The first thing to use the `dt` the tick has
   been carrying since the stream landed.
6. ~~Tool frame~~ — done, along with the tool offset finally reaching the
   solver, which it never had. ~~User frames~~ — done too: they are rows in
   the controller's database now, resolved with their parents composed in, and
   the tool is a row as well rather than a field compiled into the chain. See
   `PROGRAMS.md` §1 and §2.
7. ~~Cartesian speed limit, then the mode interlock~~ — both done. Keying the
   speed limit to the mode rather than leaving it always-on is the one piece
   left, and it is small.
8. ~~`move_linear` / `move_arc` and the queue~~ — done, along with FINE and
   blended termination and keying the tool speed limit to the mode. Programs —
   names, branches, storage — are the separate document.
9. Studio: Cartesian pendant, then the gizmo.
