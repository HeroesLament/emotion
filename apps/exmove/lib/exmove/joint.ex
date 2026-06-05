defmodule ExMove.Joint do
  @moduledoc """
  A single actuated joint in a kinematic chain.

  `id` maps directly to an Exdrive axis_id — Exdrive.push(joint.id, pos).
  `limit` is {min, max} in radians (revolute) or meters (prismatic).
  nil limit means continuous — no software limit enforced here.
  `max_vel` is in rad/s (revolute) or m/s (prismatic). nil means unlimited.
  `max_acc` is in rad/s² or m/s². nil means unlimited.
  """

  @enforce_keys [:id, :name, :type, :axis, :origin, :rpy]
  defstruct [
    id:      nil,              # atom  — :j1, :j2, ...
    name:    nil,              # string — "joint1", from URDF
    type:    :revolute,        # :revolute | :prismatic | :fixed
    axis:    {0.0, 0.0, 1.0}, # unit vector in parent frame
    origin:  {0.0, 0.0, 0.0}, # xyz translation from parent, meters
    rpy:     {0.0, 0.0, 0.0}, # roll-pitch-yaw from parent, radians
    limit:   nil,              # {min, max} | nil (continuous)
    max_vel: nil,              # float | nil — rad/s or m/s
    max_acc: nil,              # float | nil — rad/s² or m/s²
  ]
end
