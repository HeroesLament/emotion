# The controller link, the drive layer, and the force path

This document covers everything between E-Motion Studio and a moving joint: the
protocol boundary, the CiA 402 drive abstraction, the simulated drive, and how
force feedback is estimated. It exists because the important decisions here are
structural rather than technical, and structural decisions are the ones that get
quietly undone if nobody writes down why.

## The one idea

**A simulated arm and a real arm differ only in the bottom layer.**

    Studio  ──── JSON-RPC 2.0 / WebSocket ────  Controller
                                                     │
                                          ExMove planning + dynamics
                                                     │
                                             Drive behaviour (CiA 402)
                                                     ╱          ╲
                                    CANopen over CAN            Simulated drive
                                      (servo-rs, FOC)            (pure Elixir)

Everything above the drive behaviour is byte-identical in both cases. The Studio
does not know which it is talking to, and there is deliberately no way for it to
find out short of asking the controller for its own description.

This is only true because CiA 402 is a *specification of behaviour*, not a
description of hardware. The state machine, the object dictionary, the modes of
operation - none of it says anything about whether there is a motor at the other
end. That is what makes a faithful simulator possible rather than a sketch, and
it is why the drive boundary sits exactly here and not one layer up or down.

## Simulator as a server, not as a mode

The simulated controller is a **separate OTP application that serves the same
WebSocket endpoint**. It is not a flag inside the Studio, and it is not an
in-process stub.

This matters more than it looks. A simulator wired directly into the Studio
exercises a different code path from the real thing, which means the thing you
tested is not the thing you ship. A simulator that speaks the protocol over a
socket exercises *every* layer: serialization, subscription, conflation,
reconnection, error mapping. The Studio connects to `ws://localhost:4000/rpc`
and genuinely cannot tell.

It also means one Studio can drive a mix - one real Arctos, two simulated arms -
without special support, because there is no such thing as a special case. And
the simulator runs in CI on a machine with no CAN bus.

## Time is an input, never a side effect

The simulator is driven by an explicit tick carrying a duration. It never reads
the wall clock and never uses `Process.send_after` as its clock.

A test can advance ten seconds of simulated motion instantly and assert on the
result, so motion tests run at CPU speed rather than in real time. A demo can be
driven at 1x against a real timer, at 10x, or stepped frame by frame, without
the simulator knowing the difference.

This matters more once dynamics are in play, because integrating a stiff system
wants a smaller step than the control loop uses, and a simulator that owns its
own clock cannot be sub-stepped.

## The CiA 402 drive behaviour

The contract every drive implements, real or simulated.

```elixir
defmodule EMotion.Drive do
  @callback read(drive, index :: 0..0xFFFF, sub :: 0..255) ::
              {:ok, term()} | {:error, term()}
  @callback write(drive, index, sub, value :: term()) ::
              :ok | {:error, term()}
  @callback state(drive) :: EMotion.Drive.State.t()
end
```

Deliberately thin, and deliberately expressed in object-dictionary terms rather
than robot terms. There is no `move_to/2` here. Motion is expressed by writing
0x607A and toggling controlword bit 4, because that is what the real drive
requires, and an abstraction hiding it would let controller code drift into
shapes the hardware cannot honour.

| Index  | Name                       | Notes                                   |
|--------|----------------------------|-----------------------------------------|
| 0x6040 | Controlword                | Drives the state machine                |
| 0x6041 | Statusword                 | Observes it                             |
| 0x6060 | Modes of operation         | PP 1, PV 3, PT 4, HM 6, CSP 8, CST 10   |
| 0x6061 | Modes of operation display | What the drive actually did             |
| 0x6064 | Position actual value      | Encoder counts                          |
| 0x606C | Velocity actual value      |                                         |
| 0x6071 | Target torque              | Per mille of rated torque               |
| 0x6072 | Max torque                 | The clamp that makes contact survivable |
| 0x6074 | Torque demand              | Post-slope, pre-plant                   |
| 0x6077 | Torque actual value        | Derived from I_q                        |
| 0x6078 | Current actual value       |                                         |
| 0x607A | Target position            |                                         |
| 0x607D | Software position limit    | Sub 1 min, sub 2 max                    |
| 0x6081 | Profile velocity           |                                         |
| 0x6083 | Profile acceleration       |                                         |
| 0x6084 | Profile deceleration       |                                         |
| 0x6087 | Torque slope               |                                         |
| 0x6098 | Homing method              |                                         |
| 0x60F4 | Following error actual     |                                         |
| 0x60FF | Target velocity            | Jog, in PV mode                         |

### The state machine is the valuable part

    Not ready to switch on → Switch on disabled → Ready to switch on
      → Switched on → Operation enabled

You must walk the transitions. Writing "enable operation" from `Switch on
disabled` does nothing, exactly as on real hardware. Faults latch and require an
explicit reset. Quick stop is its own state with its own exit rules.

Being strict here is the entire value proposition. A permissive simulator
produces controller code that works in simulation and fails on the bench, which
is worse than no simulator because it manufactures confidence rather than doubt.

## FOC is why the force path is viable

