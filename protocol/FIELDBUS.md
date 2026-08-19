# The bus layout: joint groups, and what multi-bus actually costs

Status: DECIDED (topology) / OPEN (the safety channel). Supersedes the
single-bus arithmetic in `MVP-PLAN.md` §1.

Decided: **separate CAN networks per joint group.** J1–J3 on one, J4–J6 on
another, an effector segment, and possibly a further channel for
keepalive/heartbeat with a redundant PHY.


## What it buys, measured

Three axes a bus instead of six changes the answer from "impossible" to
"comfortable". Frames are `47 + 8N` bits, +15 % for stuffing; a cycle is one
SYNC plus the PDOs.

Per bus, three axes:

| bitrate | PDO set | 1 kHz | 500 Hz | 250 Hz |
|---|---|---|---|---|
| 500 kbit/s | all four | 273 % | 137 % | 68 % |
| 500 kbit/s | TPDO2 decimated | 196 % | 98 % | **49 %** |
| 1 Mbit/s | all four | 137 % | 68 % | 34 % |
| 1 Mbit/s | TPDO2 decimated | 98 % | **49 %** | 25 % |

Two readings matter:

* **500 Hz at ~49 % a bus, at 1 Mbit/s, with TPDO2 decimated.** That is the
  working envelope, and it has headroom for SDO traffic, EMCY and a heartbeat
  without touching the cyclic budget.
* **250 Hz at ~49 % a bus at 500 kbit/s** — the firmware's *existing default
  bitrate*, so first light needs no bitrate change and no LSS dance.

### Correction to an earlier optimism

An earlier draft claimed ip mode could drop RPDO2 and run RPDO1+TPDO1 alone.
It cannot. `boundary::ipbuf::Segment` is `pos(4) + vel(4) + ticks(4) + seq(4)`
= 16 bytes, and a classical CAN frame carries 8. Even with `ticks` implicit
(equal to the SYNC period) and `seq` narrowed to `u8`, a segment plus a
controlword is 11 bytes. **Two RPDOs are structural, not a legacy artefact** —
which is presumably why the fixed mapping already splits them exactly that way.

The open piece is that **the wire encoding of a segment does not exist yet**:
ip (mode 7) is unimplemented in `servo-rs`, only the ring is built. E-Motion
should co-design that encoding rather than receive it. The recommendation is
`RPDO1 = controlword(2) + pos(4) + seq(1)` and `RPDO2 = vel(4)`, with `ticks`
implicit in the SYNC period — which keeps the existing frame shapes and adds
one byte for the gap detection the ring was designed around.


## The thing multi-bus costs: one clock, or none

**Two buses have two SYNCs, and two SYNCs are two time bases.** J1–J3 and
J4–J6 have to be commanded for the same instant, and if the shoulder's SYNC and
the wrist's SYNC drift apart the arm is executing a pose that never existed —
the wrist doing what it was told for a moment the shoulder has already left.

The magnitude is small and that is not the problem. The problem is that under
Linux scheduling with two SocketCAN interfaces the skew is **unbounded and
unmeasured**: it is a property of whichever thread the scheduler woke, and it
does not appear in any log. An error that never trips an alarm and grows with
speed is the worst shape a motion error can have.

This is the argument that makes the metronome load-bearing rather than an
optimisation. From `apps/metronome/lib/metronome.ex`, its design already says:

> The FPGA is the hard-real-time metronome: it holds the trajectory look-ahead
> buffer, interpolates each servo cycle, and runs the CANopen cyclic engine
> (SYNC + RPDO/TPDO) entirely on its own clock. … **It never computes CAN
> frames; that is the FPGA's job.**

The multi-bus decision and the metronome design are the same decision, arrived
at from opposite ends. One board, one clock, N PHYs: SYNC coherence across
buses stops being a synchronisation problem and becomes a wiring fact. It also
answers a question nobody has asked yet — **the host does not have four CAN
interfaces.** A Pi gets there through MCP2515s on SPI, which is interrupt-heavy
and jittery, and that is the same jitter arriving by a different route.

### Consequence for the plan

`MVP-PLAN.md` §1 listed a host-side SocketCAN stack as the path. It is not the
shipping path; it is the **bring-up path**, and it is still worth building:

* one motor on a bench needs one interface and no FPGA;
* an Elixir CANopen client is how the drive's behaviour gets learned, and it
  stays useful afterwards as a diagnostic and commissioning tool
  (`cangw`-style SDO poking, LSS, firmware download over `0x1F51`);
* it is the reference the FPGA's engine is checked against.

