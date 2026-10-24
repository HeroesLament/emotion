defmodule EMotion.Pendant do
  @moduledoc """
  Firmware for the PiBot CNC Pendant V4.2, on AtomVM.

  The pendant is an operator device for an E-Motion controller: handwheel
  (MPG), band switch, three buttons, potentiometer and touchscreen, with the
  selector acting as enable. Commands reach the controller over an
  openSAFETY black channel (`OpenSafety`), and the controller, not the
  pendant, owns the stop: loss of SPDOs past the SCT drops it to a safe
  stop. See README.md.

  ## What start/0 currently runs

  Display bring-up through avmgl-rs's `spi_lcd` NIFs (timed full clear),
  then the input test screen: `EMotion.Pendant.Inputs` events drawn live,
  one widget per input, each redrawn only when its value changes. Events
  that arrive during a redraw are drained and folded into the next one, so
  a fast handwheel spin costs one redraw per frame, not one per edge.
  """

  alias EMotion.Pendant.{Display, Inputs}

  import Bitwise

  @bg 0x000000
  @panel 0x101828
  @dim 0x808080
  @fg 0xE0E0E0

  @doc "AtomVM entry point."
  def start do
    :io.format(~c"emotion_pendant ~s booting~n", [version()])

    :ok = Display.open()

    t0 = now()
    Display.clear(@bg)
    :io.format(~c"display: full clear ~b ms~n", [now() - t0])

    Display.update(frame())
    Display.backlight(true)

    _ = Inputs.start_link(self())

    receive do
      {:inputs, :ready, init} ->
        st = %{jog: 0, band: init.band, buttons: init.buttons, pot: init.pot, events: 0}
        :io.format(~c"inputs: ready band=~b buttons=~p pot=~p~n", [st.band, st.buttons, st.pot])
        Display.update(widgets(nil, st))
        loop(st)
    end
  end

  defp loop(st) do
    receive do
      msg ->
        st2 = drain(apply_event(st, msg))
        t0 = now()
        Display.update(widgets(st, st2))
        log(st, st2, now() - t0)
        loop(st2)
    end
  end

  defp drain(st) do
    receive do
      msg -> drain(apply_event(st, msg))
    after
      0 -> st
    end
  end

  defp apply_event(st, {:inputs, :jog, d}), do: bump(%{st | jog: st.jog + d})
  defp apply_event(st, {:inputs, :band, b}), do: bump(%{st | band: b})
  defp apply_event(st, {:inputs, :pot, raw}), do: bump(%{st | pot: raw})

  defp apply_event(st, {:inputs, :button, i, edge}),
    do: bump(%{st | buttons: set_nth(st.buttons, i, edge == :down)})

  defp apply_event(st, other) do
    :io.format(~c"pendant: unexpected ~p~n", [other])
    st
  end

  defp bump(st), do: %{st | events: st.events + 1}

  defp log(old, new, ms) do
    if old.band != new.band or old.buttons != new.buttons or old.pot != new.pot or
         old.jog != new.jog do
      :io.format(~c"jog=~b band=~b buttons=~p pot=~p (draw ~b ms)~n", [
        new.jog,
        new.band,
        new.buttons,
        new.pot,
        ms
      ])
    end
  end

  ## Screen

  defp frame do
    [
      {:rect, 0, 0, 240, 30, @panel},
      {:text, 8, 8, 2, @fg, ~c"E-MOTION INPUTS"},
      {:text, 8, 36, 1, @dim, ~c"MPG"},
      {:text, 8, 106, 1, @dim, ~c"BAND SWITCH  34/35/39"},
      {:text, 8, 146, 1, @dim, ~c"BUTTONS  4/16/17"},
      {:text, 8, 216, 1, @dim, ~c"POT  33"}
    ]
  end

  # Widgets whose value changed since `old` (all of them when old is nil).
  defp widgets(old, new) do
    changed(old, new, :jog, &jog/1) ++
      changed(old, new, :band, &band/1) ++
      changed(old, new, :buttons, &buttons/1) ++
      changed(old, new, :pot, &pot/1) ++
      changed(old, new, :events, &events/1)
  end

  defp changed(nil, new, key, draw), do: draw.(:maps.get(key, new))

  defp changed(old, new, key, draw) do
    v = :maps.get(key, new)
    if :maps.get(key, old) == v, do: [], else: draw.(v)
  end

  defp jog(edges) do
    [
      {:rect, 0, 48, 240, 52, @bg},
      {:text, 8, 50, 4, 0xFFFFFF, signed(edges)},
      {:text, 8, 84, 2, @dim, ~c"DETENT " ++ signed(div(edges, 4))}
    ]
  end

  defp band(b) do
    bits = [?0 + (b >>> 2 &&& 1), ?0 + (b >>> 1 &&& 1), ?0 + (b &&& 1)]

    [
      {:rect, 0, 118, 240, 24, @bg},
      {:text, 8, 120, 3, 0xFFC040, itoa(b) ++ ~c"  " ++ bits}
    ]
  end

  defp buttons(list), do: button_boxes(list, 0, [])

  defp button_boxes([], _i, acc), do: acc

  defp button_boxes([down | rest], i, acc) do
    x = 8 + i * 78
    colour = if down, do: 0x20C040, else: 0x303030

    button_boxes(rest, i + 1, acc ++
      [{:rect, x, 158, 70, 50, colour}, {:text, x + 20, 172, 3, @fg, ~c"B" ++ itoa(i + 1)}])
  end

  defp pot(nil), do: [{:rect, 0, 228, 240, 50, @bg}, {:text, 8, 240, 2, @dim, ~c"N/A"}]

  defp pot(raw) do
    w = max(div(raw * 224, 4095), 1)

    [
      {:rect, 0, 228, 240, 50, @bg},
      {:rect, 8, 230, 224, 20, 0x202020},
      {:rect, 8, 230, w, 20, 0x2060FF},
      {:text, 8, 256, 2, @fg, itoa(raw)}
    ]
  end

  defp events(n) do
    [
      {:rect, 0, 296, 240, 24, @panel},
      {:text, 8, 302, 2, @dim, ~c"EVENTS " ++ itoa(n)}
    ]
  end

  ## Helpers

  defp set_nth([_ | rest], 0, v), do: [v | rest]
  defp set_nth([h | rest], i, v), do: [h | set_nth(rest, i - 1, v)]

  defp signed(n) when n > 0, do: ~c"+" ++ itoa(n)
  defp signed(n), do: itoa(n)

  defp now, do: :erlang.system_time(:millisecond)

  defp itoa(n), do: :erlang.integer_to_list(n)

  defp version, do: ~c"0.3.0"
end
