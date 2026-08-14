# The controller link, and why the simulator is the same thing

This document covers everything between E-Motion Studio and a moving joint: the
protocol, the drive abstraction, and the simulated drive. It exists because the
most important decision here is structural rather than technical, and structural
decisions are the ones that get quietly undone if nobody writes down why.

## The one idea

**A simulated arm and a real arm differ only in the bottom layer.**

    Studio  ──── JSON-RPC 2.0 / WebSocket ────  Controller
                                                     │
                                                ExMove planning
                                                     │
                                             Drive behaviour (CiA 402)
                                                     ╱          ╲
                                    CANopen over CAN            Simulated drive
                                      (servo-rs)                 (pure Elixir)

Everything above the drive behaviour is byte-identical in both cases. The Studio
does not know which it is talking to, and there is deliberately no way for it to
find out short of asking the controller for its own description.

This is only true because CiA 402 is a *specification of behaviour*, not a
description of hardware. The 402 state machine, the object dictionary, the modes
of operation - none of it says anything about whether there is a motor at the
other end. That is what makes a faithful simulator possible rather than a
sketch, and it is the reason the drive boundary sits exactly here and not one
layer up or down.

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

It also means you can point one Studio at a mix - one real Arctos, two simulated
arms - without any special support for that case, because there is no such thing
as a special case. And the simulator runs in CI on a machine with no CAN bus.

## Time is an input, never a side effect

The simulator is driven by an explicit tick carrying a duration. It never reads
the wall clock and never uses `Process.send_after` as its clock.

Two consequences, both of which are the point:

A test can advance ten seconds of simulated motion instantly and assert on the
result, so the motion tests run at CPU speed rather than in real time. And a
demo can be driven at 1x against a real timer, or at 10x, or stepped frame by
frame, without the simulator knowing the difference.

A simulator whose clock is `System.monotonic_time/0` produces flaky tests and
cannot be stepped. This is not a preference.

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
than in robot terms. There is no `move_to/2` on this behaviour. Motion is
expressed by writing 0x607A and toggling bit 4 of the controlword, because that
is what the real drive requires, and an abstraction that hides it would let
controller code drift into shapes the hardware cannot honour.

The objects that matter for the first pass:

| Index  | Name                      | Notes                                    |
|--------|---------------------------|------------------------------------------|
| 0x6040 | Controlword               | Drives the state machine                 |
| 0x6041 | Statusword                | Observes it                              |
| 0x6060 | Modes of operation        | PP (1), PV (3), HM (6), CSP (8)          |
| 0x6061 | Modes of operation display| What the drive actually did              |
| 0x6064 | Position actual value     | Encoder counts                           |
| 0x606C | Velocity actual value     |                                          |
| 0x6077 | Torque actual value       | Motor current, for the Arctos            |
| 0x607A | Target position           |                                          |
| 0x607D | Software position limit   | Sub 1 min, sub 2 max                     |
| 0x6081 | Profile velocity          |                                          |
| 0x6083 | Profile acceleration      |                                          |
| 0x6084 | Profile deceleration      |                                          |
| 0x6098 | Homing method             |                                          |
| 0x60FF | Target velocity           | For jog, in PV mode                      |

### The state machine is the valuable part

The 402 state machine is where integration bugs live, so the simulator
implements it strictly rather than conveniently:

    Not ready to switch on → Switch on disabled → Ready to switch on
      → Switched on → Operation enabled

You must walk the transitions. Writing "enable operation" from `Switch on
disabled` does nothing, exactly as on real hardware. Faults latch and require an
explicit fault reset. Quick stop is its own state with its own exit rules.

Being strict here is the entire value proposition. A permissive simulator makes
controller code that works in simulation and fails on the bench, which is worse
than no simulator, because it produces confidence rather than doubt.

## Simulating the Arctos

The Arctos is stepper-driven through gear reduction, and the units chain is
where the bugs are:

    encoder counts → motor revolutions → gear ratio → joint radians

