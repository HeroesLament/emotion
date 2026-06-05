defmodule Exdrive.Trajectory do
  @moduledoc """
  Behaviour for IP mode trajectory sources.

  A trajectory is a module that produces position setpoints on demand.
  The IpStream calls `next/2` each cycle, passing the elapsed time `t`
  in seconds and the current module state. The module returns the next
  position and updated state.

  Hot reload works correctly — the module atom is resolved fresh each
  tick via apply/3, so `r MyTrajectory` in iex takes effect immediately.

  Example:

      defmodule MyBot.Trajectories.Sine do
        @behaviour Exdrive.Trajectory

        @impl true
        def init(opts) do
          {:ok, %{
            amplitude: Keyword.get(opts, :amplitude, 90.0),
            period:    Keyword.get(opts, :period,    2.0),
            offset:    Keyword.get(opts, :offset,    0.0),
          }}
        end

        @impl true
        def next(t, state) do
          pos = state.offset + state.amplitude *
                :math.sin(2 * :math.pi * t / state.period)
          {:ok, pos, state}
        end
      end
  """

  @doc "Initialise trajectory state from opts. Return {:ok, state} or {:error, reason}."
  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  Return the next position setpoint for time `t` (seconds since stream start).

  Return values:
    {:ok, position, new_state}  — normal, keep streaming
    {:done, new_state}          — trajectory complete, IpStream will stop or loop
    {:error, reason}            — fault, IpStream will stop and notify
  """
  @callback next(t :: float(), state :: term()) ::
    {:ok, position :: float(), new_state :: term()} |
    {:done, new_state :: term()} |
    {:error, reason :: term()}
end
