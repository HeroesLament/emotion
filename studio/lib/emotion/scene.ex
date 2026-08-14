defmodule EMotion.Scene do
  @moduledoc """
  A cell, as something Cedar can draw.

      nodes = EMotion.Scene.nodes(cell)

      {:ensure_visual, :viewport, :viewport, :root, camera: camera, nodes: nodes}

  Pure. Takes the document and the poses forward kinematics produced, and
  returns a flat list of `Cedar.Visual.Viewport` nodes. No GL, no processes,
  no drawing — which is what makes it possible to assert that an arm is shaped
  correctly without opening a window.

  ## Links are drawn between joints, not at them

  A URDF describes where each joint *is*, not what the metal between them
  looks like. Until real geometry is loaded, a link is the segment from one
  joint's origin to the next one's — which is a decent proxy for an arm and an
  honest one, because it is exactly the information the kinematics actually
  has. A joint gets a marker at its own origin so the articulation is visible;
  the last joint gets one too, and the tool frame extends past it.

  When real meshes arrive, only `link_nodes/3` changes. The camera, the
  viewport, the poses and the whole update path stay as they are, which is the
  point of keeping this a pure function from cell to nodes.
  """

  alias Cedar.Math
  alias Cedar.Visual.Mesh
  alias EMotion.{Cell, Pose}
  alias ExMove.{Chain, FK, JointState}

  @joint_color {0.86, 0.55, 0.16, 1.0}
  @link_color {0.72, 0.73, 0.76, 1.0}
  @base_color {0.42, 0.44, 0.48, 1.0}

  @doc """
  Every robot in the cell, as viewport nodes.

  Node ids are namespaced by robot, so two arms in one cell cannot collide in
  the viewport's geometry cache — which would show up as one arm's links
  jumping to the other's poses.
  """
  @spec nodes(Cell.t(), keyword()) :: [map()]
  def nodes(%Cell{} = cell, opts \\ []) do
    Enum.flat_map(Cell.robots(cell), &robot_nodes(&1, opts))
  end

  @doc """
  One robot's nodes: a base, a marker at each joint, and a link between
  consecutive joints.

  A robot with no chain loaded yet renders as just its base rather than as
  nothing, so an operator can see where it will be before it has geometry.
  """
  @spec robot_nodes(Cell.Robot.t(), keyword()) :: [map()]
  def robot_nodes(robot, opts \\ [])

  def robot_nodes(%Cell.Robot{chain: nil} = robot, opts) do
    [base_node(robot, opts)]
  end

  def robot_nodes(%Cell.Robot{chain: %Chain{} = chain} = robot, opts) do
    base = Pose.from_transform(robot.base || Cell.origin())

    points = joint_positions(chain, robot.joints, base)

    [base_node(robot, opts)] ++
      joint_nodes(robot, points, opts) ++
      link_nodes(robot, points, opts)
  end

  @doc """
  Where each joint sits in world space, base included as the first point.

  Forward kinematics returns poses relative to the robot's own base, so each is
  premultiplied by where that base stands in the cell. Two arms differing only
  in base placement therefore differ only here.
  """
  @spec joint_positions(Chain.t(), [float()], Math.mat4()) :: [Math.vec3()]
  def joint_positions(%Chain{} = chain, positions, base) do
    positions = pad(positions, length(chain.joints))

    frames = FK.solve_frames(chain, %JointState{positions: positions})

    origin = Math.transform_point(base, {0.0, 0.0, 0.0})

    [origin | Enum.map(frames, fn frame -> Math.transform_point(base, Pose.position(frame)) end)]
  end

  # ==========================================================================

  defp base_node(robot, opts) do
    size = Keyword.get(opts, :base_size, 0.18)
    base = Pose.from_transform(robot.base || Cell.origin())

    %{
      id: id(robot, :base),
      mesh: Mesh.box({size * 2, size * 0.4, size * 2}),
      transform: Math.multiply(base, Math.translation({0.0, size * 0.2, 0.0})),
      color: Keyword.get(opts, :base_color, @base_color)
    }
  end

  defp joint_nodes(robot, points, opts) do
    size = Keyword.get(opts, :joint_size, 0.055)
    color = Keyword.get(opts, :joint_color, @joint_color)

    points
    |> Enum.drop(1)
    |> Enum.with_index()
    |> Enum.map(fn {point, i} ->
      %{
        id: id(robot, :"joint#{i}"),
        mesh: Mesh.box(size * 2),
        transform: Math.translation(point),
        color: color
      }
    end)
  end

  defp link_nodes(robot, points, opts) do
    thickness = Keyword.get(opts, :link_thickness, 0.045)
    color = Keyword.get(opts, :link_color, @link_color)

    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.reject(fn {[a, b], _i} -> Math.length(Math.sub(b, a)) < 1.0e-6 end)
    |> Enum.map(fn {[a, b], i} ->
      %{
        id: id(robot, :"link#{i}"),
        mesh: Mesh.box(1.0),
        transform: segment(a, b, thickness),
        color: color
      }
    end)
  end

  @doc """
  A transform mapping the unit box onto the segment from `a` to `b`.

  The box is centred on the origin and one unit across, so this scales it to
  the segment's length on one axis and the requested thickness on the other
  two, rotates that axis onto the segment, and translates to the midpoint.

  Building the rotation as an explicit basis rather than as two Euler angles
  avoids a singularity: a link pointing straight up is the most common
  orientation in a robot at rest, and it is exactly where a yaw-then-pitch
  construction has nothing to work with.
  """
  @spec segment(Math.vec3(), Math.vec3(), number()) :: Math.mat4()
  def segment(a, b, thickness) do
    direction = Math.sub(b, a)
    length = Math.length(direction)

    y = Math.normalize(direction)
    x = Math.normalize(perpendicular(y))
    z = Math.cross(x, y)

    {ax, ay, az} = a
    {bx, by, bz} = b
    midpoint = {(ax + bx) / 2, (ay + by) / 2, (az + bz) / 2}

    {mx, my, mz} = midpoint
    {xx, xy, xz} = Math.scale(x, thickness)
    {yx, yy, yz} = Math.scale(y, length)
    {zx, zy, zz} = Math.scale(z, thickness)

    # Column-major: each basis vector is a column, the midpoint is the fourth.
    [xx, xy, xz, 0.0, yx, yy, yz, 0.0, zx, zy, zz, 0.0, mx, my, mz, 1.0]
  end

  # Any vector not parallel to the input. Choosing the world axis the direction
  # is *least* aligned with keeps the cross product well conditioned, which is
  # what stops a vertical link from producing a degenerate basis.
  defp perpendicular({x, y, z} = direction) do
    axis =
      cond do
        abs(y) <= abs(x) and abs(y) <= abs(z) -> {0.0, 1.0, 0.0}
        abs(x) <= abs(z) -> {1.0, 0.0, 0.0}
        true -> {0.0, 0.0, 1.0}
      end

    Math.cross(direction, axis)
  end

  defp id(robot, part), do: {robot.id, part}

  # A cell can hold a robot whose pose has not been set yet, or a chain longer
  # than the pose it was given. Padding with zeros shows the arm at home rather
  # than refusing to draw it.
  defp pad(positions, count) when length(positions) >= count, do: Enum.take(positions, count)

  defp pad(positions, count) do
    positions ++ List.duplicate(0.0, count - length(positions))
  end
end
