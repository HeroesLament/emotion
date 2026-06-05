defmodule ExMove.Frame do
  @moduledoc """
  A pose in 3D space — position in meters, orientation in radians (RPY).
  Used for FK output and IK targets.
  """

  defstruct [
    x:  0.0, y:  0.0, z:  0.0,   # position, meters
    rx: 0.0, ry: 0.0, rz: 0.0,   # roll, pitch, yaw, radians
  ]
end
