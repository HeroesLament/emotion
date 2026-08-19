defmodule EMotion.Cell do
  @moduledoc """
  The arm as it is currently fitted and framed.

  `EMotion.Schema.Registry.arm_chain/0` is the arm: joints, axes, geometry that
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

  alias EMotion.Schema.Registry
  alias ExMove.{FK, Frame, JointState}
  alias ExStore.Cell.Point
  alias ExStore.{Frames, Points, Robots, Tools}

  @doc """
  The kinematic chain with the fitted tool on it.

  A bare flange is a real answer: with nothing fitted the TCP is the flange,
  which is where the arm's tool centre point actually is after a changeover
  nobody finished.
  """
  def chain do
    chain = Registry.arm_chain()

    # The flange belongs to the mechanism and the tool belongs to whoever
    # bolted one on, so the URDF and the store each own one of them and this is
    # the only place they meet. Order matters and is the readable one: out from
    # the last axis to the mounting face, then out to the tool centre point.
    %{chain | tool: FK.compose(chain.flange, tool())}
  end

  @doc """
  What every joint of the loaded arm says about its own zero.

  A report, not a judgement: `[%{axis_id:, state:, offset:, drift:}]` in chain
  order. `state` is `:referenced`, `:unreferenced`, `:unmastered` or
  `:unreadable`, and they are different missing facts rather than severity
  levels — an operator told only "not ready" has to go and find out which.
  """
  def mastering, do: ExMove.Mastering.report(chain())

  @doc """
  True when every joint knows where it is.

  This is the precondition for anything that builds a pose: Cartesian motion,
  teaching, running a program. Joint jog is deliberately NOT gated on it,
  because driving to the witness mark is how an unreferenced axis is recovered.
  """
  def referenced?, do: ExMove.Mastering.check(chain()) == :ok

  @doc """
  Declares that `axis_id` is right now at `at` radians, and records it.

  The drive persists the offset; this writes a shadow row so the change has a
  date and a predecessor. That ordering matters — the controller must never be
  the source of a mastering, only a witness to one. See
  `servo4257-rs/docs/MASTERING.md`.

  Refused while the drive's output stage is on, by the drive itself.
  """
  def master_axis(axis_id, at \\ 0.0) do
    with {:ok, offset} <- EMotion.Axis.master(axis_id, at) do
      record_mastering(axis_id, offset, "taught")
      {:ok, offset}
    end
  end

  @doc """
  Gives an axis an offset that came off the board being replaced.

  Not the same operation as `master_axis/2` and deliberately not reachable the
  same way. Mastering says "the arm is at this angle"; this says "your offset
  is this number", which is only true when the number came from the hardware
  being swapped out.

  Refused by the drive unless the axis is unmastered, which is what makes the
  stale-restore failure impossible rather than merely discouraged. Recorded
  with source `restored` so the shadow's history says how the number arrived —
  `MASTERING.md` wants to answer "when did this change, and who changed it",
  and "a person typed it in from a backup" is a different answer from "a drive
  reported it".
  """
  def restore_mastering(axis_id, offset) when is_number(offset) do
    with :ok <- EMotion.Axis.restore_master_offset(axis_id, offset) do
      record_mastering(axis_id, offset, "restored")
      {:ok, offset}
    end
  end

  @doc """
  Writes down what the fleet currently says, and reports what changed.

  Called at boot. The findings are the point: an axis re-mastered underneath a
  cell full of taught points is invisible everywhere else, because every joint
  still reports a plausible angle and every move still executes cleanly.
  """
  def audit_mastering do
    case ExStore.Robots.active() do
      nil ->
        {:ok, []}

      robot ->
        report = mastering()
        observed = Map.new(report, &{to_string(&1.axis_id), &1.offset})
        findings = ExStore.Masterings.compare(robot.id, observed)

        ExStore.Masterings.snapshot(
          robot.id,
          Map.new(report, &{to_string(&1.axis_id), %{offset: &1.offset, state: &1.state}})
        )

        {:ok, findings}
    end
  end

  defp record_mastering(axis_id, offset, source) do
    case ExStore.Robots.active() do
      nil ->
        :ok

      robot ->
        ExStore.Masterings.record(%{
          robot_id: robot.id,
          axis_id: to_string(axis_id),
          offset: offset,
          state: "referenced",
          source: source
        })
    end
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

  # ── Points ────────────────────────────────────────────────────────────────

  @doc """
  Records where the arm is now as a named point.

  Everything that makes a point replayable is captured in one read, and that is
  the reason this is a function here rather than a few calls at a call site:
  the pose, the joint solution behind it, the frame it is expressed in and the
  tool that was fitted have to describe the *same instant*. Assembled from
  separate reads while somebody is hand-guiding the arm, they describe a
  machine that was never in any one of those states.

  The pose is stored in the frame, which is what makes re-teaching the frame
  move the point.
  """
  def teach_point(name, opts \\ []) do
    frame_name = Keyword.get(opts, :frame, "base")
    chain = chain()

    with {:ok, robot} <- loaded_robot(),
         {:ok, %JointState{} = js} <- JointState.read(chain),
         {:ok, in_frame} <- pose_in_frame(frame_name, FK.solve(chain, js)),
         {:ok, frame_id} <- frame_id(frame_name) do
      Points.teach(%{
        name: name,
        robot_id: robot.id,
        frame_id: frame_id,
        tool_id: fitted_tool_id(),
        x: in_frame.x,
        y: in_frame.y,
        z: in_frame.z,
        rx: in_frame.rx,
        ry: in_frame.ry,
        rz: in_frame.rz,
        joints: js.positions,
        mutable: Keyword.get(opts, :mutable, false)
      })
    end
  end

  @doc """
  Where a point is now, in the base.

  "Now" is the operative word and the reason this is computed rather than
  stored: the answer changes when the frame the point was taught in is
  re-taught, which is the entire purpose of having frames.
  """
  def point_in_base(%Point{} = point) do
    case point.frame_id do
      nil ->
        {:ok, pose_of(point)}

      frame_id ->
        # Through `resolve/1`, which composes the frame's parents, rather than
        # the frame's own six numbers. Composing only those worked perfectly
        # for a flat frame and put a point taught in a jig on a table wherever
        # the jig would be if the table were at the origin — a pose that is
        # wrong and entirely plausible. Found by the test for re-teaching a
        # parent, which is the only shape that can tell the two apart.
        case Frames.get(frame_id) do
          nil ->
            {:error, :unknown_frame}

          frame ->
            with {:ok, resolved} <- resolve(frame.name) do
              {:ok, FK.compose(resolved, pose_of(point))}
            end
        end
    end
  end

  @doc """
  Whether the tool fitted now is the tool that was fitted when this was taught.

  Not a formality. A pose taught with one tool does not describe the same
  physical location with another, so replaying a point under a different tool
  sends the arm somewhere nobody taught — and the failure is silent, because
  every number involved is perfectly valid.
  """
  def tool_matches?(%Point{tool_id: taught}), do: taught == fitted_tool_id()

  @doc "The name of the tool a point was taught with, or `nil` for a bare flange."
  def point_tool_name(%Point{tool_id: nil}), do: nil

  def point_tool_name(%Point{tool_id: tool_id}) do
    case Tools.get(tool_id) do
      nil -> nil
      tool -> tool.name
    end
  end

  @doc "The name of the frame a point was taught in. `\"base\"` when it has none."
  def point_frame_name(%Point{frame_id: nil}), do: "base"

  def point_frame_name(%Point{frame_id: frame_id}) do
    case Frames.get(frame_id) do
      nil -> "base"
      frame -> frame.name
    end
  end

  defp pose_of(point) do
    %Frame{x: point.x, y: point.y, z: point.z, rx: point.rx, ry: point.ry, rz: point.rz}
  end

  defp fitted_tool_id do
    case Tools.fitted() do
      nil -> nil
      tool -> tool.id
    end
  end

  defp frame_id("base"), do: {:ok, nil}

  defp frame_id(name) do
    case Frames.by_name(name) do
      nil -> {:error, :unknown_frame}
      frame -> {:ok, frame.id}
    end
  end

  # A point belongs to the arm it was taught on, and this controller has one.
  # With nothing commissioned there is nothing to attribute a joint vector to,
  # and inventing a robot row to hang it off would be storing a point that
  # cannot be replayed.
  defp loaded_robot do
    case Robots.active() do
      nil -> {:error, :no_robot}
      robot -> {:ok, robot}
    end
  end

  defp to_frame(%{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}) do
    %Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}
  end
end
