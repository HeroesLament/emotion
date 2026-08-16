defmodule ExMo.Cell do
  @moduledoc """
  The arm as it is currently fitted and framed.

  `ExMo.Schema.Registry.arm_chain/0` is the arm: joints, axes, geometry that
  does not change while the machine is running. This module is the arm *right
  now* — which tool is on the flange, and what a frame name resolves to — and
  it is the only place in the suite where stored geometry and kinematics meet.

  The split is deliberate and it is the one that keeps the layers honest.
  `exstore` holds rows and knows nothing about matrices; `exmove` composes
  matrices and knows nothing about a database; and the arithmetic that turns a
  row into a transform happens here, in the app that already depends on both.

  ## On reading the database in a loop

  The fitted tool is read from SQLite on every call, and the call sites include
  a projection that runs at up to 30 Hz. That is one indexed row from a WAL
  database in the same OS process — microseconds — and it is the honest
  implementation until it is measured to be a problem. What is *not* done here
  is reading it at 200 Hz: `ExMove.CartesianStream` captures the chain when the
  motion is accepted and never looks again, which is also what makes a tool
  change mid-move impossible rather than merely discouraged.
  """

  alias ExMo.Schema.Registry
  alias ExMove.{FK, Frame}
  alias ExStore.{Frames, Tools}

  @doc """
  The kinematic chain with the fitted tool on it.

  A bare flange is a real answer: with nothing fitted the TCP is the flange,
  which is where the arm's tool centre point actually is after a changeover
  nobody finished.
  """
  def chain do
    %{Registry.arm_chain() | tool: tool()}
  end

  @doc "The fitted tool as a transform from the flange. Identity when bare."
  def tool do
    case Tools.fitted() do
      nil -> %Frame{}
      tool -> to_frame(tool)
    end
  end

  @doc "The name of the fitted tool, or `nil`. What a pendant displays."
  def tool_name do
    case Tools.fitted() do
      nil -> nil
      tool -> tool.name
    end
  end

  @doc """
  Resolves a frame name to what `ExMove.CartesianStream` takes.

  `base` and `tool` are the two the controller computes rather than stores, and
  they are refused as stored names by `ExStore.Geometry.Frame` so that a row can
  never shadow one. Everything else is a lookup, composed with its parents down
  from the root — a jig on a table is the table's transform then the jig's, and
  a frame whose parent has been re-taught moves with it without being touched.

  An unknown name is an error and not a fallback to base. A pendant showing
  USER while the arm moves in WORLD is the kind of wrong a fixture finds first.
  """
  def frame("base"), do: {:ok, :base}
  def frame("tool"), do: {:ok, :tool}
  def frame(:base), do: {:ok, :base}
  def frame(:tool), do: {:ok, :tool}

  def frame(name) when is_binary(name) do
    case resolve(name) do
      {:ok, frame} -> {:ok, {:user, frame}}
      error -> error
    end
  end

  def frame(_other), do: {:error, :unknown_frame}

  @doc """
  A stored frame as a single transform in the base, parents composed in.

  Separate from `frame/1` because a target pose needs the transform itself
  rather than the tag the stream takes.
  """
  def resolve(name) when is_binary(name) do
    with %{} = row <- Frames.by_name(name),
         lineage when is_list(lineage) <- Frames.lineage(row) do
      {:ok, Enum.reduce(lineage, %Frame{}, fn link, acc -> FK.compose(acc, to_frame(link)) end)}
    else
      nil -> {:error, :unknown_frame}
      # A broken tree — a cycle or a missing parent written by something that
      # was not `ExStore.Frames`. Refused, loudly, rather than resolved to
      # whatever the walk managed to collect before it gave up.
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A pose given in a named frame, expressed in the base."
  def pose_in_base("base", %Frame{} = pose), do: {:ok, pose}

  def pose_in_base(name, %Frame{} = pose) when is_binary(name) do
    with {:ok, frame} <- resolve(name), do: {:ok, FK.compose(frame, pose)}
  end

  @doc "A pose given in the base, expressed in a named frame. Teaching runs this way."
  def pose_in_frame("base", %Frame{} = pose), do: {:ok, pose}

  def pose_in_frame(name, %Frame{} = pose) when is_binary(name) do
    with {:ok, frame} <- resolve(name), do: {:ok, FK.express_in(frame, pose)}
  end

  defp to_frame(%{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}) do
    %Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}
  end
end
