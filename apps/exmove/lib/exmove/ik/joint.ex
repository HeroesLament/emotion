defmodule ExMove.IK.Joint do
  @moduledoc """
  Flat joint geometry struct passed to the Rust IK NIF.
  limit_lo >= limit_hi means continuous (no limit) — solver uses 0.0 as midpoint.
  """
  defstruct [
    origin_x: 0.0, origin_y: 0.0, origin_z: 0.0,
    roll:  0.0, pitch: 0.0, yaw: 0.0,
    axis_x: 0.0, axis_y: 0.0, axis_z: 1.0,
    limit_lo: 1.0, limit_hi: -1.0,  # lo > hi = continuous
  ]
end
