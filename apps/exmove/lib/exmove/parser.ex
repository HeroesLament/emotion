defmodule ExGCode.Parser do
  @moduledoc """
  RS-274/NGC GCode parser.

  Produces a lazy stream of `%ExMove.Frame{}` by interpreting GCode lines
  and stitching together `ExMove.Path.linear/3` and `ExMove.Path.arc/6`
  segments.

  Supported words:

    G0        rapid move (same path semantics as G1, no velocity guarantee)
    G1        linear move at feedrate F
    G2        arc clockwise   (I J offsets from current position)
    G3        arc counter-clockwise
    G20       inch mode
    G21       millimetre mode (default)
    G90       absolute positioning (default)
    G91       incremental positioning
    F         feedrate in mm/min (G94, default) or mm/s (G95)
    G93       inverse time feed mode (not supported, ignored)
    G94       units-per-minute feed mode (mm/min or inch/min) — default for most CAM
    G95       units-per-second feed mode (mm/s)
    X Y Z     Cartesian target in mm (or inch)
    A B C     orientation rx ry rz in radians
    I J       arc centre offsets from current position, same units as X Y
    M2 M30    end of program

  Comments: `(parenthesised)` and `; to end of line` are stripped.
  FreeCAD `(machine units: mm/min)` comments are detected and set feed mode
  automatically. Unknown G/M codes (G17, G40, G43, G49, G80, M5, M6 etc.)
  are silently ignored — safe for FreeCAD linuxcnc_post output.

  GCode positions are in mm (or inch).
  `%Frame{}` positions are in metres — conversion is applied internally.
  """

  alias ExMove.{Frame, Path}

  defstruct [
    x:           0.0,
    y:           0.0,
    z:           0.0,
    rx:          0.0,
    ry:          0.0,
    rz:          0.0,
    feedrate:    600.0,        # default 600 mm/min = 10 mm/s
    feed_mode:   :per_minute,  # :per_second (mm/s) | :per_minute (mm/min)
                               # most CAM (FreeCAD linuxcnc_post) outputs mm/min
    motion:      :g1,
    units:       :mm,
    positioning: :absolute,
  ]

  @type modal :: %__MODULE__{}

  @doc """
  Parse a GCode string into a lazy stream of `%ExMove.Frame{}`.

  `start_frame` is the TCP pose before the first move.
  It becomes the source frame for the first segment and the origin
  for incremental positioning.
  """
  @spec parse(String.t(), Frame.t(), keyword()) :: Enumerable.t()
  def parse(gcode, %Frame{} = start_frame, opts \\ []) do
    fixture = Keyword.get(opts, :fixture_offset, {0.0, 0.0, 0.0})
    lines = gcode
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    initial_modal = frame_to_modal(start_frame, fixture)

    Stream.resource(
      fn -> {lines, initial_modal} end,
      fn
        {[], _modal} ->
          {:halt, nil}

        {[line | rest], modal} ->
          case interpret(line, modal) do
            {:stop, _modal} ->
              {:halt, nil}

            {:no_move, new_modal} ->
              {[], {rest, new_modal}}

            {:move, new_modal, segment_stream} ->
              frames = Enum.to_list(segment_stream)
              {frames, {rest, new_modal}}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc "Parse a GCode file into a lazy stream of `%ExMove.Frame{}`."
  @spec parse_file(Path.t(), Frame.t()) :: Enumerable.t()
  def parse_file(path, %Frame{} = start_frame) do
    File.read!(path)
    |> parse(start_frame)
  end

  # ---------------------------------------------------------------------------
  # Interpretation
  # ---------------------------------------------------------------------------

  defp interpret(line, modal) do
    # Check for FreeCAD feed mode comment before stripping
    modal = case detect_feed_mode_comment(line) do
      nil  -> modal
      mode -> %{modal | feed_mode: mode}
    end

    words = extract_words(strip_comment(line))

    if stop_word?(words) do
      {:stop, modal}
    else
      modal    = apply_non_motion_words(words, modal)
      motion   = extract_motion(words, modal.motion)
      modal    = %{modal | motion: motion}
      has_pos  = has_position_word?(words)

      if has_pos or motion_changed?(words) do
        target_modal = apply_position_words(words, modal)
        stream       = build_segment(modal, target_modal, words)
        {:move, target_modal, stream}
      else
        {:no_move, modal}
      end
    end
  end

  defp stop_word?(words) do
    Enum.any?(words, fn {l, v} -> l == "M" and trunc(v) in [2, 30] end)
  end

  defp motion_changed?(words) do
    Enum.any?(words, fn {l, v} -> l == "G" and trunc(v) in [0, 1, 2, 3] end)
  end

  defp has_position_word?(words) do
    Enum.any?(words, fn {l, _} -> l in ["X", "Y", "Z", "A", "B", "C"] end)
  end

  # ---------------------------------------------------------------------------
  # Word extraction
  # ---------------------------------------------------------------------------

  defp extract_words(line) do
    ~r/([A-Za-z])([+-]?[0-9]*\.?[0-9]+)/
    |> Regex.scan(line)
    |> Enum.map(fn [_, letter, value] ->
      {String.upcase(letter), parse_float(value)}
    end)
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  # Extract feed mode hint from FreeCAD-style comments before stripping
  # e.g. "(machine units: mm/min)" → :per_minute
  defp detect_feed_mode_comment(line) do
    cond do
      String.contains?(line, "mm/min")  -> :per_minute
      String.contains?(line, "mm/s")    -> :per_second
      true                              -> nil
    end
  end

  defp strip_comment(line) do
    line
    |> String.replace(~r/\(.*?\)/, "")
    |> String.replace(~r/;.*$/, "")
  end

  # ---------------------------------------------------------------------------
  # Modal state
  # ---------------------------------------------------------------------------

  # fixture_offset is {ox, oy, oz} in mm — added to every GCode coordinate
  defp frame_to_modal(frame, offset \\ {0.0, 0.0, 0.0})
  defp frame_to_modal(%Frame{} = f, {ox, oy, oz}) do
    %__MODULE__{
      x:  f.x  * 1000.0 - ox,
      y:  f.y  * 1000.0 - oy,
      z:  f.z  * 1000.0 - oz,
      rx: f.rx,
      ry: f.ry,
      rz: f.rz,
    }
  end

  defp modal_to_frame(%__MODULE__{} = m) do
    %Frame{
      x:  m.x  / 1000.0,
      y:  m.y  / 1000.0,
      z:  m.z  / 1000.0,
      rx: m.rx,
      ry: m.ry,
      rz: m.rz,
    }
  end

  defp apply_non_motion_words(words, modal) do
    Enum.reduce(words, modal, fn {letter, value}, acc ->
      case {letter, trunc(value)} do
        {"G", 20} -> %{acc | units: :inch}
        {"G", 21} -> %{acc | units: :mm}
        {"G", 90} -> %{acc | positioning: :absolute}
        {"G", 91} -> %{acc | positioning: :incremental}
        {"G", 93} -> acc  # inverse time — not supported, ignore
        {"G", 94} -> %{acc | feed_mode: :per_minute}
        {"G", 95} -> %{acc | feed_mode: :per_second}
        {"F",  _} -> %{acc | feedrate: value}
        _         -> acc
      end
    end)
  end

  defp extract_motion(words, current_motion) do
    Enum.reduce(words, current_motion, fn {letter, value}, acc ->
      case {letter, trunc(value)} do
        {"G", 0} -> :g0
        {"G", 1} -> :g1
        {"G", 2} -> :g2
        {"G", 3} -> :g3
        _        -> acc
      end
    end)
  end

  defp apply_position_words(words, modal) do
    scale = unit_scale(modal)

    Enum.reduce(words, modal, fn {letter, value}, acc ->
      case {letter, acc.positioning} do
        {"X", :absolute}    -> %{acc | x: value * scale}
        {"X", :incremental} -> %{acc | x: acc.x + value * scale}
        {"Y", :absolute}    -> %{acc | y: value * scale}
        {"Y", :incremental} -> %{acc | y: acc.y + value * scale}
        {"Z", :absolute}    -> %{acc | z: value * scale}
        {"Z", :incremental} -> %{acc | z: acc.z + value * scale}
        {"A", _}            -> %{acc | rx: value}
        {"B", _}            -> %{acc | ry: value}
        {"C", _}            -> %{acc | rz: value}
        _                   -> acc
      end
    end)
  end

  defp unit_scale(%{units: :mm}),   do: 1.0
  defp unit_scale(%{units: :inch}), do: 25.4

  # ---------------------------------------------------------------------------
  # Segment builder
  # ---------------------------------------------------------------------------

  defp build_segment(from_modal, to_modal, words) do
    from     = modal_to_frame(from_modal)
    to       = modal_to_frame(to_modal)
    feedrate = feedrate_to_mm_per_s(to_modal)

    case to_modal.motion do
      m when m in [:g0, :g1] ->
        Path.linear(from, to, feedrate)

      m when m in [:g2, :g3] ->
        direction = if to_modal.motion == :g2, do: :cw, else: :ccw
        scale     = unit_scale(to_modal)
        i_offset  = get_word(words, "I", 0.0) * scale / 1000.0
        j_offset  = get_word(words, "J", 0.0) * scale / 1000.0
        cx        = from.x + i_offset
        cy        = from.y + j_offset
        Path.arc(from, to, {cx, cy}, direction, feedrate)
    end
  end

  # Normalise feedrate to mm/s regardless of modal feed mode.
  # FreeCAD linuxcnc_post outputs mm/min (G94); ExGCode Path expects mm/s.
  defp feedrate_to_mm_per_s(%{feedrate: f, feed_mode: :per_minute, units: :mm}),   do: f / 60.0
  defp feedrate_to_mm_per_s(%{feedrate: f, feed_mode: :per_minute, units: :inch}), do: f * 25.4 / 60.0
  defp feedrate_to_mm_per_s(%{feedrate: f, feed_mode: :per_second, units: :mm}),   do: f
  defp feedrate_to_mm_per_s(%{feedrate: f, feed_mode: :per_second, units: :inch}), do: f * 25.4

  defp get_word(words, letter, default) do
    case Enum.find(words, fn {l, _} -> l == letter end) do
      {_, v} -> v
      nil    -> default
    end
  end
end
