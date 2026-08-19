defmodule EMotion.Installation do
  @moduledoc """
  What a machine is, as one file.

  `protocol/INSTALLATION.md` decides what goes in here and what does not. The
  short version is that this carries three kinds of thing which look alike and
  are not:

  * **the cell** — frames and tools. Where the fixture is, what is on the
    flange. Portable to an identical cell.
  * **the robot model** — the chain and what commissioning said about each
    joint. Portable to the same model of arm.
  * **this unit** — mastering. Tied to a serial number, and never portable.

  Programs are not in here. They travel separately, as `EMotion.Program.Bundle`,
  because a program is what a job does and this is what a machine is.

  ## Read-only, on purpose, for now

  This pulls, prints, hashes and saves. It does not restore, and INSTALLATION.md
  gives the order: *"Export first, because a read-only backup is immediately
  useful and cannot damage anything. Import after, and the per-unit section of
  an import is inert until the separate verb is built."*

  When import arrives, the cell and the robot model restore and mastering does
  not. That is not squeamishness — MASTERING.md is blunt about the failure:

  > A controller that pushed a stored offset back at boot would eventually push
  > a stale one, and the failure is silent... Nothing faults. You find out at
  > the workpiece.

  ## Why one call rather than four

  `cell.installation` assembles the snapshot controller-side. Four round trips
  can straddle a change — a frame taught between the second and the third gives
  a backup of a machine that never existed, and a hash over that is worse than
  no hash, because it looks authoritative.

  ## Grant

  Behind `backup`, which is a maintainer grant. A programmer can write and run
  programs and cannot take the machine's configuration off it. That is the
  boundary working rather than an inconvenience.
  """

  alias EMotion.{Canonical, Link}

  @format_version 1

  defstruct robot: %{},
            joints: [],
            frames: [],
            tools: [],
            mastering: [],
            taken_at: nil

  @type t :: %__MODULE__{
          robot: map(),
          joints: [map()],
          frames: [map()],
          tools: [map()],
          mastering: [map()],
          taken_at: String.t() | nil
        }

  @doc """
  Read the whole installation off a connected controller.

  `taken_at` is stamped by the caller rather than read from the controller,
  and is deliberately outside the hash: when a backup was taken is a fact about
  the backup, not about the machine. Two backups of an unchanged machine should
  have the same fingerprint however far apart they were taken — that is the
  property that makes "did anything change since March" answerable.
  """
  @spec pull(keyword()) :: {:ok, t()} | {:error, term()}
  def pull(opts \\ []) do
    case Link.call("cell.installation", %{}, opts) do
      {:ok, %{} = result} ->
        {:ok,
         %__MODULE__{
           robot: Map.get(result, "robot", %{}),
           joints: Map.get(result, "joints", []),
           frames: Map.get(result, "frames", []),
           tools: Map.get(result, "tools", []),
           mastering: Map.get(result, "mastering", []),
           taken_at: Keyword.get(opts, :taken_at)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  # ── The canonical rendering ───────────────────────────────────────────────

  @doc """
  The installation as text: what a person reads, and what the hash covers.

  Sectioned by the three categories rather than dumped as one list, because the
  categories are the point of the document and a reader should not have to know
  which rows are which.
  """
  @spec print(t()) :: String.t()
  def print(%__MODULE__{} = installation) do
    [
      "installation #{name(installation)}",
      section("robot", [installation.robot], &robot_line/1),
      section("joints", installation.joints, &joint_line/1, & &1["joint"]),
      section("frames", installation.frames, &frame_line/1),
      section("tools", installation.tools, &tool_line/1),
      section("mastering", installation.mastering, &mastering_line/1, & &1["axis"])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "The robot's name, or a word for a controller nobody commissioned."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{robot: robot}) do
    case Map.get(robot, "name") do
      n when is_binary(n) and n != "" -> n
      _ -> "uncommissioned"
    end
  end

  @doc "This installation's identity: a hash over its canonical rendering."
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = installation), do: installation |> print() |> Canonical.hash()

  @doc "The first twelve characters of `hash/1`."
  @spec short_hash(t()) :: String.t()
  def short_hash(%__MODULE__{} = installation), do: installation |> hash() |> Canonical.short()

  # Joints and mastering keep the controller's order, which is the chain's own
  # order, base to tip. Sorting them alphabetically would put j10 between j1 and
  # j2 and make a six-axis arm read as a list of strings. Frames and tools have
  # no natural order and are sorted by name so a backup is stable.
  defp section(label, items, render, order \\ nil)
  defp section(_label, [], _render, _order), do: ""

  defp section(label, items, render, order) do
    items = if order, do: items, else: Enum.sort_by(items, & &1["name"])
    "\n#{label}\n" <> Enum.map_join(items, "\n", &("  " <> render.(&1)))
  end

  # The URDF is hashed, not printed. It is kilobytes of XML and printing it
  # would bury the six lines a person actually reads — but leaving it out of
  # the fingerprint entirely would mean a re-commissioned arm backs up
  # identically to the one it replaced.
  defp robot_line(robot) do
    urdf = Map.get(robot, "urdf") || ""
    digest = if urdf == "", do: "none", else: Canonical.short(Canonical.hash(urdf))
    "#{Map.get(robot, "name") || "uncommissioned"}  urdf=#{digest} (#{byte_size(urdf)} bytes)"
  end

  defp joint_line(j) do
    "#{String.pad_trailing(to_string(j["joint"]), 10)} axis=#{String.pad_trailing(to_string(j["axis"]), 4)}" <>
      " vel=#{Canonical.number(j["max_vel"])} acc=#{Canonical.number(j["max_acc"])}" <>
      " limits=#{Canonical.number(j["soft_lower"])}..#{Canonical.number(j["soft_upper"])}" <>
      " home=#{Canonical.number(j["home"])}"
  end

  defp frame_line(f) do
    parent = f["parent"]
    under = if parent in [nil, ""], do: "", else: " under #{parent}"
    "#{f["name"]}#{under}  #{pose(f)}"
  end

  defp tool_line(t) do
    fitted = if t["fitted"], do: " [fitted]", else: ""
    "#{t["name"]}#{fitted}  #{pose(t)}"
  end

  # State first, because it is the word that decides whether the number means
  # anything. An offset on an unmastered axis is not a small offset, it is not
  # an offset.
  defp mastering_line(m) do
    "#{String.pad_trailing(to_string(m["axis"]), 4)} #{String.pad_trailing(to_string(m["state"]), 13)}" <>
      " offset=#{Canonical.number(m["offset"])} drift=#{Canonical.number(m["drift"])}"
  end

  defp pose(row) do
    Enum.map_join(~w(x y z rx ry rz), " ", &Canonical.number(row[&1]))
  end

  # ── The file ──────────────────────────────────────────────────────────────

  @doc """
  The installation as canonical JSON. Conventional extension is `.emi`.

  `takenAt` rides alongside the hash rather than inside it, so the same machine
  backed up twice produces the same fingerprint and a different timestamp.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = installation) do
    %{
      "format" => "emotion.installation",
      "formatVersion" => @format_version,
      "name" => name(installation),
      "hash" => hash(installation),
      "takenAt" => installation.taken_at,
      "robot" => installation.robot,
      "joints" => installation.joints,
      "frames" => installation.frames,
      "tools" => installation.tools,
      "mastering" => installation.mastering
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc """
  Read one back. The stored hash is checked rather than trusted.

  A backup whose contents no longer match its own fingerprint was edited by
  something that did not understand it, and this is the artifact people will
  reach for when they are least sure what happened.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(raw) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(raw),
         :ok <- check_format(decoded) do
      installation = %__MODULE__{
        robot: decoded["robot"] || %{},
        joints: decoded["joints"] || [],
        frames: decoded["frames"] || [],
        tools: decoded["tools"] || [],
        mastering: decoded["mastering"] || [],
        taken_at: decoded["takenAt"]
      }

      case decoded["hash"] do
        nil ->
          {:ok, installation}

        stored ->
          actual = hash(installation)
          if stored == actual, do: {:ok, installation}, else: {:error, {:hash_mismatch, stored, actual}}
      end
    end
  end

  defp check_format(%{"format" => "emotion.installation", "formatVersion" => v})
       when v <= @format_version,
       do: :ok

  defp check_format(%{"format" => "emotion.installation", "formatVersion" => v}),
    do: {:error, {:format_too_new, v}}

  defp check_format(_other), do: {:error, :not_an_installation_file}

  @doc "Write a backup."
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = installation, path), do: File.write(path, to_json(installation))

  @doc "Read a backup."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, raw} <- File.read(path), do: from_json(raw)
  end

  @doc "A sensible file name: `arctos.emi`."
  @spec filename(t()) :: String.t()
  def filename(%__MODULE__{} = installation) do
    installation |> name() |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_") |> Kernel.<>(".emi")
  end

  # ── Restoring ─────────────────────────────────────────────────────────────

  @doc """
  What installing this backup would do, without doing any of it.

  A dry run is not a nicety here. `INSTALLATION.md` requires that reconciling
  the two copies is "an explicit push or pull that a person asks for", and a
  person cannot ask for something they have not been shown. This is what the
  dialog reads out before the button does anything.

  Returns a list of steps, each `{action, kind, name, reason}`:

      {:create, :frame, "fixture", nil}
      {:replace, :tool, "welder", nil}
      {:skip, :mastering, "j3", :belongs_to_the_unit}

  The skips carry a reason rather than being omitted. An operator who cannot
  see that mastering was *deliberately* not restored will assume it was, which
  is the belief that ends at the workpiece.
  """
  @spec plan(t(), keyword()) :: {:ok, [tuple()]} | {:error, term()}
  def plan(%__MODULE__{} = installation, opts \\ []) do
    with {:ok, current} <- pull(opts) do
      {:ok,
       Enum.concat([
         steps(:frame, installation.frames, current.frames),
         steps(:tool, installation.tools, current.tools),
         steps(:joint, installation.joints, current.joints, "joint"),
         robot_step(installation, current),
         Enum.map(installation.mastering, &{:skip, :mastering, &1["axis"], :belongs_to_the_unit})
       ])}
    end
  end

  defp steps(kind, incoming, existing, key \\ "name") do
    have = MapSet.new(existing, & &1[key])

    incoming
    |> Enum.sort_by(& &1[key])
    |> Enum.map(fn row ->
      action = if MapSet.member?(have, row[key]), do: :replace, else: :create
      {action, kind, row[key], nil}
    end)
  end

  # The robot description is not restorable and this says so rather than
  # silently omitting it. `PROGRAMS.md` gap 1: the chain is
  # `ExMove.Library.demo()`, compile-time, so writing a URDF here would not
  # change what the arm actually is — it would change what the database claims
  # the arm is, which is worse than not writing it.
  defp robot_step(%__MODULE__{} = installation, current) do
    incoming = Map.get(installation.robot, "name") || ""
    live = Map.get(current.robot, "name") || ""

    cond do
      incoming == "" -> []
      incoming == live -> [{:skip, :robot, incoming, :already_commissioned}]
      true -> [{:skip, :robot, incoming, :chain_is_compile_time}]
    end
  end

  @doc """
  Install the parts of this backup that may be installed.

  Frames, tools and joint commissioning. Not mastering, and not the robot
  description — see `plan/2` for why each is skipped and MASTERING.md for what
  restoring an offset would silently cost.

  Frames go first and parents before children, because a frame that names a
  parent the controller does not have yet is refused, and the refusal would be
  a fact about ordering rather than about the backup.

  Returns what it did, in the same shape `plan/2` returns, with failures
  carrying the controller's own refusal.
  """
  @spec install(t(), keyword()) :: {:ok, [tuple()]} | {:error, term()}
  def install(%__MODULE__{} = installation, opts \\ []) do
    with {:ok, plan} <- plan(installation, opts) do
      by_name = fn rows -> Map.new(rows, &{&1["name"], &1}) end
      frames = by_name.(installation.frames)
      tools = by_name.(installation.tools)
      joints = Map.new(installation.joints, &{&1["joint"], &1})

      done =
        for {action, kind, name, reason} <- order(plan, installation) do
          case {action, kind} do
            {:skip, _} ->
              {:skip, kind, name, reason}

            {_, :frame} ->
              apply_step(action, kind, name, "cell.teach_frame", frame_args(frames[name]), opts)

            {_, :tool} ->
              apply_step(action, kind, name, "cell.teach_tool", tool_args(tools[name]), opts)

            {_, :joint} ->
              apply_step(action, kind, name, "cell.commission", joint_args(joints[name]), opts)
          end
        end

      {:ok, done}
    end
  end

  # Parents before children. A frame hierarchy is a tree and the controller
  # resolves a parent by name at write time, so depth order is the only order
  # that works. Cycles cannot arise — the controller refuses them — but a
  # backup edited by hand could name a parent that is not in the file, and that
  # frame sorts last and fails on its own rather than taking the others down.
  defp order(plan, %__MODULE__{} = installation) do
    depth = frame_depths(installation.frames)

    Enum.sort_by(plan, fn {_action, kind, name, _reason} ->
      case kind do
        :frame -> {0, Map.get(depth, name, 999), name}
        :tool -> {1, 0, name}
        :joint -> {2, 0, name}
        _other -> {3, 0, name}
      end
    end)
  end

  defp frame_depths(frames) do
    parents = Map.new(frames, &{&1["name"], &1["parent"]})

    Map.new(parents, fn {name, _parent} -> {name, depth_of(name, parents, 0)} end)
  end

  defp depth_of(_name, _parents, n) when n > 32, do: 999

  defp depth_of(name, parents, n) do
    case Map.get(parents, name) do
      p when p in [nil, ""] -> n
      parent -> if Map.has_key?(parents, parent), do: depth_of(parent, parents, n + 1), else: n
    end
  end

  defp apply_step(action, kind, name, node_id, args, opts) do
    case Link.call(node_id, args, opts) do
      {:ok, _result} -> {action, kind, name, nil}
      {:error, reason} -> {:failed, kind, name, reason}
    end
  end

  defp frame_args(nil), do: %{}

  defp frame_args(frame) do
    frame
    |> pose_args()
    |> Map.merge(%{"name" => frame["name"], "parent" => frame["parent"] || ""})
  end

  defp tool_args(nil), do: %{}
  defp tool_args(tool), do: Map.put(pose_args(tool), "name", tool["name"])

  defp pose_args(row) do
    Map.new(~w(x y z rx ry rz), fn key -> {key, row[key] || 0.0} end)
  end

  defp joint_args(nil), do: %{}

  defp joint_args(j) do
    %{
      "joint" => j["joint"],
      "axis" => j["axis"] || "",
      "max_vel" => j["max_vel"] || 0.0,
      "max_acc" => j["max_acc"] || 0.0,
      "soft_lower" => j["soft_lower"] || 0.0,
      "soft_upper" => j["soft_upper"] || 0.0,
      "home" => j["home"] || 0.0
    }
  end

  @doc """
  A plan or a result, in words.

      create   frame  fixture
      replace  tool   welder
      skip     robot  arctos      (chain is compile-time)
      skip     mastering j3        (belongs to the unit)
  """
  @spec describe([tuple()]) :: String.t()
  def describe(steps) do
    Enum.map_join(steps, "\n", fn {action, kind, name, reason} ->
      note =
        case reason do
          nil -> ""
          atom when is_atom(atom) -> "   (" <> String.replace(to_string(atom), "_", " ") <> ")"
          other -> "   (" <> inspect(other) <> ")"
        end

      "#{String.pad_trailing(to_string(action), 8)} #{String.pad_trailing(to_string(kind), 10)} #{String.pad_trailing(to_string(name), 18)}#{note}"
    end)
  end

  # ── Comparison ────────────────────────────────────────────────────────────

  @doc """
  What changed between two installations, per axis, for mastering only.

  The same three answers `ExStore.Masterings.compare/3` gives, asked of two
  files instead of a database and a fleet. This is the whole reason a dated
  backup is worth keeping: "what was J3's offset in March, and when did it
  change" is answerable off the machine, in a diff, without the controller.

  Deliberately narrow. Comparing frames or joint settings is a different
  question with a different answer shape, and a general differ that returned
  everything would bury the one finding that matters.
  """
  @spec compare_mastering(t(), t()) :: [
          {:changed, String.t(), float(), float()} | {:lost, String.t(), float()} | {:new, String.t(), float()}
        ]
  def compare_mastering(%__MODULE__{} = before, %__MODULE__{} = now) do
    was = Map.new(before.mastering, &{&1["axis"], &1})
    is = Map.new(now.mastering, &{&1["axis"], &1})

    axes = (Map.keys(was) ++ Map.keys(is)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(axes, fn axis ->
      case {Map.get(was, axis), Map.get(is, axis)} do
        {nil, %{} = b} ->
          [{:new, axis, b["offset"] || 0.0}]

        {%{} = a, nil} ->
          [{:lost, axis, a["offset"] || 0.0}]

        {%{} = a, %{} = b} ->
          # Compared as text, through the same rounding the hash uses. Two
          # numbers that render identically cannot make a hash differ, so
          # calling them changed here would report a difference nothing else
          # in the system can see.
          if Canonical.number(a["offset"]) == Canonical.number(b["offset"]) and
               a["state"] == b["state"] do
            []
          else
            [{:changed, axis, a["offset"] || 0.0, b["offset"] || 0.0}]
          end
      end
    end)
  end
end
