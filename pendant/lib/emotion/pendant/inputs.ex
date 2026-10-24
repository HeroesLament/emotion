defmodule EMotion.Pendant.Inputs do
  @moduledoc """
  The pendant's physical inputs, as messages to an owner process.

      {:inputs, :jog, delta}               # quadrature edges, signed
      {:inputs, :button, index, :down | :up}
      {:inputs, :band, value}              # 3-bit raw code from the band switch
      {:inputs, :pot, raw}                 # 12-bit ADC1 reading, with hysteresis

  ## Pins (esp3d.io pibot-pendant-v1 map)

    * MPG A 22, B 27. No pull-ups on the board; the PCNT driver enables the
      internal ones.
    * Buttons 4, 16, 17, internal pull-ups, active low assumed.
    * Band switch 34, 35, 39. Input-only pads with no internal pulls; the
      board has external pull-ups.
    * Pot 33 (ADC1 channel 5).

  ## Mechanism

  Encoder: decoded x4 in hardware by a PCNT unit (avmgl-rs `pcnt` NIFs,
  pendant VM build only) and polled every 10 ms; each non-zero delta is
  one `:jog` message. B leading A counts up, as the old state table did.

  The first cut decoded in Erlang: an interrupt on either edge read both
  pins and stepped a state table. The pins were read when the message was
  handled, not when the edge happened, so once two edges fell inside that
  latency a fast spin lost steps (double step, counted 0) or ran backwards
  (triple step). PCNT counts every edge; polling latency now only delays
  the report.

  Buttons and band switch: an edge arms a settle timer; when it fires the
  whole group is re-read and only real changes are reported. That absorbs
  contact bounce and the ESP32 GPIO36/39 glitch (errata 3.11: a short low
  pulse on 36/39 when the ADC powers up), which would otherwise land on the
  band switch's GPIO39 every pot sample.
  """

  import Bitwise

  @compile {:no_warn_undefined, [:gpio, :esp_adc, :pcnt]}

  @enc_a 22
  @enc_b 27
  @buttons [4, 16, 17]
  @band [34, 35, 39]
  @pot 33

  @settle_ms 15
  @pot_ms 100
  @pot_hyst 24

  # PCNT poll period. Only latency: the hardware keeps counting between
  # polls, and a 16-bit unit with overflow accumulation cannot be outrun.
  @jog_ms 10

  # Pulses narrower than this are ignored by the PCNT filter (max ~12.7 us).
  @glitch_ns 1000

  @doc "Start the input process, reporting to `owner`. Returns its pid."
  def start_link(owner), do: spawn_link(fn -> init(owner) end)

  defp init(owner) do
    gpio = :gpio.start()

    # Encoder pins belong to PCNT: no gpio mode, pull or interrupt here.
    :ok = :pcnt.quadrature(@enc_a, @enc_b, @glitch_ns)

    for pin <- @buttons do
      :gpio.set_pin_mode(pin, :input)
      :gpio.set_pin_pull(pin, :up)
    end

    for pin <- @band, do: :gpio.set_pin_mode(pin, :input)

    for pin <- @buttons ++ @band do
      :ok = :gpio.set_int(gpio, pin, :both)
    end

    pot = open_pot()

    st = %{
      owner: owner,
      buttons: read_buttons(),
      band: read_band(),
      pot: pot,
      pot_raw: sample_pot(pot),
      settle_buttons: false,
      settle_band: false
    }

    send(owner, {:inputs, :ready, %{buttons: st.buttons, band: st.band, pot: st.pot_raw}})

    if pot != nil, do: :erlang.send_after(@pot_ms, self(), :pot)

    # Discard anything counted between unit start and ready.
    _ = :pcnt.take()
    :erlang.send_after(@jog_ms, self(), :jog)

    loop(st)
  end

  defp loop(st) do
    receive do
      :jog ->
        :erlang.send_after(@jog_ms, self(), :jog)
        poll_jog(st.owner)
        loop(st)

      {:gpio_interrupt, pin} ->
        loop(arm(st, pin))

      :settle_buttons ->
        loop(settle_buttons(st))

      :settle_band ->
        loop(settle_band(st))

      :pot ->
        :erlang.send_after(@pot_ms, self(), :pot)
        loop(poll_pot(st))
    end
  end

  ## Encoder

  defp poll_jog(owner) do
    case :pcnt.take() do
      0 -> :ok
      d when is_integer(d) -> send(owner, {:inputs, :jog, d})
    end
  end

  ## Buttons and band switch

  defp arm(st, pin) do
    cond do
      :lists.member(pin, @buttons) and not st.settle_buttons ->
        :erlang.send_after(@settle_ms, self(), :settle_buttons)
        %{st | settle_buttons: true}

      :lists.member(pin, @band) and not st.settle_band ->
        :erlang.send_after(@settle_ms, self(), :settle_band)
        %{st | settle_band: true}

      true ->
        st
    end
  end

  defp settle_buttons(st) do
    now = read_buttons()
    report_buttons(st.owner, st.buttons, now, 0)
    %{st | buttons: now, settle_buttons: false}
  end

  defp report_buttons(_owner, [], [], _i), do: :ok

  defp report_buttons(owner, [same | old], [same | new], i),
    do: report_buttons(owner, old, new, i + 1)

  defp report_buttons(owner, [_ | old], [down | new], i) do
    send(owner, {:inputs, :button, i, if(down, do: :down, else: :up)})
    report_buttons(owner, old, new, i + 1)
  end

  # Active low: a pressed button pulls its pin to ground.
  defp read_buttons, do: for(pin <- @buttons, do: bit(pin) == 0)

  defp settle_band(st) do
    now = read_band()
    if now != st.band, do: send(st.owner, {:inputs, :band, now})
    %{st | band: now, settle_band: false}
  end

  # Bit 0 is GPIO34, bit 2 is GPIO39.
  defp read_band do
    [b0, b1, b2] = for pin <- @band, do: bit(pin)
    b2 <<< 2 ||| b1 <<< 1 ||| b0
  end

  ## Pot

  defp open_pot do
    try do
      {:ok, unit} = :esp_adc.init()
      {:ok, chan} = :esp_adc.acquire(@pot, unit)
      {unit, chan}
    catch
      kind, reason ->
        :io.format(~c"inputs: pot unavailable ~p:~p~n", [kind, reason])
        nil
    end
  end

  defp sample_pot(nil), do: nil

  defp sample_pot({unit, chan}) do
    case :esp_adc.sample(chan, unit, [:raw, {:samples, 16}]) do
      {:ok, {raw, _}} -> raw
      _ -> nil
    end
  end

  defp poll_pot(st) do
    raw = sample_pot(st.pot)

    if raw != nil and (st.pot_raw == nil or abs(raw - st.pot_raw) >= @pot_hyst) do
      send(st.owner, {:inputs, :pot, raw})
      %{st | pot_raw: raw}
    else
      st
    end
  end

  defp bit(pin) do
    case :gpio.digital_read(pin) do
      :high -> 1
      _ -> 0
    end
  end
end
