defmodule Exdash.Dashboard do
  @moduledoc """
  Mode-aware terminal dashboard for ExDrive CiA402 axes.

  Each axis renders a panel tuned to its current mode of operation:

    PP / CSP  — position panel: actual vs target, following error gauge,
                position sparkline showing approach curve
    PV / CSV  — velocity panel: bidirectional velocity gauge, torque as
                load indicator, velocity sparkline showing stability
    PT / CST  — torque panel: bidirectional torque gauge, velocity as
                output indicator, torque sparkline
    IP        — interpolated position panel: dual-trace sparkline
                (target vs actual), following error prominent
    HM        — homing panel: state progress, home position on completion
    _         — generic fallback

  History tuples: {actual_pos, target_pos, actual_vel, actual_torque}

  Per-axis config via opts:
      Exdash.watch([:j1, :j2],
        j1: [pos_min: -180.0, pos_max: 180.0, vel_max: 200.0, trq_max: 50.0],
        j2: [pos_min:    0.0, pos_max: 360.0, vel_max: 500.0, trq_max: 100.0]
      )

  Defaults apply if no config given. q to quit.
  """

  use ExRatatui.App

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Gauge, Paragraph}
  alias ExRatatui.Event

  @history_len 60
  @tick_ms     100

  # Defaults — overridden per axis via watch/2 opts
  @default_cfg [
    pos_min: -360.0,
    pos_max:  360.0,
    vel_max:  500.0,
    trq_max:  100.0,
    ferr_warn:  1.0,
    ferr_crit: 10.0,
  ]

  @state_colors %{
    not_ready_to_switch_on: :yellow,
    switch_on_disabled:     :cyan,
    ready_to_switch_on:     :blue,
    switched_on:            :blue,
    operation_enabled:      :green,
    quick_stop_active:      :yellow,
    fault:                  :red,
    fault_reaction_active:  :red,
  }

  @position_modes      [:profile_position, :cyclic_sync_position]
  @velocity_modes      [:profile_velocity, :cyclic_sync_velocity]
  @torque_modes        [:profile_torque,   :cyclic_sync_torque]
  @ip_modes            [:interpolated_position]
  @homing_modes        [:homing]

  # ── App behaviour ─────────────────────────────────────────────────────────

  @impl true
  def mount(opts) do
    axis_ids = Keyword.get(opts, :axes, [])
    cfg = Map.new(axis_ids, fn id ->
      axis_opts = Keyword.get(opts, id, [])
      {id, Keyword.merge(@default_cfg, axis_opts)}
    end)
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{axes: axis_ids, cfg: cfg, data: %{}, history: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = Enum.reduce(state.axes, state, fn id, acc ->
      case fetch_status(id) do
        {:ok, s} ->
          entry = {
            s[:actual_position] || 0.0,
            s[:target_position] || 0.0,
            s[:actual_velocity] || 0.0,
            s[:actual_torque]   || 0.0,
          }
          history =
            acc.history
            |> Map.get(id, [])
            |> then(&(&1 ++ [entry]))
            |> Enum.take(-@history_len)
          acc
          |> put_in([:data, id], Map.put(s, :offline, false))
          |> put_in([:history, id], history)

        {:error, _} ->
          update_in(acc, [:data, id], &Map.put(&1 || %{}, :offline, true))
      end
    end)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_event(%Event.Key{code: "q", kind: "press"}, state),
    do: {:stop, state}
  def handle_event(%Event.Key{code: "c", modifiers: [:control], kind: "press"}, state),
    do: {:stop, state}
  def handle_event(_event, state),
    do: {:noreply, state}

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    n    = length(state.axes)

    cond do
      n == 0 ->
        [{%Paragraph{text: " No axes. Call Exdash.watch([:j1, ...])"}, area}]
      map_size(state.data) == 0 ->
        [{%Paragraph{text: " Connecting...", style: %Style{fg: :yellow}}, area}]
      true ->
        bands = Layout.split(area, :vertical, List.duplicate({:percentage, div(100, n)}, n))
        state.axes
        |> Enum.zip(bands)
        |> Enum.flat_map(fn {id, band} ->
          data    = Map.get(state.data,    id, %{})
          history = Map.get(state.history, id, [])
          cfg     = Map.get(state.cfg,     id, @default_cfg)
          render_panel(id, data, history, cfg, band)
        end)
    end
  end

  # ── Panel dispatch ────────────────────────────────────────────────────────

  defp render_panel(id, data, history, cfg, area) do
    mode = data[:mode]
    cond do
      mode in @position_modes -> render_position_panel(id, data, history, cfg, area)
      mode in @velocity_modes -> render_velocity_panel(id, data, history, cfg, area)
      mode in @torque_modes   -> render_torque_panel(id, data, history, cfg, area)
      mode in @ip_modes       -> render_ip_panel(id, data, history, cfg, area)
      mode in @homing_modes   -> render_homing_panel(id, data, history, cfg, area)
      true                    -> render_generic_panel(id, data, history, cfg, area)
    end
  end

  # ── Position panel (PP / CSP) ─────────────────────────────────────────────
  # Story: am I at my target? Following error is the headline.

  defp render_position_panel(id, data, history, cfg, area) do
    {title_area, rows} = split_panel(area, 4)
    [rg_pos, rg_ferr, rl_vel_trq, r_spark] = rows

    ap    = data[:actual_position] || 0.0
    tp    = data[:target_position] || 0.0
    av    = data[:actual_velocity] || 0.0
    at_   = data[:actual_torque]   || 0.0
    fe    = abs(tp - ap)

    pos_min   = cfg[:pos_min]
    pos_max   = cfg[:pos_max]
    pos_range = pos_max - pos_min
    ferr_crit = cfg[:ferr_crit]

    pos_r  = clamp((ap - pos_min) / pos_range)
    ferr_r = clamp(fe / ferr_crit)

    sc = state_color(data)
    fc = ferr_color(fe, cfg)
    vc = vel_color(av)

    spark = sparkline(history, fn {ap_, _tp, _av, _at} -> ap_ end)

    [
      title_row(id, data, title_area,
        " pos #{f(ap)} → #{f(tp)}   err #{f(fe)}   vel #{f(av)}   trq #{f(at_)}",
        sc),

      {%Gauge{
        ratio:       pos_r,
        label:       "pos #{f(ap)}",
        gauge_style: %Style{fg: :cyan},
        style:       %Style{fg: :dark_gray},
      }, rg_pos},

      {%Gauge{
        ratio:       ferr_r,
        label:       "err #{f(fe)}",
        gauge_style: %Style{fg: fc},
        style:       %Style{fg: :dark_gray},
      }, rg_ferr},

      {%Paragraph{
        text:  " vel #{vel_arrow(av)} #{f(av)}   trq #{f(at_)}",
        style: %Style{fg: vc},
      }, rl_vel_trq},

      {%Paragraph{text: spark, style: %Style{fg: :cyan}}, r_spark},
    ]
  end

  # ── Velocity panel (PV / CSV) ─────────────────────────────────────────────
  # Story: am I at speed, and is it stable? Torque shows load.

  defp render_velocity_panel(id, data, history, cfg, area) do
    {title_area, rows} = split_panel(area, 4)
    [rg_vel, rl_trq, rg_trq, r_spark] = rows

    av  = data[:actual_velocity] || 0.0
    tv  = data[:target_velocity] || 0.0
    at_ = data[:actual_torque]   || 0.0

    vel_max = cfg[:vel_max]
    trq_max = cfg[:trq_max]

    vel_r = clamp((av + vel_max) / (vel_max * 2))
    trq_r = clamp((at_ + trq_max) / (trq_max * 2))

    sc = state_color(data)
    vc = vel_color(av)
    tc = trq_color(at_, cfg)

    spark = sparkline(history, fn {_ap, _tp, av_, _at} -> av_ end)

    [
      title_row(id, data, title_area,
        " vel #{vel_arrow(av)} #{f(av)} → #{f(tv)}   trq #{f(at_)}",
        sc),

      {%Gauge{
        ratio:       vel_r,
        label:       "vel #{vel_arrow(av)} #{f(av)}",
        gauge_style: %Style{fg: vc},
        style:       %Style{fg: :dark_gray},
      }, rg_vel},

      {%Paragraph{
        text:  " trq #{f(at_)}  load",
        style: %Style{fg: tc},
      }, rl_trq},

      {%Gauge{
        ratio:       trq_r,
        label:       "trq #{f(at_)}",
        gauge_style: %Style{fg: tc},
        style:       %Style{fg: :dark_gray},
      }, rg_trq},

      {%Paragraph{text: spark, style: %Style{fg: vc}}, r_spark},
    ]
  end

  # ── Torque panel (PT / CST) ───────────────────────────────────────────────
  # Story: am I applying the right force? Velocity shows mechanical response.

  defp render_torque_panel(id, data, history, cfg, area) do
    {title_area, rows} = split_panel(area, 4)
    [rg_trq, rl_vel, rg_vel, r_spark] = rows

    av  = data[:actual_velocity] || 0.0
    at_ = data[:actual_torque]   || 0.0
    tt  = data[:target_torque]   || 0.0

    vel_max = cfg[:vel_max]
    trq_max = cfg[:trq_max]

    trq_r = clamp((at_ + trq_max) / (trq_max * 2))
    vel_r = clamp((av  + vel_max) / (vel_max  * 2))

    sc = state_color(data)
    tc = trq_color(at_, cfg)
    vc = vel_color(av)

    spark = sparkline(history, fn {_ap, _tp, _av, at} -> at end)

    [
      title_row(id, data, title_area,
        " trq #{f(at_)} → #{f(tt)}   vel #{f(av)}",
        sc),

      {%Gauge{
        ratio:       trq_r,
        label:       "trq #{f(at_)}",
        gauge_style: %Style{fg: tc},
        style:       %Style{fg: :dark_gray},
      }, rg_trq},

      {%Paragraph{
        text:  " vel #{vel_arrow(av)} #{f(av)}  response",
        style: %Style{fg: vc},
      }, rl_vel},

      {%Gauge{
        ratio:       vel_r,
        label:       "vel #{vel_arrow(av)} #{f(av)}",
        gauge_style: %Style{fg: vc},
        style:       %Style{fg: :dark_gray},
      }, rg_vel},

      {%Paragraph{text: spark, style: %Style{fg: tc}}, r_spark},
    ]
  end

  # ── IP panel (interpolated position) ─────────────────────────────────────
  # Story: am I tracking the table? Dual sparkline shows commanded vs actual.

  defp render_ip_panel(id, data, history, cfg, area) do
    {title_area, rows} = split_panel(area, 5)
    [rg_ferr, rl_pos, rg_pos, r_spark_tgt, r_spark_act] = rows

    ap  = data[:actual_position] || 0.0
    tp  = data[:target_position] || 0.0
    av  = data[:actual_velocity] || 0.0
    fe  = abs(tp - ap)

    pos_min   = cfg[:pos_min]
    pos_max   = cfg[:pos_max]
    pos_range = pos_max - pos_min
    ferr_crit = cfg[:ferr_crit]

    pos_r  = clamp((ap - pos_min) / pos_range)
    ferr_r = clamp(fe / ferr_crit)

    sc = state_color(data)
    fc = ferr_color(fe, cfg)

    spark_act = sparkline(history, fn {ap_, _tp, _av, _at} -> ap_ end)
    spark_tgt = sparkline(history, fn {_ap, tp_, _av, _at} -> tp_ end)

    [
      title_row(id, data, title_area,
        " IP  err #{f(fe)}   pos #{f(ap)} → #{f(tp)}   vel #{f(av)}",
        sc),

      {%Gauge{
        ratio:       ferr_r,
        label:       "err #{f(fe)}",
        gauge_style: %Style{fg: fc},
        style:       %Style{fg: :dark_gray},
      }, rg_ferr},

      {%Paragraph{
        text:  " pos #{f(ap)} → #{f(tp)}",
        style: %Style{fg: :white},
      }, left_half(rl_pos)},
      {%Paragraph{
        text:  "vel #{f(av)}",
        style: %Style{fg: vel_color(av)},
      }, right_half(rl_pos)},

      {%Gauge{
        ratio:       pos_r,
        label:       "pos #{f(ap)}",
        gauge_style: %Style{fg: :cyan},
        style:       %Style{fg: :dark_gray},
      }, rg_pos},

      # Dual sparkline — target (dim) then actual (bright)
      {%Paragraph{
        text:  "tgt " <> spark_tgt,
        style: %Style{fg: :dark_gray},
      }, r_spark_tgt},
      {%Paragraph{
        text:  "act " <> spark_act,
        style: %Style{fg: :cyan},
      }, r_spark_act},
    ]
  end

  # ── Homing panel ──────────────────────────────────────────────────────────
  # Story: have I found home?

  defp render_homing_panel(id, data, _history, _cfg, area) do
    {title_area, rows} = split_panel(area, 1)
    [r_status] = rows

    sc = state_color(data)
    complete = data[:homing_complete] || false

    status_text = if complete do
      " ✓ HOMING COMPLETE   home = #{f(data[:actual_position] || 0.0)}"
    else
      " ⟳ SEARCHING FOR HOME..."
    end
    status_color = if complete, do: :green, else: :yellow

    [
      title_row(id, data, title_area, "", sc),
      {%Paragraph{
        text:  status_text,
        style: %Style{fg: status_color, modifiers: [:bold]},
      }, r_status},
    ]
  end

  # ── Generic fallback ──────────────────────────────────────────────────────

  defp render_generic_panel(id, data, history, cfg, area) do
    render_position_panel(id, data, history, cfg, area)
  end

  # ── Shared layout helpers ─────────────────────────────────────────────────

  # Split area into title row + n evenly-sized content rows.
  # Returns {title_area, [row1, row2, ...]}
  # Content rows: n-1 fixed rows of height 1, last row gets remainder.
  defp split_panel(area, content_rows) do
    fixed = List.duplicate({:length, 1}, content_rows - 1)
    constraints = [{:length, 1}] ++ fixed ++ [{:min, 1}]

    case Layout.split(area, :vertical, constraints) do
      [title | rest] -> {title, rest}
      _              -> {area, List.duplicate(area, content_rows)}
    end
  end

  defp title_row(id, data, area, subtitle, sc) do
    mode_str  = fmt_mode(data[:mode])
    state_str = fmt_state(data[:state])
    fault_str = if data[:state] == :fault, do: "  ⚠ #{inspect(data[:fault_code])}", else: ""
    text = " #{id} │ #{state_str} │ #{mode_str}#{fault_str}   #{subtitle}"
    {%Paragraph{
      text:  text,
      style: %Style{fg: sc, modifiers: [:bold]},
    }, area}
  end

  # ── Sparkline ─────────────────────────────────────────────────────────────

  defp sparkline([], _extractor), do: String.duplicate("─", @history_len)
  defp sparkline(history, extractor) do
    bars   = ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
    values = Enum.map(history, extractor)
    mn     = Enum.min(values)
    mx     = Enum.max(values)
    range  = max(mx - mn, 0.001)

    values
    |> Enum.take(-@history_len)
    |> Enum.map(fn v ->
      idx = round((v - mn) / range * 7) |> max(0) |> min(7)
      Enum.at(bars, idx)
    end)
    |> Enum.join()
    |> String.pad_trailing(@history_len, "─")
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp fetch_status(id) do
    try do
      {:ok, Exdrive.status(id)}
    catch
      :exit, _ -> {:error, :offline}
    end
  end

  defp state_color(data) do
    cond do
      data[:offline] -> :red
      true -> Map.get(@state_colors, data[:state], :white)
    end
  end

  defp fmt_state(nil), do: "UNKNOWN"
  defp fmt_state(s),   do: s |> Atom.to_string() |> String.replace("_", " ") |> String.upcase()

  defp fmt_mode(nil), do: "—"
  defp fmt_mode(m),   do: m |> Atom.to_string() |> String.replace("_", " ")

  defp f(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2) |> String.pad_leading(7)
  defp f(v),                   do: "#{v}" |> String.pad_leading(7)

  defp vel_arrow(v) when v >  0.5, do: "▶▶"
  defp vel_arrow(v) when v < -0.5, do: "◀◀"
  defp vel_arrow(_),                do: "◼ "

  defp vel_color(v) when v >  0.5, do: :green
  defp vel_color(v) when v < -0.5, do: :red
  defp vel_color(_),                do: :white

  defp trq_color(v, cfg) do
    trq_max = cfg[:trq_max] || 100.0
    cond do
      abs(v) > trq_max * 0.8 -> :red
      abs(v) > trq_max * 0.5 -> :yellow
      true                    -> :green
    end
  end

  defp ferr_color(fe, cfg) do
    warn = cfg[:ferr_warn] || 1.0
    crit = cfg[:ferr_crit] || 10.0
    cond do
      fe >= crit -> :red
      fe >= warn -> :yellow
      true       -> :green
    end
  end

  defp clamp(v), do: v |> max(0.0) |> min(1.0)

  defp left_half(%Rect{x: x, y: y, width: w, height: h}),
    do: %Rect{x: x, y: y, width: div(w, 2), height: h}

  defp right_half(%Rect{x: x, y: y, width: w, height: h}) do
    half = div(w, 2)
    %Rect{x: x + half, y: y, width: w - half, height: h}
  end
end
