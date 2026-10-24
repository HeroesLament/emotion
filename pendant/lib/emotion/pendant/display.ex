defmodule EMotion.Pendant.Display do
  @moduledoc """
  The pendant's ILI9341 240x320 panel through avmgl-rs's `spi_lcd` NIFs.

  Needs the pendant AtomVM build (avmgl-rs with the `spi_lcd` family; see
  README.md). On a stock image the NIFs are absent and `open/1` raises
  `undef`; `EMotion.Pendant.DisplayStock` is the pure-Elixir fallback.

  ## Drawing

  `update/1` takes the display list `esp_rgb:update/1` takes on the Plant
  7B, in paint order, colours RGB888:

      {:rect, x, y, w, h, 0xRRGGBB}
      {:pixel, x, y, 0xRRGGBB}
      {:text, x, y, scale, 0xRRGGBB, ~c"CHARS"}   # 5x7 glyphs, 6-cell advance

  There is no framebuffer (no PSRAM on this module): a `rect` is sent as an
  opaque region with everything drawn over it later in the list composed in,
  so a widget is "background rect, then its contents". Text with no rect
  under it in the same list is drawn transparently over what is on screen.

  ## Pins and controller settings

  Compiled into the NIF (avmgl-rs `src/spi_lcd/defs.rs`): SPI2 on 12/13/14/15,
  DC 2, MADCTL 0x48, INVON. The backlight (GPIO21) stays on this side so the
  firmware lights the panel only after the first frame.
  """

  @compile {:no_warn_undefined, [:spi_lcd, :gpio]}

  @bl 21
  @width 240
  @height 320

  @doc "Bring the panel up. `clock_hz:` overrides the NIF's 40 MHz default."
  @spec open(keyword()) :: :ok
  def open(opts \\ []) do
    :gpio.set_pin_mode(@bl, :output)
    :gpio.digital_write(@bl, :low)

    :ok =
      case Keyword.get(opts, :clock_hz) do
        nil -> :spi_lcd.init()
        hz -> :spi_lcd.init(hz)
      end
  end

  @spec backlight(boolean()) :: :ok
  def backlight(true), do: :gpio.digital_write(@bl, :high)
  def backlight(false), do: :gpio.digital_write(@bl, :low)

  def width, do: @width
  def height, do: @height

  @doc "Draw a display list."
  def update(list), do: :spi_lcd.update(list)

  @doc "Fill the screen, RGB888."
  def clear(rgb888), do: update([{:rect, 0, 0, @width, @height, rgb888}])

  ## Test card

  @bars [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF, 0xFFFF00, 0x00FFFF, 0xFF00FF, 0x000000]

  @doc """
  The bring-up card: the same eight bars and (0, 0) marker as the stock
  driver's pattern, plus a text panel, so one look confirms orientation,
  colour order and the glyph path together.
  """
  def test_card(lines) do
    bar_w = div(@width, length(@bars))

    bars = bar_rects(@bars, 0, bar_w, [])

    marker = [{:rect, 0, 0, 20, 20, 0xFFFFFF}, {:rect, 2, 2, 16, 16, 0xFF0000}]

    panel_y = 200
    panel = [{:rect, 0, panel_y, @width, @height - panel_y, 0x101828}]
    text = text_lines(lines, 8, panel_y + 8, [])

    update(bars ++ marker ++ panel ++ text)
  end

  defp bar_rects([], _i, _w, acc), do: :lists.reverse(acc)

  defp bar_rects([c | rest], i, w, acc),
    do: bar_rects(rest, i + 1, w, [{:rect, i * w, 0, w, 200, c} | acc])

  defp text_lines([], _x, _y, acc), do: :lists.reverse(acc)

  defp text_lines([l | rest], x, y, acc),
    do: text_lines(rest, x, y + 18, [{:text, x, y, 2, 0xE0E0E0, l} | acc])
end
