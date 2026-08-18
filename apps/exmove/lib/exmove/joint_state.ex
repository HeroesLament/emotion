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

  @doc """
  Reads where the arm actually is, in the chain's order.

  One observation per joint, and no side effects — which is the difference
  between this and the read inside `ExMove.CartesianStream`, which deliberately
  fuses a drive-mode check into the same pass because it is about to command a
  velocity. Teaching a point must not change what mode a drive is in.

  `{:error, :unreadable}` rather than a partial answer: a pose assembled from
  five joints and a guess is a pose the arm was never in, and it looks like a
  plausible position rather than like a fault.

  For the same reason it reads the JOINT position rather than the drive's
  accumulator, and refuses `{:error, {:unreferenced, axis_id}}` when an axis
  does not know where it is. An unreferenced axis still has an accumulator —
  jogging needs it — but it does not have an angle anybody may build a pose
  from. See `ExMove.Mastering`.
  """
  def read(%ExMove.Chain{axis_ids: axis_ids}) do
    axis_ids
    |> Enum.reduce_while({:ok, []}, fn axis_id, {:ok, acc} ->
      case ExMove.Mastering.read_axis(axis_id) do
        {:ok, position, _status} -> {:cont, {:ok, [position | acc]}}
        {:error, {:unreadable, _axis}} -> {:halt, {:error, :unreadable}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, from_positions(Enum.reverse(reversed))}
      other -> other
    end
  catch
    :exit, _reason -> {:error, :unreadable}
  end

  @doc "Build from a positions list, zero velocities and accelerations"
  def from_positions(positions) when is_list(positions) do
    n = length(positions)
    zeros = List.duplicate(0.0, n)
    %__MODULE__{positions: positions, velocities: zeros, accelerations: zeros}
  end
end
