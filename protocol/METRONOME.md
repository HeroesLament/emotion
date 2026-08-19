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


## Transports: three topologies, one interface

The host link is **USB, AXI-DMA (Zynq) or possibly Ethernet**. It is never SPI —
`docs/INTRODUCTION.md` says SPI and is wrong; that line predates the metronome
app by two months and should be corrected rather than reconciled.

These are not three cables for one design. They are three **deployment
topologies**, and they differ in what a "window" has to be:

| | where the FPGA is | a window is | service interval |
|---|---|---|---|
| **USB** | separate board, cable, hot-plug | a packet, quantised to frames | 1 ms (FS) / 125 µs (HS) |
| **AXI-DMA** | same die as the host (Zynq PS+PL) | **a ring entry in DDR** | none — it is memory |
| **Ethernet** | separate board, long cable, isolated | a frame | 125 µs achievable |

### Make the ring the interface, and the choice binds late

Everything this document already specifies — trajectory windows, published
look-ahead depth, `seq` so a gap reads as a gap, saturating underflow counts,
occupancy as published state — describes **a ring buffer with a producer index,
a consumer index and health counters**. Nothing in it is about USB.

So define the metronome interface as exactly that, and the three transports
become three ways of moving the same structure:

* **AXI-DMA** — the ring *is* the interface. Nothing is moved.
* **USB** — ring entries are packetised into isochronous transfers; the
  endpoint architecture in this document is the packetisation layer, nothing
  more.
* **Ethernet** — ring entries in frames, with a sequence number that already
  exists.

That is worth doing deliberately, because it means the transport decision stops
gating everything upstream of it.

### AXI-DMA is the best of the three, and most of it exists

On Zynq the PS (ARM, Linux, BEAM) and the PL are one die. There is no link,
there is shared DDR. And EHDL already has the parts:

* **`Hw.PS7HP`** — PS7 with `S_AXI_HP0` and the EMIO GPIO banks.
* **`Hw.AXIHPWriter`** — the PL mastering data into DDR through HP0.

More valuable than the components is the architectural rule they were built
around, which was paid for in a debugging session and is exactly right here:

> The PL *masters* data into DDR through `S_AXI_HP0`. The lethal GP failure
> mode — a PS-initiated read into the PL that never answers, hanging the CPU
> with no recovery — cannot occur when the PL is the master; a broken PL master
> starves, it cannot wedge the ARM.

A metronome that starves is a metronome that reports underflow and quick-stops.
A metronome that wedges the ARM is unrecoverable without a power cycle. That
distinction is the whole ballgame for a motion controller, and it is already
decided correctly.

The design that falls out:

```
  DDR (PS)                                    PL
  ┌─────────────────────┐
  │ trajectory ring     │ ◀── HP0 reads ───── segment fetch, look-ahead
  │ feedback ring       │ ◀── HP0 writes ──── AXIHPWriter (exists)
  └─────────────────────┘
        indices, occupancy, underflow, LOCKED, heartbeat
             ◀────── EMIO GPIO banks 2/3, 64 wires ──────▶
```

Which is, near enough word for word, what `Hw.PS7HP`'s own moduledoc already
describes EMIO carrying: *"write pointer bits, burst/overrun counters, LOCKED,
heartbeats."* Control plane on GPIO, data plane on HP, PL always the master.

**What this deletes:** packets, framing, service intervals, `bInterval`,
endpoint maps, isochronous alternate settings, explicit feedback endpoints, and
the entire contents of `USB-PATH.md`. Latency becomes DDR latency.

**What it needs that does not exist yet:** the HP0 **read** path. `AXIHPWriter`
is write-side only, and the trajectory ring requires the PL to master reads. The
same safety property holds — a PL master that cannot read starves — so it is the
same architecture, not a new one.

### The CAN side is further along than assumed

`designs/can_controller_bringup/` brings up **`Hw.CAN.Controller` — a soft CAN
controller in fabric** driving a bare SN65HVD230, no MCP2515 anywhere, and
transmits a real CANopen SYNC frame (COB-ID 0x080) on a real bus.
`designs/canopen_sync_bringup/` does the same through the MCP2515 path at
500 kbps.

