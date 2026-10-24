defmodule EMotion.Pendant.DisplayStock do
  @moduledoc """
  ILI9341 320x240 TFT on the PiBot Pendant V4.2, over AtomVM's stock `spi`
  port driver. Pure Elixir, no custom VM component.

  Fallback for running on a stock AtomVM image. The firmware normally uses
  `EMotion.Pendant.Display`, backed by avmgl-rs's `spi_lcd` NIFs, which needs
  the pendant VM build (README.md). Kept because it is the reference the
  NIF driver's init values came from, and it runs with no VM rebuild.

  ## Wiring

  From the ESP3D-X hardware page for this pendant, controller identity from
  the stock firmware (`ili9341_init()` through esp_lcd SPI):

  | signal | GPIO | note                                         |
  |--------|------|----------------------------------------------|
  | SCLK   | 14   | HSPI (SPI2) native pins                      |
  | MOSI   | 13   |                                              |
  | MISO   | 12   | also the flash-voltage strap; input only     |
  | CS     | 15   |                                              |
  | DC     | 2    | low = command, high = data                   |
  | BL     | 21   | backlight enable                             |
  | RST    | -    | not routed to a GPIO; software reset instead |

  ## Transfer size

  The ESP32 build initialises the bus with DMA and `max_transfer_sz = 0`,
  i.e. the IDF default of 4092 bytes per transaction, so pixel data goes out
  in `@chunk_bytes` pieces.

  ## Memory

  No PSRAM on this module: a 320x240 RGB565 frame is 150 KB, more than the
  BEAM heap can spare. Everything here is rectangle fills streamed in
  chunks; nothing holds a framebuffer.
  """

  import Bitwise

  # AtomVM-only modules; absent on the host compiler.
  @compile {:no_warn_undefined, [:spi, :gpio]}

  @sclk 14
  @mosi 13
  @miso 12
  @cs 15
  @dc 2
  @bl 21

  # Portrait: the pendant is held with the screen above the buttons and
  # handwheel, so the panel's long axis is vertical.
  @width 240
  @height 320

  # Under the 4092-byte DMA limit, and even so a chunk never splits a pixel.
  @chunk_bytes 4000

  # MADCTL 0x48 = MX | BGR: portrait, origin top-left as the pendant is held
  # (screen above the buttons and handwheel). Found on hardware 2026-10-23:
  #   0x28 (MV|BGR): bars ran top to bottom, x = 0 at the top -> drop MV
  #   0x08 (BGR):    portrait, but mirrored, (0, 0) top-right   -> add MX
  # BGR confirmed by red showing as cyan (its inverse) before INVON, not
  # yellow.
  @madctl 0x48

  @type t :: %{spi: port()}

  @doc "Open SPI, drive DC and backlight, run the ILI9341 init sequence."
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    clock = Keyword.get(opts, :clock_hz, 20_000_000)
    madctl = Keyword.get(opts, :madctl, @madctl)

    :gpio.set_pin_mode(@dc, :output)
    :gpio.set_pin_mode(@bl, :output)
    :gpio.digital_write(@bl, :low)

    spi =
      :spi.open(
        bus_config: [sclk: @sclk, mosi: @mosi, miso: @miso, peripheral: "spi2"],
        device_config: [
          lcd: [cs: @cs, clock_speed_hz: clock, mode: 0, address_len_bits: 0, command_len_bits: 0]
        ]
      )

    d = %{spi: spi}
    init(d, madctl)
    d
  end

  @doc "Backlight on or off."
  @spec backlight(boolean()) :: :ok
  def backlight(true), do: :gpio.digital_write(@bl, :high)
  def backlight(false), do: :gpio.digital_write(@bl, :low)

  def width, do: @width
  def height, do: @height

  @doc "RGB565 from 8-bit components."
  @spec rgb(0..255, 0..255, 0..255) :: 0..0xFFFF
  def rgb(r, g, b), do: (r &&& 0xF8) <<< 8 ||| (g &&& 0xFC) <<< 3 ||| b >>> 3

  @doc "Fill a rectangle with one RGB565 colour. Clipped to the screen."
  @spec fill_rect(t(), integer(), integer(), integer(), integer(), 0..0xFFFF) :: :ok
  def fill_rect(d, x, y, w, h, color) do
    x0 = max(x, 0)
    y0 = max(y, 0)
    x1 = min(x + w, @width) - 1
    y1 = min(y + h, @height) - 1

    if x1 < x0 or y1 < y0 do
      :ok
    else
      set_window(d, x0, y0, x1, y1)
      pixels = (x1 - x0 + 1) * (y1 - y0 + 1)
      stream_color(d, color, pixels * 2)
    end
  end

  @doc "Fill the whole screen."
  def clear(d, color), do: fill_rect(d, 0, 0, @width, @height, color)

  ## ILI9341

  defp init(d, madctl) do
    # SWRESET, then the datasheet's 5 ms before any command and 120 ms
    # before SLPOUT. Generous here: no hardware reset line to fall back on.
    command(d, 0x01)
    sleep(150)
    # SLPOUT
    command(d, 0x11)
    sleep(120)
    # COLMOD: 16 bit/pixel on the MCU interface
    command(d, 0x3A, <<0x55>>)
    # MADCTL
    command(d, 0x36, <<madctl>>)
    # Normal display mode. INVON: this panel shows every colour inverted
    # with inversion off (white for black, cyan for red), so its native
    # sense is inverted.
    command(d, 0x13)
    command(d, 0x21)
    # DISPON
    command(d, 0x29)
    sleep(20)
    :ok
  end

  defp set_window(d, x0, y0, x1, y1) do
    # CASET, PASET, then RAMWR leaves the controller expecting pixel data.
    command(d, 0x2A, <<x0::16, x1::16>>)
    command(d, 0x2B, <<y0::16, y1::16>>)
    command(d, 0x2C)
  end

  defp command(d, cmd, params \\ <<>>) do
    :gpio.digital_write(@dc, :low)
    :ok = :spi.write(d.spi, :lcd, %{write_data: <<cmd>>})

    if params != <<>> do
      :gpio.digital_write(@dc, :high)
      :ok = :spi.write(d.spi, :lcd, %{write_data: params})
    end

    :ok
  end

  # DC is already high after RAMWR's (empty) parameter phase is skipped, so
  # set it explicitly before streaming.
  defp stream_color(d, color, bytes) do
    :gpio.digital_write(@dc, :high)
    chunk = repeat(<<color::16>>, div(min(bytes, @chunk_bytes), 2))
    stream(d, chunk, bytes)
  end

  defp stream(_d, _chunk, 0), do: :ok

  defp stream(d, chunk, bytes) do
    n = min(byte_size(chunk), bytes)
    data = if n == byte_size(chunk), do: chunk, else: binary_part(chunk, 0, n)
    :ok = :spi.write(d.spi, :lcd, %{write_data: data})
    stream(d, chunk, bytes - n)
  end

  # Doubling, so a 2000-pixel chunk is 11 concatenations, not 2000.
  defp repeat(unit, 1), do: unit

  defp repeat(unit, n) do
    half = repeat(unit, div(n, 2))
    if rem(n, 2) == 0, do: half <> half, else: half <> half <> unit
  end

  defp sleep(ms) do
    receive do
    after
      ms -> :ok
    end
  end

  ## Test pattern

  @doc """
  Eight vertical bars, left to right: red, green, blue, white, yellow, cyan,
  magenta, black, plus a red 20x20 square with a white border at (0, 0),
  which is top-left as the pendant is held.

  If it ever reads differently (another panel batch, a different MADCTL):
  bars in the wrong order or mirrored means the axis bits are wrong; red
  and blue swapped means the BGR bit is wrong; every colour inverted means
  INVON/INVOFF; the corner square shows where (0, 0) actually is.
  """
  def test_pattern(d) do
    bars = [
      rgb(255, 0, 0),
      rgb(0, 255, 0),
      rgb(0, 0, 255),
      rgb(255, 255, 255),
      rgb(255, 255, 0),
      rgb(0, 255, 255),
      rgb(255, 0, 255),
      rgb(0, 0, 0)
    ]

    bar_w = div(@width, length(bars))
    draw_bars(d, bars, 0, bar_w)

    fill_rect(d, 0, 0, 20, 20, rgb(255, 255, 255))
    fill_rect(d, 2, 2, 16, 16, rgb(255, 0, 0))
    :ok
  end

  # Plain recursion: AtomVM's bundled Elixir Enum is a subset, and
  # Enum.with_index/1 is not in it.
  defp draw_bars(_d, [], _i, _w), do: :ok

  defp draw_bars(d, [c | rest], i, w) do
    fill_rect(d, i * w, 0, w, @height, c)
    draw_bars(d, rest, i + 1, w)
  end
end
