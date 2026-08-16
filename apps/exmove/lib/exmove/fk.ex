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
