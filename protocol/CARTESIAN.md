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

## 1. The interpolator (the defect we measured)

A jog assertion arrives at ~10 Hz. Today each one computes joint velocities
once and the joints coast on them until the next assertion. That makes the
*client's* rate the interpolation rate, and it does not work:

    tool speed 0.05 m/s  →  0.417 rad/s at shoulder and elbow
    held for 100 ms      →  0.042 rad of joint travel per tick

The Jacobian has changed meaningfully by the end of that tick, so each one
walks a chord where the command asked for an arc. Chord error always falls to
the inside of the curve, so it accumulates in one direction rather than
cancelling. Measured: commanding +0.05 m/s in Z for two seconds gave the right
Z and 175 mm of Y nobody asked for.

The solver is not at fault — `J·dq` equals the commanded twist to five decimal
places. Nor is the drive ramp: 10 rad/s² against 0.4 rad/s is ~40 ms in a 2 s
move.

**Finished:** a `Exdrive.CartesianStream` process per arm. An assertion
*refreshes the intent* — frame, direction, speed — and nothing else. The stream
re-solves from the live joint pose at its own rate and writes joint velocity
setpoints. The client's rate and the interpolation rate are decoupled: the
watchdog guards the hold, the stream guards the path.

Rate: the drives tick at 1 kHz, but each solve is a NIF Jacobian plus a 6×6
elimination. 200 Hz gives 5 ms ticks — 0.002 rad of joint travel, two orders
below the error we measured — and should be confirmed by measurement rather
than assumed. `Exdrive.IpStream` is already almost this shape and is the thing
to copy from.

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

  * **Straightness.** Jog +Z for two seconds; assert maximum deviation from the
    commanded line stays under a millimetre.
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

1. `CartesianStream` — fixes the defect that is measured and shipped.
2. Straightness and speed tests, immediately after, so it stays fixed.
3. Variable damping, κ floor, rate-limit reporting.
4. Joint-limit stop.
5. Tool frame, then user frames.
6. Cartesian speed limit, then the mode interlock.
7. `move_linear` / `move_arc` and the queue.
8. Studio: Cartesian pendant, then the gizmo.