So: build it, do not ship on it. Single-axis and single-bus bring-up in Elixir,
multi-bus cyclic traffic on the metronome.


## Failure semantics, which multi-bus introduces

One bus has one failure mode: it is up or it is not. Two buses have three, and
the new one is the dangerous one.

**If the wrist bus drops while the shoulder bus is healthy, J1–J3 keep going.**
Three joints continuing a Cartesian move that four, five and six have stopped
participating in is not a degraded move — it is a different move, through a
pose nobody planned, with the tool somewhere the program never described. It
is worse than everything stopping, and on a loaded arm it can be worse
mechanically than a fault.

So the rule, and it is not optional: **the fault domain is the arm, not the
bus.** Any bus losing its cyclic stream quick-stops every bus. The reaction
time is the detection latency, and with one device owning all the buses that is
one cycle with no host round trip — another thing the gateway buys that two
SocketCAN interfaces cannot.


## Addressing: node ids stop being unique

Node ids are per-bus, so J1 and J4 can both be node 1 — and probably should be,
because it makes each bus's LSS Fastscan a three-node problem instead of a
six-node one, and a fresh board on the wrist harness cannot collide with one at
the shoulder.

That means **an axis is `{bus, node_id}`, not `node_id`**, and the store has
nowhere to put that today. `ExStore.Cell.JointSetting` holds `axis_id`,
`joint_name`, limits and rates; it needs `bus` and `node_id` beside them, both
commissioning facts in exactly the sense that table exists for — properties of
this installation that survive a re-exported CAD file.

Per-bus, not per-fleet, from here on: heartbeat consumers, EMCY handling, NMT
state, LSS, bitrate. The adapter's unit of supervision is a bus.


## The effector segment

Endorsed, with one question: the wrist harness already runs to the end of the
arm, so a gripper on the J4–J6 bus costs one node's traffic and **no new
cable**. At 49 % load there is room.

Split it out when the gripper earns it: a third-party device whose bus manners
are unknown, a chatty sensor, or anything that could jam the segment the wrist
depends on. Fault isolation is the real reason, not bandwidth — and it is a
good reason. It is just worth paying the cable for a named fault rather than by
default.


## The safety channel: be precise about what it is

A fourth CAN carrying keepalives is an **independent liveness channel**. It is
not a safety function, and the distinction is worth holding hard because
conflating them is how a project ends up believing it has a protective measure
it cannot argue for.

To be a safety function it needs rated components, diagnostic coverage, a
declared fault reaction time and — for anything above cat B — dual channel with
cross-checking. Over CAN, the standard answer exists: **CANopen Safety (CiA
304 / EN 50325-5)**, SRDOs carrying the data twice, one inverted, with SCT and
SRVT timers. It works, and it means `servo-rs` implements SRDO and someone
writes the assessment. That is a real project, not a bus.

For V1 the stronger and cheaper answer is that **safety is a wire, not a
message.** A discrete STO line, driven by the E-stop chain and by a watchdog in
the metronome, removes drive enable regardless of what any bus believes. It has
a bounded reaction time by construction, it survives a bus that is up but
lying, and it is the architecture a rated version grows into rather than
replaces.

Which leaves the fourth bus with a genuinely good job that is not safety:
**diagnostics on a channel that motion traffic cannot delay.** On a bus at 49 %
a heartbeat queues behind PDOs; on an idle bus its latency is bounded and
measurable. That makes it the right place for liveness, EMCY, temperature and
following-error telemetry, and it makes those numbers trustworthy in exactly
the moment the motion bus is saturated and you most want them.

### On the redundant PHY

CANopen has a redundancy profile (CiA 302-6) if it is wanted. But the dominant
failure in a robot arm is a conductor in a moving harness, and a second
transceiver on a cable that shares the same drag chain does not address it. If
the money is going anywhere, it goes to **routing the second channel
differently** — or to the STO wire, which is the failure this is all trying to
survive.


## Open

1. **Bitrate.** 500 kbit/s ships today and gives 250 Hz at half a bus.
   1 Mbit/s gives 500 Hz at half a bus and costs an LSS pass per drive.
   Bench-measure the frame time before choosing; the arithmetic above is
   arithmetic.
2. **The segment wire encoding**, which does not exist. E-Motion should propose
   it; `servo-rs` implements mode 7 against it.
3. **How many PHYs the metronome carries**, and whether the effector shares the
   wrist bus for V1.
4. **Where STO physically lands** on the MKS boards — enable input, or a
   contactor in the bus supply.
