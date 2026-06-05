defmodule ExMove.Trajectory do
  @moduledoc """
  Behaviour for robot-level trajectory sources.

  Produces a JointState per tick — one position per joint in chain order.
  This is distinct from Exdrive.Trajectory which produces a single float
  for one axis.

  The chain is passed to init/1 so the trajectory knows the DOF and can
  produce correctly-sized JointState lists without being told explicitly.
  """

  alias ExMove.JointState

  @doc "Initialise trajectory state. Chain is always in opts as :chain."
  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  Return the next JointState for time t (seconds since stream start).

    {:ok, %JointState{}, new_state}  — normal, keep streaming
    {:done, new_state}               — trajectory complete
    {:error, reason}                 — fault, stream stops
  """
  @callback next(t :: float(), state :: term()) ::
    {:ok, JointState.t(), new_state :: term()} |
    {:done, new_state :: term()} |
    {:error, reason :: term()}
end
