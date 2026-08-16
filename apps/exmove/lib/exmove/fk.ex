defmodule ExMove.FK do
  @moduledoc """
  Forward kinematics for a serial kinematic chain.

  Pure function — no side effects, no GenServer.

      chain = ExMove.URDF.load(:arctos) |> elem(1)
      js    = ExMove.JointState.zero(6)
      frame = ExMove.FK.solve(chain, js)
      #=> %ExMove.Frame{x: ..., y: ..., z: ..., rx: ..., ry: ..., rz: ...}

  For each joint, builds:

      T_i = T_translation(origin) · R_rpy(rpy) · R_axis(axis, θ_i)

  Then composes base → tip, applies tool offset.
  """

  alias ExMove.{Chain, Frame, JointState, Math}

  @doc """
  Solve FK for a chain at the given joint state.
  Returns a %Frame{} representing the TCP pose in the base frame.
  """
  def solve(%Chain{} = chain, %JointState{} = js) do
    tcp = solve_transform(chain, js)

    {x, y, z}    = Math.translation_of(tcp)
    {rx, ry, rz} = Math.rpy_of(tcp)

    %Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}
  end

  @doc """
  Solve FK and return the TCP transform itself rather than a `%Frame{}`.

  A `%Frame{}` carries orientation as roll, pitch and yaw, and rebuilding a
  rotation matrix from those is a round trip through a parameterisation that is
  singular at gimbal lock. Anything that needs the tool's *axes* — rotating a
  twist into the tool frame, for one — should take them from here and never
  compose Euler angles it did not have to.
  """
  def solve_transform(%Chain{} = chain, %JointState{positions: positions}) do
    transforms =
      chain.joints
      |> Enum.zip(positions)
      |> Enum.map(fn {joint, theta} -> joint_transform(joint, theta) end)

    Math.compose(transforms ++ [frame_to_transform(chain.tool)])
  end

  @doc """
  Solve FK and return the full list of intermediate frame poses,
  one per joint (useful for visualisation / debugging).
  """
  def solve_frames(%Chain{} = chain, %JointState{positions: positions}) do
    transforms =
      chain.joints
      |> Enum.zip(positions)
      |> Enum.map(fn {joint, theta} -> joint_transform(joint, theta) end)

    transforms
    |> Enum.scan(Math.identity(), &Math.mul(&2, &1))
    |> Enum.map(&transform_to_frame/1)
  end

  @doc """
  A `%Frame{}` as a transform.

  Public because a target pose is a frame and anything comparing one against
  where the arm actually is needs both in the same representation — and building
  a second copy of this conversion is how two parts of a controller come to
  disagree about what a pose means.
  """
  def frame_transform(frame), do: frame_to_transform(frame)

  @doc """
  A pose expressed in `outer`, expressed in whatever `outer` is expressed in.

  The whole of what a user frame does. A point taught at `inner` inside a
  fixture frame is at `compose(fixture, inner)` in the base, and re-teaching
  the fixture moves it — which is the single property frames exist for.

  Composition is not commutative and the argument order is the one that reads
  left to right from the base outwards: `compose(table, jig)` is the jig on the
  table. Getting it backwards produces a pose that is wrong and plausible,
  which is the worst kind, so there is exactly one of these in the suite.
  """
  def compose(outer, inner) do
    outer
    |> frame_to_transform()
    |> Math.mul(frame_to_transform(inner))
    |> transform_to_frame()
  end

  @doc """
  The inverse of `compose/2`: a pose in the base, expressed in `outer`.

  Teaching runs this way round. The arm reports where it is in the base, the
  pendant says USER, and what gets stored is the pose in the frame — so that
  moving the frame later moves the point.
  """
  def express_in(outer, pose) do
    outer
    |> frame_to_transform()
    |> Math.invert_rigid()
    |> Math.mul(frame_to_transform(pose))
    |> transform_to_frame()
  end

  # --- Private --------------------------------------------------------------

  defp joint_transform(joint, theta) do
    {ox, oy, oz} = joint.origin
    {roll, pitch, yaw} = joint.rpy

    t_origin = Math.translation(ox, oy, oz)
    r_rpy    = Math.rotation_rpy(roll, pitch, yaw)
    r_joint  = Math.rotation_axis(joint.axis, theta)

    Math.mul(Math.mul(t_origin, r_rpy), r_joint)
  end

  defp frame_to_transform(nil), do: Math.identity()

  defp frame_to_transform(%Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}) do
    Math.mul(Math.translation(x, y, z), Math.rotation_rpy(rx, ry, rz))
  end

  defp transform_to_frame(t) do
    {x, y, z}    = Math.translation_of(t)
    {rx, ry, rz} = Math.rpy_of(t)
    %Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}
  end
end
