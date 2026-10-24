# E-Motion Pendant

AtomVM firmware for the PiBot CNC Pendant V4.2, used as the handheld
operator device for E-Motion controllers (first target: the 7x14 lathe).

Standalone project beside the umbrella, like `studio/`. It ships to the
pendant's ESP32 and nothing in `apps/` depends on it.

## Hardware (as found on the board)

| Item          | Known                                                     |
|---------------|-----------------------------------------------------------|
| MCU           | ESP32-WROOM-32E: classic ESP32, no PSRAM                  |
| Flash size    | unknown until `esptool flash_id`                          |
| USB           | USB-C to a USB-UART bridge (chip unread), auto-download   |
| Display       | ILI9341 240x320, SPI2 12/13/14/15, DC 2, BL 21, no RST    |
| Touch         | FPC1, capacitive, I2C (flex silkscreen: VDD GND RST INT)  |
| Link          | RJ12 UART on GPIO25/27; RX/TX swap by jumper caps         |
| Wireless link | external Bluetooth serial modules (not the ESP32's radio) |
| Power         | 18650 + IP5306; AMS1117-3.3                               |
| Other         | MPG encoder, band switch, pot, 3 buttons, speaker, microSD|

Do not run the RJ12 link with the 18650 fitted (PiBot warning: voltage
imbalance into the ESP32).

No PSRAM means no full framebuffer: 240x320 RGB565 is 150 KB. Drawing is
banded or dirty-rect only; the panel's GRAM is the framebuffer.

Panel settings found on the panel 2026-10-23 with a colour-bar and
corner-marker card: MADCTL 0x48 (MX | BGR, portrait, origin top-left as
held), INVON. Source of truth: avmgl-rs `src/spi_lcd/defs.rs`.

## Debug and development

USB only. JTAG (GPIO12-15) is routed to the display FPC, so it is not
available without giving up the panel.

* flash: esptool over the bridge; full image for AtomVM, AVM partition for
  this app
* console: UART0 on the same USB port
* native faults: panic gdbstub on UART0, core dump to flash
* probing: PCBite as a logic analyzer on FPC2/FPC1, encoder and RJ12 UART

UART0 carries console and gdbstub, so the controller link stays on the RJ12
UART.

## Board facts (read 2026-10-23)

* ESP32-D0WD-V3 rev v3.1, 8 MB flash, CH34x bridge (`/dev/cu.wchusbserial10`)
* flash encryption and secure boot off
* the link is unreliable above 115200: use `--baud 115200` for everything
* stock firmware (ESP3D-X, partition table at 0xC000) backed up to
  `stock/pibot_pendant_v42_stock_8MB.bin`, sha256 `39ef78b5...bcf19`,
  verified against the chip; not committed

## Flashing

VM image: `AtomVM-esp32-elixir-v0.7.0-beta.0.img` (in `images/`, not
committed). Erase first: stock data sits inside AtomVM's NVS range.

    P=/dev/cu.wchusbserial10
    esptool --port $P --baud 115200 erase-flash
    esptool --port $P --baud 115200 write-flash 0x1000 images/AtomVM-esp32-elixir-v0.7.0-beta.0.img

App, main.avm at 0x250000:

    mix atomvm.packbeam
    esptool --port $P --baud 115200 write-flash 0x250000 emotion_pendant.avm

Console (DTR/RTS low so opening the port does not reset the board):

    python3 -m serial.tools.miniterm --raw --dtr 0 --rts 0 $P 115200

Restore stock:

    esptool --port $P --baud 115200 write-flash 0 stock/pibot_pendant_v42_stock_8MB.bin

## Status

Pendant runtime built from the AtomVM fork (`build-pendant`, avmgl-rs with
the `spi_lcd` family) and flashed at 0x10000 (1627792 bytes, hash
verified). Firmware 0.2.0 boots on it and runs the input test screen
through `EMotion.Pendant.Display`.

Display timings from the console, 2026-10-23:

| Path                                 | Full clear | Widget redraw            |
|--------------------------------------|------------|--------------------------|
| `DisplayStock` (`:spi` port, 0.1.0)  | 208-210 ms | not measured             |
| `spi_lcd` NIF at 40 MHz (0.2.0)      | 33 ms      | 12-27 ms, mostly 17-18   |

The widget figure is the `draw N ms` line per input-screen update (1015
samples, 745 at or under 19 ms). The stock test pattern took 401 ms.
`DisplayStock` widget redraws were never timed, so the like-for-like gain
is the full clear: about 6x.
