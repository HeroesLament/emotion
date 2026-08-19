defmodule EMotion.Program.Printer do
  @moduledoc """
  A program, as text.

  `protocol/PROGRAMS.md` §"Why structure is authoritative and text is a
  rendering" argues for building this early, and the asymmetry is the whole
  reason:

  > rendering structure to text is **total** and always succeeds, while parsing
  > text to structure is **partial** and can fail. So: write the printer now. It
  > is cheap, it cannot fail, and it buys `git diff` over a cell's programs,
  > curl-able export, and reviewable change.

  So this exists and its inverse deliberately does not. A `.emp` file is not
  this text — it is canonical JSON, written and read by machines and never
  parsed back from prose. This is the human view, and the fingerprint.

  ## It is also what the hash is taken over

  A program's identity is the hash of its canonical rendering, so the rendering
  has to be canonical: same program, same bytes, every time, regardless of what
  order a database handed the rows back in. Arguments are sorted by name and
  statements by sequence for that reason, not for looks.

  ## What it renders is the bundle, not the body

  A program whose `weld_start` moved four millimetres is a different program in
  the only sense that matters — what the arm will do. So the referenced points,
  frames and tools are part of the text and part of the hash. Printing only the
  body would give a fingerprint that calls those two programs identical, which
  is precisely the lie you would not want it to tell.
  """

  alias EMotion.Program.Bundle

  @doc """
  Render a bundle as canonical text. Deterministic: same bundle, same bytes.
  """
  @spec print(Bundle.t()) :: String.t()
  def print(%Bundle{} = bundle) do
    [
      "program #{bundle.name}",
      body(bundle.statements),
      data(bundle)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Render one statement as a line, without its surroundings.

  What the Programs tab draws in its statement list — one renderer rather than
  two, because two renderings of the same thing is how KUKA ended up with
  editor metadata in a comment.
  """
  @spec statement(map()) :: String.t()
  def statement(%{} = s) do
    args =
      s
      |> Map.get("args", [])
      |> Enum.sort_by(& &1["name"])
      |> Enum.map_join("  ", fn a -> "#{a["name"]}: #{a["value"]}" end)

    String.trim_trailing("#{String.pad_trailing(to_string(s["kind"]), 12)} #{args}")
  end

  defp body([]), do: "  (empty)"

  defp body(statements) do
    statements
    |> Enum.sort_by(& &1["seq"])
    |> Enum.map_join("\n", fn s ->
      "  #{String.pad_leading(to_string(s["seq"]), 3)}  #{statement(s)}"
    end)
  end

  # The data a program cannot run without. After the body, because the body is
  # what someone reads and this is what makes the body mean something.
  defp data(%Bundle{} = bundle) do
    [
      section("frames", bundle.frames, &frame_line/1),
      section("tools", bundle.tools, &tool_line/1),
      section("points", bundle.points, &point_line/1)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp section(_label, [], _render), do: ""

  defp section(label, items, render) do
    lines = items |> Enum.sort_by(& &1["name"]) |> Enum.map_join("\n", &("  " <> render.(&1)))
    "\n#{label}\n#{lines}"
  end

  # Radians and metres, as everywhere else. `EMotion.Units` owns conversion to
  # whatever a person types, and a file is not a person.
  defp point_line(point) do
    pose = Enum.map_join(~w(base_x base_y base_z base_rx base_ry base_rz), " ", &number(point[&1]))
    tool = point["tool"]
    suffix = if tool in [nil, ""], do: "", else: " tool=#{tool}"
    "#{point["name"]}  in #{point["frame"] || "base"}#{suffix}  #{pose}"
  end

  defp frame_line(frame) do
    parent = frame["parent"]
    suffix = if parent in [nil, ""], do: "", else: " under #{parent}"
    "#{frame["name"]}#{suffix}"
  end

  defp tool_line(tool), do: to_string(tool["name"])

  # Fixed precision, so a float's shortest representation changing across a
  # JSON round trip cannot change the hash. Nine places is past anything this
  # arm's encoders resolve and well inside a double.
  defp number(nil), do: "0.000000000"
  defp number(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 9)
  defp number(other), do: to_string(other)
end
