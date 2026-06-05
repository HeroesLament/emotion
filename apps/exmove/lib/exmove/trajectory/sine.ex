defmodule ExMove.Trajectory.Sine do
  @moduledoc """
  Joint-space sine wave trajectory for all joints — demo/test use only.

  Each joint gets an independent sine wave with configurable amplitude
  and phase offset, so the arm does a slow ripple rather than all joints
  moving in lockstep.

  Options:
    :amplitude  — peak displacement in radians, default 0.3
    :period     — seconds per full cycle, default 4.0
    :phase_step — phase offset between joints in radians, default pi/6
  """

  @behaviour ExMove.Trajectory

  alias ExMove.{Chain, JointState}

  @impl true
  def init(opts) do
    chain      = Keyword.fetch!(opts, :chain)
    amplitude  = Keyword.get(opts, :amplitude,  0.3)
    period     = Keyword.get(opts, :period,      4.0)
    phase_step = Keyword.get(opts, :phase_step,  :math.pi() / 6)
    dof        = Chain.dof(chain)

    phases = Enum.map(0..(dof - 1), &(&1 * phase_step))

    {:ok, %{
      dof:       dof,
      amplitude: amplitude,
      period:    period,
      phases:    phases,
    }}
  end

  @impl true
  def next(t, state) do
    positions = Enum.map(state.phases, fn phase ->
      state.amplitude * :math.sin(2 * :math.pi() * t / state.period + phase)
    end)
    {:ok, JointState.from_positions(positions), state}
  end
end