For a multi-bus metronome the soft controller is the right one, and not
marginally: **N controller instances and N transceivers, all in the same clock
domain as the SYNC generator.** That is "one clock, N buses" as a structural
fact rather than a synchronisation effort. The MCP2515 path puts an SPI
transaction between the SYNC generator and the wire — fine for bring-up, wrong
for the thing whose entire purpose is deterministic timing.

Three actuator buses plus an effector segment is four instances of a core that
already transmits on silicon.

### So which topology

Pick by where the FPGA physically is, not by preference:

* **Zynq carrier, PS running the controller** → AXI-DMA. Best latency, no
  protocol, most of it built, and the failure mode is already the safe one.
* **Discrete FPGA on a cable** → USB, and `USB-PATH.md` applies. This is the
  ULX3S bench topology and it is not wasted work: it is how the CAN cores and
  the cyclic engine get developed before a carrier exists.
* **Distance or galvanic isolation required** → Ethernet, which needs a MAC and
  PHY in fabric and only earns that if the distance is real.

The ring interface makes this a late decision. Make it late.


## The constraint moved. It is not CAN any more.

> Applies to the **USB topology**. On Zynq with AXI-DMA there is no link
> budget at all — see *Transports* above.

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

> **Superseded** by *Correction: three transfer types* below. The three
> channels are right; putting them on two interrupt endpoints and policing
> them in software is not. USB schedules periodic before bulk in hardware,
> which is a stronger guarantee than any rule written here.

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


## The acyclic tunnel

### First, three protocols, not one

"An LSS tunnel for SDOs" is two different things wearing one name, and the
difference decides the addressing:

| | COB-ID | addressed by | what it is for |
|---|---|---|---|
| **NMT** | `0x000` | node id, or 0 for all | start/stop/reset a node |
| **SDO** | `0x600+node` → / `0x580+node` ← | **node id** | read or write any object by index/subindex |
| **LSS** | `0x7E5` → / `0x7E4` ← | **nothing — that is the point** | give an unconfigured node its id and bitrate |

LSS exists precisely for the case where there is no node id yet: a factory-fresh
`servo-rs` board parks at `0xFF` and answers only LSS. So the tunnel cannot be
"an SDO tunnel with LSS on top" — LSS is a peer, and it has to work when SDO
cannot.

What the host actually needs to send down the tunnel:

* SDO — mastering (`0x2002`), parameter save (`0x1010`), restore (`0x1011`),
  identity (`0x1018`), mapping discovery (`0x1600`/`0x1A00`), home offset
  (`0x607C`), firmware download (`0x1F51`);
* LSS — Fastscan and node-id assignment on a fresh board;
* NMT — bring a bus operational, reset a node.

And what comes back unbidden, which the tunnel must also carry **up**: EMCY
(`0x080+node`) and heartbeat (`0x700+node`).


### The design fork: raw frames, or services

**Service tunnel** — the host says "write 0x2002:02 = 0x7274736D on bus 1 node
3" and the metronome runs the SDO client: segmentation, timeouts, aborts,
retries.

**Raw frame tunnel** — the host says "put these bytes on bus 1 as COB-ID 0x603"
and reads back what arrived. The SDO and LSS state machines live in Elixir.

**Take the raw frame tunnel.** The reasons compound:

