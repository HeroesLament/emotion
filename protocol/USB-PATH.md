# The USB path: where full speed ends, and what high speed would cost

Status: UNDERSTANDING, not a plan. Nothing here is scheduled; implementation
happens elsewhere. This records what was measured about the EHDL USB stack
(`~/src/ehdl`) so the next person does not have to re-derive it.

Read `METRONOME.md` first for why the link matters and what rides on it.

**Before any of this is acted on**: `docs/INTRODUCTION.md` still describes the
host link as **SPI** (CM5 → SPI → ECP5), and `apps/metronome` describes it as
USB. If SPI is the intent, the entire contents of this document are moot — SPI
has no frame quantisation, is full duplex, and the ECP5 pads handle it without
argument. Settle that fork first.


## 1. Where the ceiling is, and why it is not the ECP5's fault

`lib/hw/std/usb/fs_phy.ex` — 641 lines — does bit-level USB in fabric:

* 48 MHz clock, **4 cycles per bit** at 12 Mbit/s;
* edge-triggered clock recovery, re-centering the sample counter on transitions;
* majority-vote glitch filter on `dp_diff` / `dn_raw`;
* full SYNC validation (KJKJKJKK), NRZI encode/decode, bit stuffing, and EOP as
  two SE0 bit periods;
* D+/D− driven straight off LVCMOS33 pads.

That technique cannot reach high speed, for **two independent reasons**, and
only one of them is about sample rates:

1. **Rate.** 4× oversampling of 480 Mbit/s is 1.92 GHz. The fabric will not.
2. **Electricals, which is the decisive one.** High speed is not CMOS
   signalling at all. It is **current-mode**: a 17.78 mA source into 45 Ω
   terminations, ~400 mV differential swing, with squelch detection, disconnect
   detection and the chirp handshake. That is an analog front end. **No FPGA
   general-purpose IO can produce or receive it** — this is true of every FPGA
   without a hard USB PHY, not a limitation of the ECP5.

So: fabric-only USB tops out at full speed, permanently. If somebody previously
said "the pads don't really support it", that is correct and this is why.


## 2. High speed inverts the difficulty: the PHY gets *easier*

The intuition to discard is that HS means "the same PHY, but harder". It does
not. HS means an **external PHY over ULPI**, and ULPI hands the design bytes.

| | full speed, today | high speed, via ULPI |
|---|---|---|
| interface | D+/D− at CMOS levels | 8-bit data, 60 MHz clock, `dir` / `stp` / `nxt` |
| NRZI | in fabric | in the PHY |
| bit stuffing | in fabric | in the PHY |
| clock recovery | in fabric, edge-triggered | in the PHY |
| SYNC / EOP | in fabric | in the PHY |
| chirp, squelch, disconnect | n/a | in the PHY |
| clock source | local PLL, trimmed | **PHY sources the 60 MHz** |

Two whole components stop being needed:

* **`fs_phy.ex` (641 lines)** is replaced by a ULPI turnaround state machine —
  register read/write, `dir` handover, `nxt` flow control, RX command decode.
  Call it 200–300 lines and conceptually much simpler, because every hard part
  moved into the chip.
* **`clock_trim.ex` (254 lines)** becomes unnecessary. It exists because full
  speed requires ±2500 ppm on a locally-synthesised 48 MHz, and it disciplines
  the PLL against SOF intervals. With ULPI the PHY *sources* the clock from its
  own crystal and the whole USB domain is PHY-clocked. The ppm problem is
  deleted rather than solved.

60 MHz SDR on ECP5-85F pads is unremarkable; it is not where the risk is.


## 3. The SIE is the work. Specifically, this:

`lib/hw/std/usb/sie.ex` — 660 lines — is **bit-serial**, and that is the change
everything else follows from. The evidence is in its own ports:

```elixir
input  :phy_rx_valid,   1
input  :phy_rx_data,    1      # one BIT
input  :phy_rx_bit0,    1      # PID bit-0 alignment strobe from PHY
input  :phy_rx_pid_done, 1     # PID last-bit strobe
...
wire :bit_cnt,    4    # assembling
wire :byte_shift, 8    # bytes from bits
```

ULPI delivers a byte per clock. So:

### 3.1 Datapath: bit-serial → byte-parallel

* `phy_rx_data` and `phy_tx_data` widen 1 → 8.
* `bit_cnt`, `byte_shift` and the PID alignment strobes (`phy_rx_bit0`,
  `phy_rx_pid_done`) **disappear**. Byte alignment is a given, not a thing to
  recover.
* `phy_tx_ready` is replaced by ULPI's `nxt` (PHY accepts a byte) and `stp`
  (link ends the packet), with `dir` arbitrating bus ownership.

### 3.2 CRC must go parallel — this is the largest single item

`crc16.ex` (104 lines) and `crc5.ex` (77 lines) are bit-serial, one bit per
clock. At byte-wide they must consume 8 bits per clock. The transform is
standard — unroll eight bit-steps into combinational logic — but it is a
rewrite of both, and the SIE's shared-CRC muxing (`crc16_reg` comb-muxed
between RX and TX) changes shape with them.

CRC5 matters more than it looks: it validates tokens, and the HS turnaround
budget leaves far fewer clocks to decide whether to answer. A bit-serial CRC5
needing 11 clocks on a token that arrived in 2 is not viable.

### 3.3 Frame structure and new protocol

* **Microframes.** SOF every 125 µs, not 1 ms. Anything counting frames counts
  8× as often.