The drives are MKS SERVO42 and SERVO57 running servo-rs with field-oriented
control. This is not an implementation detail - it is the fact the entire force
strategy rests on.

Under FOC the phase currents are transformed into a rotor-aligned frame (Clarke,
then Park), yielding a flux-producing component `I_d`, commanded to zero at
these speeds, and a torque-producing component `I_q`. The relationship

    tau_motor = K_t * I_q

is calibrated, not inferred. A stepper under FOC is a two-phase PMSM, and torque
becomes both **measurable** and **commandable**.

That second property is the one that matters. It moves the arm from admittance
control to impedance control:

- **Admittance**: measure force, command position. Works with position-only
  joints. Needs a stiff position loop, feels heavy, and tends to chatter or go
  unstable against a stiff environment.
- **Impedance**: measure position, command torque. Requires torque control.
  Inherently stable against stiff environments and is what makes hand-guiding
  feel like moving a well-balanced object rather than fighting a servo.

Impedance is what real cobots do, and FOC is what puts it in reach here. The
qualifier is that we measure torque at the *motor*, not at the joint - there are
no joint torque sensors - so the transmission sits between the measurement and
the thing we care about. That is the dominant error term and the next section is
about modelling it.

### A third units chain

Position already has one: encoder counts, motor revolutions, gear ratio, joint
radians. Torque now adds its own, and 402 makes it worse by expressing torque in
per mille of rated torque rather than in newton-metres:

    per-mille rated → motor N·m (via rated torque) → joint N·m (via N and eta)

Same rule as position. The conversion lives in exactly one place, driven by
per-joint configuration, and is property-tested round-trip. Nothing above the
drive layer ever sees per mille or counts. The protocol is SI.

## The transmission is the error term

With FOC the sensor is good. What is uncertain is what the drivetrain did to the
torque between motor and joint:

    tau_joint = N * eta(tau, direction, temperature) * tau_motor - tau_friction(qdot)

Belt and harmonic efficiency varies with load, direction, and temperature.
Backlash puts hysteresis between motor and joint. Printed structure adds
compliance, so joint torque and end-effector force diverge when the arm deflects
under load.

This produces a concrete, testable prediction worth writing down before we
measure anything:

> **Force sensing quality will vary per joint, inversely with gear ratio.**
> Low-reduction joints sense well because the motor is close to the load.
> High-reduction joints sense poorly for the same reason a harmonic drive hides
> the load - friction and backlash referred to the joint scale with the ratio.

If that holds, contact-detection thresholds must be per joint rather than global,
and some joints will carry a tighter threshold than others. Measure this early;
it shapes the whole force API.

Secondary error sources, in rough order of how much they will bite:

1. **Cogging torque** - angle-periodic, sits squarely in the low-speed band
   hand-guiding uses. Because it is periodic in rotor angle it is
   characterisable and feed-forward cancellable, which makes it the highest
   value-per-effort item on this list.
2. **K_t thermal drift** - neodymium loses roughly 0.1%/degC, so a 40 degC rise
   is a few percent of torque error. Matters for fine force, not for gross
   contact detection.
3. **Current sense quantisation** - shunt and ADC resolution.

## Estimating external force

External joint torque is a residual: what was measured, minus what the model
says the observed motion should have required.

    tau_ext ~= tau_measured - (M(q) qddot + C(q, qdot) qdot + g(q) + f(qdot))

Implemented naively this needs joint acceleration, which is noisy to
differentiate. The standard fix is a **generalized momentum observer** (De Luca
and Mattone), which works on `p = M(q) qdot` and avoids acceleration entirely.
That is why essentially every cobot uses it, and it is what we should implement
rather than a direct residual.

The observer runs **identically in simulation and on hardware** - same module,
same code path, different plant underneath. That is the point of the whole
arrangement.

TCP wrench follows from the transposed Jacobian, `F = pinv(J(q)^T) tau_ext`,
with the usual caveat that this degrades near singularities and that a 6-DOF arm
gives an exactly-determined system only away from them.

## What the simulator models

The earlier version of this document said the simulator was not a physics
simulation. For a position-controlled industrial arm that was right. For a cobot
it is wrong, and the correction is not "add dynamics" but something sharper:

**Model the error sources, not the ideal.**

A simulator with exact gravity, no stiction, no backlash, and clean currents
will make the momentum observer look superb and teach us nothing, because it
will have been validated against a robot that does not exist. The value is in
reproducing exactly the things that make estimation hard:

- Coulomb, viscous, and Stribeck friction with realistic stiction breakaway
- Backlash with proper hysteresis, not a deadband
- Gearbox efficiency varying with load and direction
- Cogging as an angle-periodic torque term
- K_t drifting with a thermal state
- Current quantisation and noise

And the most important one, which is a *test methodology* rather than a model:

> Run the observer against a plant whose parameters deliberately differ from the
> observer's model. The phantom external force it reports under no real load is
> the **detection floor** for that joint.

That number, per joint, is the single most useful output the simulator can
produce. It is what tells us whether hand-guiding is viable and where contact
thresholds go.