* The SDO client is the fiddly part — segmented and block transfer, abort code
  interpretation, the CANopen wart that **responses carry no transaction id**
  (they are matched by COB-ID and index/subindex alone, so a retry can be
  answered by the previous attempt's response). That belongs where it can be
  tested in milliseconds, not in a bitstream.
* It is protocol-agnostic by construction: LSS, NMT, EMCY, heartbeat and
  anything CiA 401 adds for I/O all ride the same mechanism with no new RTL.
* The RTL reduces to something small enough to be obviously correct: a queue
  per bus, a classifier, and one scheduling rule.

The cost is a USB round trip per SDO segment, which sounds bad and is not:

| | |
|---|---|
| firmware image | 27,320 B |
| segmented SDO download | 3,903 segments of 7 bytes |
| at 1 ms round trip | **~3.9 s** |
| at 2 ms round trip | ~7.8 s |

Four seconds to reflash a drive, over the tunnel, with no special path. That is
faster than the operator can find the cable.


### The scheduling rule, which is the whole of the RTL

A cycle is: SYNC, then the cyclic burst, then whatever time is left.

```
|<------------------ SYNC period ------------------>|
 SYNC | RPDO1 x3 | RPDO2 x3 | ...TPDOs... | acyclic | guard |
```

The metronome knows the cyclic burst's duration exactly — the mapping is fixed
and the axis count is fixed — so it admits an acyclic frame only when

```
now + longest_acyclic_frame + margin  <  next_SYNC
```

**The guard band is not optional and it is not about fairness.** CAN cannot
preempt a frame in flight, so a frame started too late is still on the wire when
SYNC is due, and SYNC is the thing every drive's cycle is anchored to. The
longest acyclic frame is an 8-byte frame: 255 µs at 500 kbit/s, 128 µs at
1 Mbit/s. One comparison, and it is the only timing rule in the tunnel.

Arbitration does the rest for free, which is a good reason to use the standard
COB-IDs and invent nothing: an SDO request is `0x600+node` and a PDO is
`0x180`–`0x3FF`, so a lower ID always wins the bus. Even a queued acyclic frame
loses to a PDO without anybody arranging it.

### What that leaves, measured

Three axes a bus, RPDO1+RPDO2+TPDO1 cyclic, an 8-byte guard:

| bitrate | rate | cyclic | acyclic window | frames/s |
|---|---|---|---|---|
| 500 kbit/s | 500 Hz | 1964 µs of 2000 | **none** | 0 |
| 500 kbit/s | 250 Hz | 1964 µs of 4000 | 1781 µs | ~1,500 |
| 1 Mbit/s | 500 Hz | 982 µs of 2000 | 890 µs | ~3,000 |
| 1 Mbit/s | 250 Hz | 982 µs of 4000 | 2890 µs | ~5,500 |

The first row is the finding. **At 500 kbit/s and 500 Hz there is no acyclic
window at all** — the bus is not merely 98 % busy, it is unusable for anything
else. No commissioning, no mastering, no diagnostics while the arm runs. That
turns the bitrate question from a performance preference into a capability one:
**500 Hz requires 1 Mbit/s**, or 250 Hz is the ceiling.

The USB side caps out at roughly 5 frames per 64-byte packet per millisecond,
so above 1 Mbit/s the pipe, not the bus, is the limit — which is the right way
round.


### Framing

64-byte packets, one type byte, so all three channels share two endpoints:

```
0      u8   type    0x01 cyclic  0x02 acyclic  0x03 control
1      u8   bus     0..N-1  (ignored for cyclic: a window spans every bus)
2..3   u16  seq     wraps; a gap is a gap, not a jump
4..63  payload
```

An acyclic payload is a list of CAN frames, 12 bytes each — five per packet:

```
0..1   u16  cob_id  (11-bit, top bits carry RTR/extended if ever needed)
2      u8   dlc
3      u8   flags
4..11  u8   data[8]
```

Upstream is the same shape with a timestamp, so the host can measure the bus
rather than guess at it.

### What the metronome does NOT do

No SDO state machine. No timeouts. No abort interpretation. No retries. No
knowledge of what any index means. It is a **scheduled multiplexer**: classify
by COB-ID, queue per bus, admit inside the window, forward everything else up.

The one piece of policy it does own is backpressure — a bounded queue per bus,
with depth reported on the control channel, and **overflow drops the acyclic
frame rather than delaying a cyclic one**. A commissioning tool that is slow is
correct; a commissioning tool that makes the arm stutter is not.


### The mode nobody plans for: commissioning

LSS runs *before* a node has an id, so it runs before the cyclic engine can
address that node at all. A SYNC-anchored cyclic engine pointed at a bus of
unconfigured drives has nothing to talk to.

So each bus needs two modes:

* **commissioning** — no SYNC, no cyclic traffic, tunnel only. LSS Fastscan,
  node-id assignment, identity, firmware download.
* **operational** — cyclic engine running, tunnel admitted inside the guard.

Per bus, not per fleet: a replacement board on the wrist harness should be
commissionable while the shoulder bus is still holding position. That is only
true because the buses are separate, which is one more thing the split bought.


## What belongs in the RTL: the rule, and mastering as the worked example

**Deadline, not difficulty.** A thing lives in the metronome if its deadline is
shorter than the USB round trip. Everything else lives on the host, where it can
be changed without a bitstream and tested without a bench.

Mastering splits cleanly along that line, and it splits three ways rather than
two:

| | where | why |
|---|---|---|
| mastering **state** | already cyclic, free | statusword bits 14/15 ride TPDO1; the metronome sees it every cycle without asking |
| mastering **fault reaction** | **RTL** | a reference lost mid-run must stop the arm now, in the same fault domain as a bus drop — no host round trip |
| mastering **command and policy** | host | a dozen times in a machine's life, no deadline, all judgement, 34 tests that run in 0.2 s |

The third row is what an "API in RTL" would be, and it is the row with no
deadline in it. It is also the row that generalises straight into parameter
save, identity, LSS and a 27 kB firmware download — at which point the SDO
engine exists anyway and baking any single command was work done twice.

The second row is currently **missing from this design** and should not be:
losing a reference mid-run is a fault, and faults belong to the metronome.


## Correction: three transfer types, not three channels over two endpoints

An earlier section of this document proposed multiplexing cyclic, acyclic and
control traffic over the two interrupt endpoints, with a software rule that an
acyclic request must never delay a cyclic window. **That was solving a problem
USB already solves, in hardware, and solving it worse.**

USB has four transfer types because traffic has different needs, and this
device's traffic is a textbook three-way split:

| traffic | type | why that one |
|---|---|---|
| trajectory windows, feedback | **isochronous** | guaranteed bandwidth and service interval, **no retry** — and a retried trajectory window is stale garbage, so retry is not merely unnecessary, it is wrong |
| SDO / LSS / NMT tunnel | **bulk** | delivery guaranteed, latency irrelevant, bursty |
| status, faults, mode | **interrupt** | small, must not be lost, must not wait |

The payoff is larger than tidiness. **A host controller schedules periodic
transfers first, in the guaranteed portion of every (micro)frame, and lets bulk
fill what is left.** So a 27 kB firmware download on a bulk endpoint *cannot*
delay a trajectory window on an isochronous one — not by policy, by the host
controller's scheduler. The multiplexing rule this document previously invented
is deleted, and what replaces it is stronger.

### Endpoint map

```
EP0       control     enumeration; vendor requests for mode, rate, config
EP1 OUT   isoc        trajectory windows
EP2 IN    isoc        feedback
EP3 OUT   bulk        tunnel down  — SDO / LSS / NMT frames, tagged by bus
EP4 IN    bulk        tunnel up    — responses, EMCY, heartbeat
EP5 IN    interrupt   status and faults, bInterval 1
```

Six endpoints. Legal at full speed, legal at high speed, and each class gets
the error semantics it actually wants: isoc drops rather than stalls, bulk
retries until it lands, interrupt retries within a bounded window.

### Four spec-correctness details that are usually got wrong

**1. Isochronous bandwidth is reserved at `SET_INTERFACE`, so it belongs on an
alternate setting.** A device that declares isoc endpoints in altsetting 0 can
fail enumeration when the bus cannot reserve the bandwidth. The correct pattern
is altsetting 0 with no isoc at all, altsetting 1 with the streams.

That maps exactly onto the per-bus mode split this document already needs:

* **altsetting 0** — commissioning. Control, bulk and interrupt only. LSS,
  node-id assignment, firmware download, identity. No cyclic traffic, no
  reserved bandwidth, and the arm is not moving.
* **altsetting 1** — operational. Isoc streams live.

Two things that were designed separately turn out to be the same switch.

**2. The isoc OUT endpoint is an asynchronous sink, and the spec has a
mechanism for it.** The metronome owns the clock; the host's SOF clock is a
different oscillator. Over minutes they drift, and the look-ahead buffer either
starves or overruns. USB's first-class answer is an **explicit feedback
endpoint** — the device tells the host how fast to actually send.

That is precisely the buffer-occupancy problem this document raised as a thing
to invent. Carrying occupancy in the feedback stream is simpler and works;
knowing the standard mechanism exists is the difference between choosing not to
use it and not knowing about it.

**3. `bInterval` means different things at full and high speed.** At FS it is
frames — milliseconds, 1..255. At HS it is `2^(bInterval-1)` microframes. The
same descriptor byte is **8× different** across a PHY change, and a device
carried over unchanged runs eight times faster than intended.

**4. Vendor class is right, but ship the OS descriptors.** There is no USB
class for motion control, so `0xFF` is correct. Add a **BOS descriptor with
Microsoft OS 2.0 descriptors** so it binds WinUSB with no driver — the modern
way to ship a vendor device, and free.

### The performance envelope, and where the ceiling actually is

| | service interval | practical throughput |
|---|---|---|
| FS interrupt, MPS 64 | 1 ms | 64 kB/s — **what is built today** |
| FS isoc, MPS 512 | 1 ms | ~512 kB/s each way (1350 B/frame periodic budget) |
| FS isoc, MPS 1023 | 1 ms | ~1 MB/s, one direction only — both will not fit |
| HS isoc, MPS 1024 ×3 | 125 µs | ~24 MB/s |
| HS bulk, MPS 512 | 125 µs | ~40 MB/s |

Against a requirement of **28 kB/s each way** at 500 Hz.

**Bandwidth is not the constraint and never was.** Even full-speed isochronous
over-provisions the cyclic stream by 20×. The constraint is **latency
granularity**: full speed services an endpoint once per millisecond, so a
feedback → host → command path is ~3 ms worst case. High speed makes it ~375 µs.

So the honest recommendation:

* **Full speed with the endpoint map above is sufficient for V1** and is a
  descriptor change, not a board change. It is a 10× headroom improvement over
  today for free, and it deletes the multiplexing rule.
* **High speed is the upgrade that buys latency, not bandwidth** — worth it if a
  loop ever needs the host inside it, or for high-rate trace. It costs an
  external ULPI PHY (USB3300 / TUSB1210) on a PMOD, because the ECP5 has no
  hard USB PHY; LUNA is the obvious core. A board addition, not a redesign.

### Two practical notes

Isochronous through libusb on macOS requires the async API and is fiddlier than
interrupt. The shipping host is Linux, where it is routine; the Mac is the
development box, and that asymmetry is worth knowing before it is discovered.

And the road not taken, stated once so it is on the record: if the goal were
purely the highest envelope, a raw layer-2 gigabit Ethernet link gives 125 µs
cycles, 100 m of cable and galvanic isolation, and is what industrial motion
actually uses. USB is decided, and both FS and HS clear the requirement by an
order of magnitude, so this is a footnote rather than a recommendation.


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
5. **Mid-run reference loss joins the metronome's fault domain.** Missing from
   the mastering work, which put every refusal at admission; a reference lost
   while the arm is moving is a fault, and faults do not wait for the host.

The `joint_settings` addition is unchanged but gains a field: an axis is
`{bus, node_id}`, and the bus is now a port on the metronome.


## Open

1. ~~**Full speed or high speed.**~~ Full speed with the corrected endpoint map
   is sufficient for V1 and is a descriptor change, not a board change. High
   speed buys latency granularity, not bandwidth, and costs an external ULPI
   PHY. Decide when a loop needs the host inside it.
2. **Look-ahead depth**, and whether it is fixed or negotiated at attach.
   Related: explicit feedback endpoint, or occupancy carried in the stream.
3. **Cycle rate.** 500 Hz for motion, dropping to 250 Hz or commissioning mode
   for bulk acyclic work &mdash; the rate is a mode, not a constant.
4. **Where STO physically lands** on the MKS boards: enable input, or a
   contactor in the bus supply. Still the most important unanswered hardware
   question in the project.
