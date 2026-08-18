defmodule ExProto.Source.Cell do
  @moduledoc """
  The stored geometry, over the protocol: user frames, tools, and which tool is
  fitted.

  Configuration rather than motion, which is why it is its own source. Frames
  and tools live in the controller's database and change when somebody teaches
  them; axes live in drives and change every tick. Serving both from one module
  would put a `case` on a node id prefix in front of two entirely different
  failure modes.

  ## Refusals are refusals, not exceptions

  Every call here can fail for a reason a client can act on — a name that is
  already taken, a frame that is still a parent, a cycle. Those come back as
  `{:error, :rejected}` through the protocol's own vocabulary. What does *not*
  happen is a changeset error crossing the wire as a term nobody can pattern
  match on.
  """

  @behaviour ExProto.Source

  alias ExMo.Cell
  alias ExMove.CartesianStream
  alias ExStore.Cell.Point
  alias ExStore.{Frames, Points, Tools}

  @impl ExProto.Source
  def read("cell.tool", _arg), do: {:ok, Cell.tool_name() || ""}

  # From the loaded chain rather than from the store, deliberately. What this
  # node reports is what the controller is *running*, and after somebody stores
  # and activates a different description those two answers differ until the
  # restart. Reporting the stored one would have a pendant show an arm the
  # controller is not driving.
  def read("cell.robot", _arg), do: {:ok, to_string(Cell.chain().name)}
  def read(_unknown, _arg), do: {:error, :unknown_node}

  @impl ExProto.Source
  def write(_node_id, _value, _arg), do: {:error, :not_writable}

  @impl ExProto.Source
  # Gated on `write_setpoint` rather than `write_configuration`, and the
  # difference is deliberate: teaching a point is what an operator does with a
  # pendant in their hand, all day, and it is the same grant that lets them
  # move the arm there in the first place. Frames and tools are configuration;
  # points are work.
  def call("cell.teach_point", args, _arg) do
    with {:ok, name} <- name(args) do
      frame = Map.get(args, "frame") || "base"
      mutable = Map.get(args, "mutable") == true

      case Cell.teach_point(name, frame: frame, mutable: mutable) do
        {:ok, point} ->
          {:ok,
           %{
             "name" => point.name,
             "frame" => Cell.point_frame_name(point),
             "tool" => Cell.point_tool_name(point) || ""
           }}

        {:error, _reason} ->
          {:error, :rejected}
      end
    end
  end

  def call("cell.forget_point", args, _arg) do
    with {:ok, name} <- name(args) do
      case Points.by_name(name) do
        nil ->
          {:error, :rejected}

        point ->
          case Points.delete(point) do
            {:ok, _} -> :ok
            {:error, _changeset} -> {:error, :rejected}
          end
      end
    end
  end

  def call("cell.list_points", _args, _arg) do
    points =
      for point <- Points.list() do
        point
        |> pose_map()
        |> Map.merge(%{
          "name" => point.name,
          "frame" => Cell.point_frame_name(point),
          "tool" => Cell.point_tool_name(point) || "",
          "joints" => Point.joints(point),
          "mutable" => point.mutable
        })
      end

    {:ok, %{"points" => points}}
  end

  def call("cell.teach_frame", args, _arg) do
    with {:ok, name} <- name(args),
         {:ok, parent_id} <- parent_id(args) do
      attrs = args |> pose() |> Map.merge(%{name: name, parent_id: parent_id})

      case Frames.by_name(name) do
        nil -> created(Frames.create(attrs), name, true)
        frame -> created(Frames.teach(frame, attrs), name, false)
      end
    end
  end

  def call("cell.forget_frame", args, _arg) do
    with {:ok, name} <- name(args) do
      case Frames.by_name(name) do
        nil ->
          {:error, :rejected}

        frame ->
          case Frames.delete(frame) do
            {:ok, _} -> :ok
            {:error, _changeset} -> {:error, :rejected}
          end
      end
    end
  end

  def call("cell.list_frames", _args, _arg) do
    frames =
      for frame <- Frames.list() do
        frame
        |> pose_map()
        |> Map.merge(%{
          "name" => frame.name,
          "parent" => parent_name(frame),
          "mutable" => frame.mutable
        })
      end

    {:ok, %{"frames" => frames}}
  end

  def call("cell.teach_tool", args, _arg) do
    with {:ok, name} <- name(args) do
      attrs = args |> pose() |> Map.put(:name, name)

      case Tools.by_name(name) do
        nil -> created(Tools.create(attrs), name, true)
        tool -> created(Tools.teach(tool, attrs), name, false)
      end
    end
  end

  def call("cell.list_tools", _args, _arg) do
    tools =
      for tool <- Tools.list() do
        tool
        |> pose_map()
        |> Map.merge(%{"name" => tool.name, "fitted" => tool.fitted})
      end

    {:ok, %{"tools" => tools}}
  end

  # Refused while the arm is moving, and this is the interesting one.
  #
  # A move is solved against the chain it was accepted with, so changing the
  # fitted tool halfway through does not steer it — it means the motion was
  # aimed at one point and finishes at another, silently, with nothing in the
  # report to say so. Refusing is the only answer that leaves the machine's
  # story consistent.
  def call("cell.fit_tool", args, _arg) do
    with {:ok, name} <- name(args),
         :ok <- arm_still() do
      case Tools.fit(name) do
        {:ok, _tool} -> :ok
        {:error, _reason} -> {:error, :rejected}
      end
    end
  end

  def call("cell.release_tool", _args, _arg) do
    with :ok <- arm_still() do
      {:ok, _count} = Tools.unfit()
      :ok
    end
  end

  def call(_unknown, _args, _arg), do: {:error, :not_callable}

  # ── Arguments ─────────────────────────────────────────────────────────────

  defp name(args) do
    case Map.get(args, "name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _absent -> {:error, :rejected}
    end
  end

  defp parent_id(args) do
    case Map.get(args, "parent") do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      parent when is_binary(parent) ->
        case Frames.by_name(parent) do
          nil -> {:error, :rejected}
          frame -> {:ok, frame.id}
        end

      _other ->
        {:error, :rejected}
    end
  end

  # Absent is zero rather than unchanged, deliberately. Re-teaching a frame by
  # sending only the axis that moved would leave the other five at whatever they
  # were, which reads as helpful and means a partial write can never be told
  # apart from a full one — and the whole point of a taught frame is that its
  # six numbers were measured together.
  defp pose(args) do
    for field <- ~w(x y z rx ry rz), into: %{} do
      {String.to_existing_atom(field), as_float(Map.get(args, field))}
    end
  end

  defp as_float(nil), do: 0.0
  defp as_float(value) when is_float(value), do: value
  defp as_float(value) when is_integer(value), do: value * 1.0
  defp as_float(_other), do: 0.0

  defp pose_map(row) do
    for field <- ~w(x y z rx ry rz), into: %{} do
      {field, Map.fetch!(row, String.to_existing_atom(field))}
    end
  end

  defp parent_name(%{parent_id: nil}), do: ""

  defp parent_name(%{parent_id: id}) do
    case Frames.get(id) do
      nil -> ""
      parent -> parent.name
    end
  end

  defp created({:ok, _row}, name, created?), do: {:ok, %{"name" => name, "created" => created?}}
  defp created({:error, _changeset}, _name, _created?), do: {:error, :rejected}

  defp arm_still do
    name = ExMo.Schema.Registry.arm_chain().name

    case CartesianStream.status(name) do
      nil -> :ok
      :idle -> :ok
      {:done, _reached} -> :ok
      _moving -> {:error, :rejected}
    end
  end
end