Forward dynamics come from the standard set: Composite Rigid Body for `M(q)`,
Recursive Newton-Euler for inverse dynamics, Articulated Body for forward.
ExMove already has chains and FK; what it needs is inertial parameters per link
- mass, centre of mass, inertia tensor - which extends the existing `Chain` and
`Joint` structs rather than introducing a new subsystem.

## Identification is what makes any of it real

None of the above means anything until the parameters come from the actual arm.
Guessed link masses produce a simulator of a different robot.

The procedure is standard: excite the arm along a persistently exciting
trajectory, record position, velocity, and current, and least-squares fit the
base inertial parameters and friction coefficients. FOC makes this materially
easier, because the arm can be excited in **torque** rather than position, which
gives cleaner data and avoids the position loop hiding the dynamics being
identified.

Identification belongs *before* observer refinement in the build order. A
mediocre observer with identified parameters beats an excellent observer with
guessed ones, every time.

## What the simulator is still not

It does not do contact or collision geometry. Detecting that the arm would hit a
fixture is a cell-level concern operating on the cell's geometry, and it does
not belong in the drive layer. What the drive layer models is what happens to
torque and motion *given* an external wrench; deciding that a wrench should
exist because two solids overlap is somebody else's job.

## Safety: functional, not protective

Everything in this document is **functional capability**, not a protective
measure.

ISO 10218 was substantially revised in 2025 and folded in the collaborative
content that previously lived in ISO/TS 15066. The relevant consequence: power
and force limiting *as a safety function* requires safety-rated sensing and
safety-rated logic with a demonstrated performance level. A momentum observer
running in the BEAM on a Pi 5, reading I_q estimates over CAN, is not that, and
cannot be made into that by improving it.

This is not a reason to avoid the work. Hand-guiding for teaching, contact
detection to abort a move, force-aware assembly - all legitimate and all
valuable. What it must never be described as, in this repository or anywhere
else, is a mechanism that makes it safe for a person to share the workspace. The
Arctos is a prototype arm, not a certified cobot.

The corresponding rule in the protocol: `estop` is observed and never commanded,
and `motion/stop` is documented as not a safety function.

## Build order

Two tracks. The link has to exist before the force path is observable, but past
that point they are largely independent.

### Track one: the link

**1. `EMotion.Drive.StateMachine`** - a pure module. Controlword plus current
state in, next state plus statusword out. No processes, no I/O, no time.
Exhaustively testable including every illegal transition. Highest value per line
in the whole plan.

**2. `EMotion.Drive.Sim`** - object dictionary, the state machine from step 1,
and `tick(sim, dt)`. Position modes only at this stage.

**3. Controller application** - serves the OpenRPC protocol over WebSocket,
backed by simulated drives. First externally visible milestone: the Studio
connects to a simulated Arctos and sees it move.

**4. Studio client** - connect, subscribe to `joint_state`, feed the viewport.
Nearly free, because `EMotion.Scene.nodes/1` is already a pure function of the
cell; only the source of joint values changes.

**5. Conformance suite** - one suite that runs unchanged against either backend.
This is the payoff: it proves the simulator faithful *and* servo-rs conformant,
from one body of tests.

**6. CANopen backend** - socketcan on the Pi, SDO for configuration, PDO for
cyclic data, against real servo-rs. Deliberately last, because by then the
conformance suite exists to say whether it works.

### Track two: the force path

**7. Torque modes** - PT and CST in both the drive behaviour and the simulator,
with 0x6071, 0x6072, 0x6077, 0x6087 wired through.

**8. Rigid-body dynamics in ExMove** - inertial parameters on `Chain` and
`Joint`, then CRBA, RNE, and ABA. Testable in isolation against analytically
known cases before any of it touches a drive.

**9. Transmission model in the simulator** - friction, backlash, efficiency,
cogging, thermal drift. The error sources, per the section above.

**10. Parameter identification** - excite the real arm in torque, fit the base
parameters. Requires step 6. This is the step that makes the simulator a model
of *this* arm.

**11. Momentum observer** - implemented once, run against sim and hardware.
Measure the per-joint detection floor and check the gear-ratio prediction.

**12. Impedance control and hand-guiding** - the visible payoff, and last
because everything above it is a prerequisite.

## Open questions

- **Cycle time.** CST wants a hard periodic loop. The BEAM is soft real-time.
  Likely fine at 10 ms and likely not at 1 ms, but it needs measuring on the Pi 5
  before anything depends on the answer. This is the single biggest unknown for
  the force path, because impedance control quality scales with loop rate.
- **Where the compliance parameters live.** Does the Studio set stiffness and
  damping per Cartesian axis, or select a named profile the controller holds?
  This is the one open question that changes the protocol, so it should be
  settled before the controller is written.
- **Multi-axis synchronisation.** Coordinated motion wants CSP or CST with SYNC
  rather than per-axis PP. Changes the cycle-time budget.
- **Homing.** Which 402 homing methods servo-rs implements, and what the Arctos
  offers in the way of switches or hard stops.
- **Where the cell model lives.** The controller needs joint limits and
  kinematics to plan. Its own copy, or one pushed by the Studio? Pushing means
  the controller cannot run a program alone; holding means two copies that can
  disagree.
