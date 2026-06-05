defmodule ExMove.JointState do
  @moduledoc """
  Current state of all joints in a chain, in chain order.

  Lists are used (not maps) so the layout matches what a Rust NIF IK solver
  expects — ordered float arrays. The mapping from list index to axis id
  lives in the Chain struct.

  Positions in radians (revolute) or meters (prismatic).
  Velocities in rad/s or m/s.
  Accelerations in rad/s² or m/s².
  """

  defstruct [
    positions:     [],
    velocities:    [],
    accelerations: [],
  ]

  @doc "Zero state for an n-joint chain"
  def zero(n) do
    zeros = List.duplicate(0.0, n)
    %__MODULE__{positions: zeros, velocities: zeros, accelerations: zeros}
  end

  @doc "Build from a positions list, zero velocities and accelerations"
  def from_positions(positions) when is_list(positions) do
    n = length(positions)
    zeros = List.duplicate(0.0, n)
    %__MODULE__{positions: positions, velocities: zeros, accelerations: zeros}
  end
end