Every joint has a different ratio. Signs differ per joint depending on how the
belt is routed. This conversion belongs in exactly one place, with the ratio and
sign as per-joint configuration read from the robot description, and it should
be property-tested round-trip: counts → radians → counts must be the identity
within one count.

Nothing above the drive layer ever sees a count. The protocol is SI, the
planning layer is SI, and radians become counts at the last possible moment.

First-pass fidelity, in order of value:

1. **State machine and object dictionary** - exact. Free, and catches the most.
2. **Trapezoidal profile in PP mode** - honour 0x6081/0x6083/0x6084 so a move
   takes the time it would really take. Wrong durations make the Studio's
   progress reporting a lie.
3. **Software position limits** - refuse out-of-range targets the way the drive
   would, so limit handling is exercised.
4. **Following error** - a configurable lag between demand and actual, which is
   what lets you provoke a following-error fault.

Explicitly *not* in the first pass: backlash, belt compliance, thermal models,
step loss. The Arctos is 3D printed and has all of these, but modelling them
before the state machine is exact would be optimising fidelity in the dimension
that matters least.

### Fault injection is a feature, not a debug tool

The simulator exposes fault injection as part of its API, because this is where
it earns its keep beyond "the arm moves":

- Drive drops to `Fault` mid-motion
- Following error exceeded
- Over-temperature warning, then fault
- Communication loss on one node
- Limit switch triggered during homing

None of these can be provoked on a real arm without either breaking it or
waiting for a bad day. All of them must be handled correctly by the Studio, and
the only way to know that is to cause them on demand.

## What the simulator is not

It is not a physics simulation. There is no contact, no gravity loading, no
dynamics. It integrates commanded motion subject to drive limits, and that is
all. Collision checking is a separate concern that operates on the cell geometry
and does not belong in the drive layer.

If dynamics become interesting later, they attach above the drive - as a load
model that perturbs the following error - not inside it.

## Build order

Each step is independently useful and testable, which is deliberate: nothing
here requires the step after it to be worth having.

**1. `EMotion.Drive.StateMachine`** - a pure module. Controlword plus current
state in, next state plus statusword out. No processes, no I/O, no time.
Exhaustively testable, including every illegal transition. Highest value per
line in the whole plan.

**2. `EMotion.Drive.Sim`** - object dictionary, the state machine from step 1,
and a `tick(sim, dt)` that integrates motion. Still pure or near enough; the
process wrapper comes later and stays thin.

**3. Controller application** - serves the OpenRPC protocol over WebSocket,
backed by simulated drives. At the end of this step the Studio can connect to a
simulated Arctos and see it move. This is the first externally visible
milestone.

**4. Studio client** - connect, subscribe to `joint_state`, feed the viewport.
The viewport already renders from `EMotion.Scene.nodes/1`, which is already a
pure function of the cell, so this is genuinely just replacing where the joint
values come from.

**5. Conformance suite** - a single test suite that runs unchanged against
either backend. This is the payoff: it proves the simulator is faithful *and* it
proves servo-rs is conformant, from one body of tests.

**6. CANopen backend** - socketcan on the Pi, SDO for configuration, PDO for
cyclic data, against real servo-rs firmware. Deliberately last, because by this
point the conformance suite already exists to tell you whether it works.

## Open questions

- **Multi-axis synchronisation.** Coordinated motion needs CSP with SYNC rather
  than per-axis PP. Worth deciding early whether v1 does point-to-point only,
  because it changes the cycle-time budget on the Pi.
- **Cycle time.** CSP wants a hard periodic loop. The BEAM is soft real-time.
  This is likely fine at 10ms and likely not at 1ms; it needs measuring on the
  Pi 5 before anything depends on the answer.
- **Homing.** Which of the 402 homing methods servo-rs implements, and what the
  Arctos actually has in the way of switches or hard stops.
- **Where the cell model lives.** The controller needs joint limits and
  kinematics to plan. Does it hold its own copy, or does the Studio push one?
  Pushing means the controller cannot run a program alone; holding means two
  copies that can disagree.
