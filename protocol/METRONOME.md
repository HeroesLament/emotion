# The metronome headends the robot: where the boundary falls

Status: BOUNDARY. The topology is settled (`FIELDBUS.md`); this is what
"headend" means concretely, and what it makes the host stop doing.

The metronome is not a CAN accelerator bolted onto a host-driven controller. It
is the head of the machine: every bus terminates on it, it owns the clock, and
the host never sees a CAN frame. `apps/metronome/lib/metronome.ex` has said so
from the start — *"it runs the CANopen cyclic engine (SYNC + RPDO/TPDO)
entirely on its own clock … it never computes CAN frames."* Multi-bus makes
that mandatory rather than preferable: N buses off one clock is a wiring fact,
N buses off N host threads is unbounded skew.


## The constraint moved. It is not CAN any more.

Measured from `Metronome.USB`: vendor class, **two interrupt endpoints, MPS 64,
bInterval 1**. That reads as full speed — interrupt MPS 64 is the FS ceiling —
so the link is **one 64-byte transaction per millisecond, each way: ~64 kB/s.**

*Confirm this on the wire before anything is designed against it.* `bcdUSB
0x0200` declares spec compliance, not high speed, and the entire budget below
hangs on which it is.

### Downstream — trajectory, not setpoints

A six-axis waypoint of position and velocity is 48 bytes; with an 8-byte header
it is 56, so **one waypoint fits in one packet** and a seventh axis still fits.

| waypoint spacing | rate | share of the pipe |
|---|---|---|
| 4 ms | 250/s | 22 % |
| 10 ms | 100/s | 9 % |
| 25 ms | 40/s | 4 % |

That table is the whole argument for the architecture. **The host is not
closing a loop over USB; it is filling a pipe.** The FPGA interpolates between
waypoints at servo rate, so the host's job is to stay ahead, not to be on time.

### Upstream — reporting, not feedback

| what | at 1 kHz | 500 Hz | 250 Hz |
|---|---|---|---|
| position + velocity + statusword (6 axes) | **106 % — does not fit** | 53 % | 27 % |
| position + statusword (6 axes) | 69 % | 34 % | 17 % |

Two ways out and they are different bets: drop velocity upstream and derive it
from successive positions, or report the full set at 500 Hz. The second is
better — a derived velocity at the host is a differentiated quantised position,
which is the same noise-budget mistake `Params::DEFAULT`'s `obs_bw_hz` note
already records having made once at 20 kHz.


## The number that has to be published: look-ahead depth

If the FPGA holds *D* milliseconds of trajectory, the host may be up to *D* ms
late without the arm knowing. **That number is what makes a BEAM host on Linux
acceptable**, and it should be a stated figure with a fault attached, not an
emergent property:

> The metronome holds 50 ms. The host must never be more than 25 ms from
> refilling it. Beyond that is a fault, not a glitch.

Underflow already has the right shape on the firmware side —
`boundary::ipbuf` counts underflows saturating rather than wrapping, *"because
a counter that wraps to zero would report no underflows at the exact moment"* —
and `Segment.seq` makes a gap visible as a gap rather than as a jump in
position. The same accounting belongs at the USB boundary: buffer occupancy and
underflow count are published state, not a debug print.


## The requirement that is easy to miss: an SDO tunnel

The host has no bus. But nearly everything in commissioning is acyclic SDO or
LSS traffic, and it all still has to happen:

* mastering — `0x2002` write, and reading state back;
* parameter tuning and `0x1010` save;
* `0x1018` identity, `0x1600`/`0x1A00` mapping discovery;
* LSS Fastscan and node-id assignment on a fresh board;
* firmware download over `0x1F51`.

So the USB protocol carries **three logical channels over two endpoints**, and
the framing has to say which is which:

| channel | direction | priority |
|---|---|---|
| cyclic — trajectory windows / feedback | both | first, always |
| acyclic — SDO and LSS tunnel, tagged by bus | both | never delays cyclic |
| control — NMT, bus health, STO, watchdog config, fault state | both | small, urgent |

An acyclic request that can push a cyclic window out of its millisecond is a
commissioning tool that makes the arm stutter. The multiplexer decides that,
and it decides it in favour of the arm.

**This is the gating artifact.** Not the CANopen client — this. Nothing above
it can be built or tested until the framing exists, and it is the one interface
with a device on the other side that cannot be refactored later over a coffee.


## What each side owns

**Metronome:** the clock and one SYNC per bus from it; the cyclic engine, RPDO
out and TPDO in, per bus; interpolation between host waypoints; NMT state,
heartbeat consumption and EMCY collection per bus; **the cross-bus fault
domain** — any bus losing its cyclic stream quick-stops every bus, in one
cycle, without asking the host; and the **STO watchdog** — the host stops
feeding, the line drops.

**Host:** kinematics, IK, limits, blending, path planning; programs, points,
frames, tools; mastering policy and its shadow; everything with a name in it.

The dividing line is time. Anything with a deadline shorter than the USB
round trip lives on the metronome. Everything else lives on the host, where it
can be written in a language with a garbage collector and tested without
hardware.


## The boundary this draws, stated so nobody trips over it later

Anything that needs the **host** to react quickly to feedback cannot work in
this architecture: force control, collision reaction, visual servoing. The
round trip is host → USB → FPGA → CAN → drive and back, several milliseconds
and not tightly bounded at the host end.

Every one of those is out of MVP scope, so this costs nothing today. But it is
an architectural commitment, not a schedule one: when one of them is wanted, it
moves **into the metronome or into the drive**, and the host's role stays
"describe the intent". Better to know that now than to discover it as a
latency bug.


## Consequences for the plan

`MVP-PLAN.md` §1 ordered the CAN work as if the host drove the bus. Corrected:

1. **Host↔metronome protocol** — framing, the three channels, window format,
   look-ahead depth and its fault. The gating artifact.
2. **Elixir CANopen client, bench only.** One interface, one motor, no FPGA.
   Still worth building: it is how the drive is learned, it is the oracle the
   FPGA's engine is checked against, and it survives as the commissioning and
   diagnostic tool. It is not the shipping path.
3. **Segment emission from `CartesianStream`** — unchanged in importance, and
   now clearly the same work for both the CAN budget and the metronome.
4. **`ExDrive.Axis` behaviour** — still item zero, and now with a third
   implementation in view: simulator, direct CANopen, metronome.

The `joint_settings` addition is unchanged but gains a field: an axis is
`{bus, node_id}`, and the bus is now a port on the metronome.


## Open

1. **Full speed or high speed.** Everything above assumes 64 B/ms. Measure it.
2. **Look-ahead depth**, and whether it is fixed or negotiated at attach.
3. **Feedback rate and content** — 500 Hz with velocity, or 1 kHz without.
4. **Where STO physically lands** on the MKS boards: enable input, or a
   contactor in the bus supply. Still the most important unanswered hardware
   question in the project.
