defmodule EMotion.Program.Bundle do
  @moduledoc """
  A program and everything it needs, as one standalone thing.

  This is what a `.emp` file contains and what a push installs. Not a copy of a
  controller's program — **its own thing**, with no memory of where it came
  from and no notion of being behind anything.

  That distinction does the work. There is no sync, no last-seen revision, no
  fast-forward check and no merge. If a controller has `pick` and your file is
  called `pick`, that is a name collision, not a conflict: the hashes say
  whether they are the same thing or two different things wearing the same
  label, and a person decides what to do about it.

  ## Why the references travel with it

  `move_joint point=weld_start` means nothing without `weld_start`. So a bundle
  carries the points, frames and tools its statements name, and the hash covers
  all of it.

  That last part matters more than it looks: **if a point moves, the hash
  changes.** A program whose `weld_start` shifted four millimetres is a
  different program in the only sense anyone cares about — what the arm will
  do. Hashing the body alone would call those two identical, which is the one
  lie a fingerprint must not tell.

  ## The file is JSON. The text is a view.

  `PROGRAMS.md` says to write the printer and defer the parser, because
  rendering is total and parsing is partial. Both are true and neither stops a
  file round-tripping, because the file is not the printed text: it is
  canonical JSON, written and read by machines. `EMotion.Program.Printer` is
  the human view and the thing hashed; nothing ever parses it back.

  So opening a file cannot fail on prose, and `git diff` still shows something
  a person can read, because the JSON is sorted and pretty-printed.

  ## What is not here yet

  Pulling works. Pushing does not, and not for a small reason: the wire has
  exactly one way to create a point — `cell.teach_point`, which records where
  the arm *is*. Installing a point from a file is a different act, asserting a
  position nobody verified against real metal, and it deserves its own method
  and its own grant rather than being smuggled in as an overload of teaching.
  """

  alias EMotion.{Program, Teach}
  alias EMotion.Program.Printer

  @format_version 1

  defstruct name: nil,
            statements: [],
            points: [],
            frames: [],
            tools: [],
            source: nil

  @type t :: %__MODULE__{
          name: String.t() | nil,
          statements: [map()],
          points: [map()],
          frames: [map()],
          tools: [map()],
          source: String.t() | nil
        }

  @doc """
  Read a program and its references off a connected controller.

  Two round trips for the data plus one for the program, rather than one call
  per referenced point: a cell has tens of points and a program names a handful,
  and filtering a list locally is cheaper than asking a controller a question
  per statement.
  """
  @spec pull(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def pull(name, opts \\ []) do
    with {:ok, statements} <- Program.show(name, opts),
         {:ok, points} <- Teach.list_points(opts),
         {:ok, frames} <- Teach.list_frames(opts),
         {:ok, tools} <- Teach.list_tools(opts) do
      needed = referenced(statements)

      {:ok,
       %__MODULE__{
         name: name,
         statements: Enum.sort_by(statements, & &1["seq"]),
         points: keep(points, needed["point"]),
         frames: keep(frames, needed["frame"]),
         tools: keep(tools, needed["tool"]),
         source: opts[:source]
       }}
    end
  end

  @doc """
  Everything the statements name, grouped by what sort of thing it is.

  Read off `refs`, which the controller derives from the same rows as the
  arguments — so this cannot disagree with what the program actually does, and
  it does not need the kind registry to work out which sockets are references.
  """
  @spec referenced([map()]) :: %{String.t() => MapSet.t()}
  def referenced(statements) do
    statements
    |> Enum.flat_map(&Map.get(&1, "refs", []))
    |> Enum.group_by(& &1["kind"], & &1["name"])
    |> Map.new(fn {kind, names} -> {kind, MapSet.new(names)} end)
  end

  defp keep(_all, nil), do: []
  defp keep(all, names), do: all |> Enum.filter(&MapSet.member?(names, &1["name"])) |> Enum.sort_by(& &1["name"])

  @doc """
  Names this bundle refers to but does not carry.

  Empty for a bundle pulled from a controller. Not necessarily empty for one
  assembled by hand or edited, which is the reason to be able to ask.
  """
  @spec dangling(t()) :: [{String.t(), String.t()}]
  def dangling(%__MODULE__{} = bundle) do
    have = %{
      "point" => names(bundle.points),
      "frame" => names(bundle.frames),
      "tool" => names(bundle.tools)
    }

    for {kind, wanted} <- referenced(bundle.statements),
        name <- MapSet.to_list(wanted),
        not MapSet.member?(Map.get(have, kind, MapSet.new()), name) do
      {kind, name}
    end
    |> Enum.sort()
  end

  defp names(list), do: MapSet.new(list, & &1["name"])

  @doc "The canonical text. What a person reads and what the hash covers."
  @spec print(t()) :: String.t()
  def print(%__MODULE__{} = bundle), do: Printer.print(bundle)

  @doc """
  This bundle's identity: a SHA-256 over its canonical rendering.

  A name is a label; this is the identity. Two programs called `pick` with
  different hashes are two different programs, and saying so is the whole job —
  there is nothing to reconcile, only something to tell apart.
  """
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = bundle) do
    :sha256 |> :crypto.hash(print(bundle)) |> Base.encode16(case: :lower)
  end

  @doc "The first twelve characters of `hash/1`, for showing a person."
  @spec short_hash(t()) :: String.t()
  def short_hash(%__MODULE__{} = bundle), do: bundle |> hash() |> binary_part(0, 12)

  # ── The file ──────────────────────────────────────────────────────────────

  @doc """
  The bundle as canonical JSON: sorted keys, two-space indent, trailing newline.

  Canonical so that saving an unchanged bundle produces an unchanged file, which
  is what makes `git diff` mean something and what keeps the hash stable.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = bundle) do
    %{
      "format" => "emotion.program",
      "formatVersion" => @format_version,
      "name" => bundle.name,
      "hash" => hash(bundle),
      "statements" => bundle.statements,
      "points" => bundle.points,
      "frames" => bundle.frames,
      "tools" => bundle.tools
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc """
  Read a bundle back.

  The stored hash is checked rather than trusted. A file whose contents no
  longer match the hash written into it was edited by something that did not
  understand it, and quietly accepting that would make the fingerprint
  worthless exactly when it matters.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(raw) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(raw),
         :ok <- check_format(decoded) do
      bundle = %__MODULE__{
        name: decoded["name"],
        statements: decoded["statements"] || [],
        points: decoded["points"] || [],
        frames: decoded["frames"] || [],
        tools: decoded["tools"] || []
      }

      case decoded["hash"] do
        nil -> {:ok, bundle}
        stored -> if stored == hash(bundle), do: {:ok, bundle}, else: {:error, {:hash_mismatch, stored, hash(bundle)}}
      end
    end
  end

  defp check_format(%{"format" => "emotion.program", "formatVersion" => v}) when v <= @format_version,
    do: :ok

  defp check_format(%{"format" => "emotion.program", "formatVersion" => v}),
    do: {:error, {:format_too_new, v}}

  defp check_format(_other), do: {:error, :not_a_program_file}

  @doc "Write a bundle to disk. Conventional extension is `.emp`."
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = bundle, path) do
    File.write(path, to_json(bundle))
  end

  @doc "Read a bundle from disk."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, raw} <- File.read(path), do: from_json(raw)
  end

  @doc "A sensible file name for this bundle: `pick.emp`."
  @spec filename(t()) :: String.t()
  def filename(%__MODULE__{name: name}) do
    (name || "program")
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
    |> Kernel.<>(".emp")
  end
end
