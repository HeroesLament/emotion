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

## 2. Singularity policy — three tiers, not one check

Today `solve_velocity/3` reports `:singular` only when its Gaussian elimination
fails outright, and its damping constant is fixed at 1.0e-6. That is enough to
avoid dividing by zero and nowhere near a guard: near a singularity it returns
large joint rates that are arithmetically fine and physically wrong, and the
caller applies them. The model description currently claims a refusal that does
not happen — fix the claim or the code, but not neither.

**Finished** is three tiers, evaluated every stream tick:

  * **Detect.** Manipulability `w = sqrt(det(J·Jᵀ))`, or the condition number.
    Cheap enough at 200 Hz and it is the number everything else keys off.
  * **Damp.** Variable λ, zero when `w` is comfortable and rising smoothly as it
    falls (Nakamura, or Chiaverini's variable-damping form). This trades path
    accuracy for bounded joint rates *near* a singularity instead of failing
    *at* one.
  * **Refuse.** Below a floor, stop and say so. The operator is told the arm is
    singular and to use joint jog, which is the only way out of one anyway.

Alongside, always on: the joint-rate ceiling, applied by scaling the whole
vector rather than clamping per joint — clamping changes the ratios between
joints, and the ratios *are* the direction, so a clipped arm travels
confidently somewhere nobody pointed.

And it has to be *reported*. A pendant that says "limited: near singularity" is
a machine explaining itself; one that silently slows down is a machine that
feels broken.

## 3. Frames

Base only today. Finished:

  * `base` — the arm's origin.
  * `tool` — the twist is rotated into the current TCP orientation before
    solving, rotational components included.
  * `user` — named frames, stored on the controller as configuration because
    they are facts about the cell. Model nodes under `frames.<name>`, writable
    behind `write_configuration`.

One gap sits underneath all three. The Jacobian NIF is handed the joints and
nothing else, so the point it solves for is the tip of the last joint, not the
tool centre point — the tool offset lives on the Elixir `Chain`. `ExMove.IK.solve/4`
targets the same point, so the two agree with each other, and while the offset is
identity they also agree with the arm. Fit a real tool and every Cartesian
command is solved for the wrong point. The tool has to be plumbed into the NIF
before `tool` frame means anything.

Unknown frame names are refused rather than quietly treated as base. The four
jog modes on any commercial pendant — JOINT, WORLD, TOOL, USER — are then one
joint method plus one Cartesian method with a frame argument, not four
mechanisms.

## 4. Joint limits

A Cartesian jog that drives a joint into its limit must stop *before* it.
Per tick: predict `q + dq·dt`, and if any joint would cross, scale the whole
vector so the arm stops on the boundary — same uniform-scaling rule, same
reason. Report which joint. "The arm stopped because J5 is at its limit" is
actionable; "the arm stopped" is a support call.

Self-collision is the same class of problem and much larger: a capsule model
per link and a broad-phase check. Out of scope, named here because "the arm can
move through itself" is a real gap and should not be discovered by an arm.

## 5. Branch continuity

Velocity IK is differential, so a jog cannot flip elbow-up to elbow-down
partway through — the property comes for free from the method. Worth stating
because it is the reason a jog must never be implemented as "solve for a pose
and go there": that flip is a collision, and a solver picking a better-scoring
solution mid-move is exactly how it happens.

## 6. Cartesian speed limit

Manual-mode speed is a limit on the *tool*, not on any joint — ISO 10218 puts
it at 250 mm/s at the TCP. The stream is the only place that can enforce it,
because it is the only place that knows the tool speed being commanded. The
per-joint clamp that exists today is a convenience against a slipped decimal
point and is not this.

Functional, not protective. The E-stop is a hardware circuit and is not in this
document.

## 7. Mode

Jogging is gated on a grant, which answers "may this person ever jog". It does
not answer "is this machine in a state where jogging is what should happen".
Manual mode belongs on the controller as a property, with jog refused outside
it and the manual speed limit keyed to it. A pendant that greys out its own
buttons is a suggestion; a controller that refuses is an interlock.

## 8. Beyond jogging

Finished Cartesian is not only held motion:

  * `axes.move_linear` — async, not held: a target pose and a feedrate, running
    the same stream machinery toward a target rather than along a direction,
    terminating on arrival. `ExMove.Path.linear/4` already generates the ticks.
  * `axes.move_arc` — `ExMove.Path.arc/6` likewise.
  * Termination and blending — the FINE / CNT100 distinction every teach
    pendant shows per line: whether a move settles on its point or rounds
    through it into the next.

Those need a motion queue, which is where programs begin, and is a separate
document.

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
  * **Speed.** `|Δp|/Δt` within a few percent of what was asked for.
  * **Singularity.** Approach one; assert damping engages, then refusal, and
    that no joint rate ever exceeds the ceiling on the way.
  * **Limits.** Jog into a joint limit; assert the arm stops on the boundary
    and names the joint.
  * **Frames.** The same twist in base and in tool produces different motion,
    hand-checkable at a known pose.
  * **Hold.** Already covered by the watchdog tests, and unchanged by any of
    this.

## Order

1. ~~The Jacobian~~ — done, `e177d76`. It was the measured defect, and it
   was not what this document first said it was.
2. `CartesianStream` — needed for manual-speed accuracy, and needed before
   anything in 3, 4 or 6 has a clock to run on.
3. Straightness and speed tests, immediately after, so it stays fixed.
4. Variable damping, κ floor, rate-limit reporting.
5. Joint-limit stop.
6. Tool frame, then user frames.
7. Cartesian speed limit, then the mode interlock.
8. `move_linear` / `move_arc` and the queue.
9. Studio: Cartesian pendant, then the gizmo.
