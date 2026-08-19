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
  def hash(%__MODULE__{} = bundle), do: bundle |> print() |> EMotion.Canonical.hash()

  @doc "The first twelve characters of `hash/1`, for showing a person."
  @spec short_hash(t()) :: String.t()
  def short_hash(%__MODULE__{} = bundle), do: bundle |> hash() |> EMotion.Canonical.short()

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

  # ── Pushing ───────────────────────────────────────────────────────────────

  @doc """
  What pushing this bundle would do, without doing any of it.

  Same contract as `EMotion.Installation.plan/2`: a person has to be able to
  read what is about to happen to a machine. Steps are
  `{action, kind, name, reason}`:

      {:create, :point, "weld_start", nil}
      {:replace, :program, "pick", nil}
      {:refuse, :frame, "fixture_a", :not_in_this_cell}

  **A missing frame or tool is a refusal, not something to install.** A point
  is job data and installing one is what pushing a program means. A frame is a
  claim about where a fixture physically sits, and a laptop asserting one it
  has never measured is the same class of act as pushing a mastering offset —
  it runs cleanly and lands in the wrong place. `INSTALLATION.md` records this
  as falling out of the categories rather than being a rail bolted on.

  The refusal is also the useful answer: it says this cell has not been
  commissioned for this job, which is true and actionable, where a fixture
  invented at the origin is neither.
  """
  @spec plan(t(), keyword()) :: {:ok, [tuple()]} | {:error, term()}
  def plan(%__MODULE__{} = bundle, opts \\ []) do
    with {:ok, points} <- Teach.list_points(opts),
         {:ok, frames} <- Teach.list_frames(opts),
         {:ok, tools} <- Teach.list_tools(opts),
         {:ok, programs} <- Program.list(opts) do
      have_points = MapSet.new(points, & &1["name"])
      have_frames = MapSet.new(frames, & &1["name"])
      have_tools = MapSet.new(tools, & &1["name"])
      have_programs = MapSet.new(programs, & &1["name"])

      {:ok,
       Enum.concat([
         missing(bundle.frames, have_frames, :frame),
         missing(bundle.tools, have_tools, :tool),
         Enum.map(Enum.sort_by(bundle.points, & &1["name"]), fn point ->
           action = if MapSet.member?(have_points, point["name"]), do: :replace, else: :create
           {action, :point, point["name"], nil}
         end),
         [
           {if(MapSet.member?(have_programs, bundle.name), do: :replace, else: :create), :program,
            bundle.name, nil}
         ]
       ])}
    end
  end

  # Only what the cell is missing is worth a line. A frame the controller
  # already has needs no action and saying "leave alone" for every one of them
  # buries the one that matters.
  defp missing(rows, have, kind) do
    for row <- Enum.sort_by(rows, & &1["name"]),
        not MapSet.member?(have, row["name"]),
        do: {:refuse, kind, row["name"], :not_in_this_cell}
  end

  @doc """
  Install this bundle on the connected controller.

  Refuses as a whole if the cell is missing any frame or tool the bundle names
  — nothing is written. Partly installing a program whose points cannot all
  land would leave a program on the machine that names things that are not
  there, and the controller would refuse to run it later with less context than
  is available right now.

  Otherwise: points first, then the program, because `program.append` refuses a
  statement naming a point that does not exist yet. The program is replaced
  rather than merged — a push installs the artifact, and merging two programs
  that share a name is the reconciliation this design deliberately does not do.
  """
  @spec push(t(), keyword()) :: {:ok, [tuple()]} | {:error, term()}
  def push(%__MODULE__{} = bundle, opts \\ []) do
    with {:ok, plan} <- plan(bundle, opts) do
      case Enum.filter(plan, &match?({:refuse, _, _, _}, &1)) do
        [] -> {:ok, do_push(bundle, plan, opts)}
        refusals -> {:error, {:cell_not_commissioned, refusals}}
      end
    end
  end

  defp do_push(%__MODULE__{} = bundle, plan, opts) do
    points =
      for {action, :point, name, _reason} <- plan do
        point = Enum.find(bundle.points, &(&1["name"] == name))

        case EMotion.Link.call("cell.define_point", point_args(point), opts) do
          {:ok, _result} -> {action, :point, name, nil}
          {:error, reason} -> {:failed, :point, name, reason}
        end
      end

    points ++ [install_program(bundle, opts)]
  end

  # Delete and rebuild rather than diff. A program is an artifact here, not a
  # working copy, so installing one means the machine ends up with exactly what
  # the file says — including the absence of a statement somebody added on the
  # pendant. Diffing would be reconciliation wearing a different hat.
  defp install_program(%__MODULE__{} = bundle, opts) do
    _ = Program.delete(bundle.name, opts)

    with {:ok, _} <- Program.create(bundle.name, opts),
         :ok <- append_all(bundle, opts) do
      {:installed, :program, bundle.name, nil}
    else
      {:error, reason} -> {:failed, :program, bundle.name, reason}
    end
  end

  defp append_all(%__MODULE__{} = bundle, opts) do
    bundle.statements
    |> Enum.sort_by(& &1["seq"])
    |> Enum.reduce_while(:ok, fn statement, :ok ->
      case Program.append(bundle.name, statement["kind"], statement["args"] || [], opts) do
        {:ok, _seq} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp point_args(nil), do: %{}

  defp point_args(point) do
    %{
      "name" => point["name"],
      "joints" => point["joints"] || [],
      "frame" => point["frame"] || "",
      "tool" => point["tool"] || ""
    }
    |> Map.merge(Map.new(~w(x y z rx ry rz), fn k -> {k, point[k] || 0.0} end))
  end

  @doc "A plan or a result, in words. Same shape as `EMotion.Installation.describe/1`."
  @spec describe([tuple()]) :: String.t()
  def describe(steps) do
    Enum.map_join(steps, "\n", fn {action, kind, name, reason} ->
      note =
        case reason do
          nil -> ""
          atom when is_atom(atom) -> "   (" <> String.replace(to_string(atom), "_", " ") <> ")"
          other -> "   (" <> inspect(other) <> ")"
        end

      "#{String.pad_trailing(to_string(action), 10)} #{String.pad_trailing(to_string(kind), 8)} #{String.pad_trailing(to_string(name), 18)}#{note}"
    end)
  end

  @doc "A sensible file name for this bundle: `pick.emp`."
  @spec filename(t()) :: String.t()
  def filename(%__MODULE__{name: name}) do
    (name || "program")
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
    |> Kernel.<>(".emp")
  end
end
