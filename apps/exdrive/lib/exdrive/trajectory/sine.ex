defmodule Exdrive.Trajectory.Sine do
  @moduledoc """
  Joint-space sine wave trajectory — demo/test use only.

  Produces a continuous sine wave in position space. Useful for exercising
  the IP mode pipeline and visualising in Exdash without needing ExMove or
  real kinematics.

  This is NOT a Cartesian trajectory. It operates directly in joint space
  and has no awareness of machine geometry. Real motion programs live above
  ExMove.

  Options:
    :amplitude  — peak displacement from offset, default 90.0
    :period     — seconds per full cycle, default 2.0
    :offset     — centre position, default 0.0
    :phase      — initial phase in radians, default 0.0
  """

  @behaviour Exdrive.Trajectory

  @impl true
  def init(opts) do
    {:ok, %{
      amplitude: Keyword.get(opts, :amplitude, 90.0),
      period:    Keyword.get(opts, :period,    2.0),
      offset:    Keyword.get(opts, :offset,    0.0),
      phase:     Keyword.get(opts, :phase,     0.0),
    }}
  end

  @impl true
  def next(t, state) do
    pos = state.offset +
          state.amplitude * :math.sin(2 * :math.pi * t / state.period + state.phase)
    {:ok, pos, state}
  end
end