* **PING / NYET.** High speed adds a flow-control handshake for control and
  bulk OUT that full speed does not have. The SIE's handshake PID set grows.
* **High-bandwidth endpoints.** Up to 3 transactions per microframe for
  interrupt and isochronous, sequenced with DATA0/DATA1/DATA2/MDATA. This is
  **optional** — skipping it costs bandwidth nobody needs here and removes
  MDATA entirely. Recommend skipping it in a first HS SIE.
* **Reset and chirp.** The PHY performs the chirp handshake, but the link must
  drive the ULPI function-control register to select HS, and must react to
  reset and suspend indications delivered as RX commands.

### 3.4 Timing

Full speed gives the SIE 4 clocks per bit — 32 per byte — to think. ULPI gives
it **one clock per byte**. Every state that currently gets a comfortable number
of cycles between events gets one. This is the part that will not port; it has
to be re-timed.

### 3.5 What survives untouched

`Hw.Interface.USBEndpointIn` and `USBEndpointOut` are **already byte-oriented**
(`data` is 8 bits, `valid`/`ready`/`pkt_end` are byte-rate). So the layers above
— `vendor_interrupt.ex` (715 lines), `cdc_serial.ex` (742) and the enumeration
and descriptor machinery — should cross a PHY change **unchanged**.

That is the payoff of having built this as components behind interfaces, and it
is worth saying out loud: roughly 1,450 lines of upper layer are insulated from
the entire question by an interface that happens to have been drawn in the
right place.

### 3.6 The simulator gets simpler, and it is the reason this is tractable

`lib/hw/sim/usb_host.ex` (592 lines) bit-bangs `dp_raw`/`dn_raw` at 4 clocks
per bit, NRZI-encoded, to drive enumeration in the native simulator.

For HS it would be rewritten to drive the **ULPI pins** instead — byte-level,
no NRZI, no bit stuffing, no 4×-oversampled edges. The host model gets *easier*
for the same reason the PHY does.

Which means an HS SIE is developable and testable in ExUnit **before any PHY
chip exists**. That is what turns high speed from a hardware gamble into a
software task with a hardware tail, and it is the strongest argument that this
is possible at all.


## 4. The cheaper win, which should happen first: full-speed isochronous

The requirement is **28 kB/s each way** at 500 Hz (see `METRONOME.md`). Today's
two interrupt endpoints give 64 kB/s. Full-speed **isochronous** gives ~512 kB/s
each way within the 1350 B/frame periodic budget — roughly 20× the requirement,
with no new silicon.

And in this SIE, isochronous is mostly a **subtraction**:

* no handshake phase at all — token, data, done. The ACK/NAK/STALL branch is
  skipped for isoc endpoints;
* no data toggle — full-speed isochronous is DATA0 only;
* no retransmission.

The additions are small:

* endpoint buffer grows from 64 to up to 1023 bytes — BRAM, and an 85F has
  ~3.7 Mbit of it;
* `SET_INTERFACE` and alternate settings, so isoc bandwidth is declared in
  altsetting 1 and altsetting 0 stays quiet. (That switch is also the
  commissioning-vs-operational mode `METRONOME.md` needs — the same control.)
* descriptor changes: `bmAttributes` transfer type, MPS, and the sync/usage
  type bits.

### One real conflict to resolve, not to discover later

`USBEndpointIn`'s documented contract says:

> If the host NAKs or the ACK is lost, SIE retransmits on the next IN token
> automatically (data is still buffered).

**That is exactly wrong for isochronous.** There is no ACK, and stale data must
be *replaced* at the next interval rather than retransmitted — a retransmitted
trajectory window is the failure this transfer type was chosen to avoid. The
interface needs an isoc mode where `done` pulses **on transmission** rather than
on acknowledgement, and where an unloaded buffer transmits a zero-length packet
rather than NAKing.


## 5. Board reality

* ULX3S has **no ULPI PHY**. Adding one means 12 signals at 60 MHz across the
  GP header to a breakout — marginal for signal integrity on a pin header, and
  the fiddliest part of the whole exercise. On a purpose-built metronome PCB it
  is routine.
* Candidate PHYs: **USB3300** (Microchip) or **TUSB1210** (TI). Both are
  ordinary 8-bit ULPI at 60 MHz.
* ECP5 SERDES is not a path. The -5G's 5 Gbps lanes cannot do USB 2.0 HS (wrong
  electrical layer entirely), and USB 3.0 device IP for ECP5 is not practical.


## 6. Where this sits

1. **Settle SPI vs USB.** If the metronome sits on the CM5 carrier, SPI beats
   both full and high speed and none of section 1–3 matters.
2. **If USB: full-speed isochronous.** Biggest ratio of benefit to work, no new
   hardware, and mostly deleting code paths for the endpoints that want it.
3. **High speed only if a loop ever needs the host inside it** — which the
   boundary in `METRONOME.md` argues it should not. If that changes, the path is
   ULPI front-end → parallel CRC → re-timed SIE → external PHY → custom board,
   and the simulator makes it tractable rather than speculative.

Bandwidth is not why anyone would do this. **Latency granularity is**: full
speed services an endpoint once per millisecond, high speed once per 125 µs.


## Incidental

`vendor_interrupt.ex`'s descriptor block still carries `bDeviceClass = 0x02`
(CDC) and `idProduct = 0x0001`, inherited from the CDC enumeration engine it was
forked from, while `Metronome.USB` asserts vendor class `0xFF` and PID `0x0002`.
The moduledoc says it is a bring-up copy, so this is probably known — noted
because the two do not match in the source as it stands.
