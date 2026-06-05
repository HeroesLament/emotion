defmodule ExMove.Lookahead do
  @moduledoc """
  Async lookahead analyser for feedrate limiting near singularities.

  Runs IK solves on future waypoints in parallel Tasks, building a map of
  `frame_index → feedrate_ceiling`. PathExecutor consults this map each tick
  to get a scale factor (0.0–1.0) before dispatching joint velocities.

  The servo loop is never blocked — `ceiling/2` always returns immediately
  with the last known result for that frame. If analysis hasn't completed yet,
  it returns 1.0 (full speed, assume safe until proven otherwise).

  ## Integration with PathExecutor

      # At executor start:
      {:ok, la} = ExMove.Lookahead.start_link(chain: chain, window: 50, seed: js)

      # Each tick (feed the frame that is `window` ticks ahead):
      ExMove.Lookahead.push(la, frame_index + window, future_frame)

      # Read the ceiling for the frame we're about to execute:
      scale = ExMove.Lookahead.ceiling(la, frame_index)
      # Multiply commanded velocities by scale before pushing to drives.

  ## Kappa → ceiling mapping

  Condition number κ = σ_max / σ_min. Higher κ = closer to singularity.

      κ < κ_low   → ceiling = 1.0   (full speed)
      κ_low..κ_high → ceiling scales linearly from 1.0 → min_ceiling
      κ > κ_high  → ceiling = min_ceiling

  Defaults: κ_low=50, κ_high=500, min_ceiling=0.1
  These are tunable via start_link opts.
  """

  use GenServer

  alias ExMove.{IK, JointState}

  @default_window      50
  @default_kappa_low   50.0
  @default_kappa_high  500.0
  @default_min_ceiling 0.1

  defstruct [
    chain:       nil,
    seed:        nil,     # %JointState{} — best available seed for IK solves
    results:     %{},     # %{frame_index => ceiling}
    kappa_low:   @default_kappa_low,
    kappa_high:  @default_kappa_high,
    min_ceiling: @default_min_ceiling,
    window:      @default_window,
    in_flight:   %{},     # %{frame_index => task_ref} — pending tasks
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the lookahead analyser.

  Required opts:
    - `:chain` — `%ExMove.Chain{}`
    - `:seed`  — `%ExMove.JointState{}` — initial IK seed

  Optional opts:
    - `:window`      — frames ahead to analyse (default #{@default_window})
    - `:kappa_low`   — κ below which ceiling = 1.0 (default #{@default_kappa_low})
    - `:kappa_high`  — κ above which ceiling = min_ceiling (default #{@default_kappa_high})
    - `:min_ceiling` — minimum feedrate scale (default #{@default_min_ceiling})
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Submit a future frame for async analysis.

  Non-blocking. Spawns a Task to IK-solve the frame and cache the result.
  Safe to call every tick — duplicate pushes for the same index are ignored.
  """
  def push(pid, frame_index, frame) do
    GenServer.cast(pid, {:push, frame_index, frame})
  end

  @doc """
  Get the feedrate ceiling for a frame index.

  Returns a float 0.0–1.0. Non-blocking — returns 1.0 if analysis is pending
  or if the index has no cached result (assume safe).
  """
  def ceiling(pid, frame_index) do
    GenServer.call(pid, {:ceiling, frame_index})
  end

  @doc """
  Update the seed joint state used for IK solves.

  Call each tick with the executor's current joint state so lookahead solves
  start from a realistic seed rather than drifting from the initial one.
  """
  def update_seed(pid, %JointState{} = js) do
    GenServer.cast(pid, {:update_seed, js})
  end

  @doc "Flush all cached results and in-flight tasks."
  def reset(pid) do
    GenServer.call(pid, :reset)
  end

  @doc "Current cache stats — useful for tuning window size."
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    chain       = Keyword.fetch!(opts, :chain)
    seed        = Keyword.fetch!(opts, :seed)
    window      = Keyword.get(opts, :window,      @default_window)
    kappa_low   = Keyword.get(opts, :kappa_low,   @default_kappa_low)
    kappa_high  = Keyword.get(opts, :kappa_high,  @default_kappa_high)
    min_ceiling = Keyword.get(opts, :min_ceiling, @default_min_ceiling)

    {:ok, %__MODULE__{
      chain:       chain,
      seed:        seed,
      window:      window,
      kappa_low:   kappa_low,
      kappa_high:  kappa_high,
      min_ceiling: min_ceiling,
    }}
  end

  @impl true
  def handle_cast({:push, frame_index, frame}, state) do
    if Map.has_key?(state.results, frame_index) or
       Enum.any?(state.in_flight, fn {_ref, idx} -> idx == frame_index end) do
      {:noreply, state}
    else
      # Capture frame_index in closure so the result can be matched back
      task = Task.async(fn -> {frame_index, analyse(state.chain, frame, state.seed)} end)
      # Store ref => frame_index so we can look up on completion
      {:noreply, %{state | in_flight: Map.put(state.in_flight, task.ref, frame_index)}}
    end
  end

  def handle_cast({:update_seed, js}, state) do
    {:noreply, %{state | seed: js}}
  end

  @impl true
  def handle_call({:ceiling, frame_index}, _from, state) do
    ceiling = Map.get(state.results, frame_index, 1.0)
    {:reply, ceiling, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | results: %{}, in_flight: %{}}}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      cached:    map_size(state.results),
      in_flight: map_size(state.in_flight),
      window:    state.window,
    }
    {:reply, stats, state}
  end

  # Task completion — {ref, {frame_index, kappa}} from Task.async
  @impl true
  def handle_info({ref, {frame_index, kappa}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    ceiling   = kappa_to_ceiling(kappa, state)
    results   = Map.put(state.results, frame_index, ceiling)
    in_flight = Map.delete(state.in_flight, ref)
    {:noreply, %{state | results: results, in_flight: in_flight}}
  end

  # Task DOWN (crash) — remove from in_flight
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | in_flight: Map.delete(state.in_flight, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Run on a BEAM scheduler thread — not blocking the GenServer.
  # Returns {frame_index, kappa} to be sent back as a Task result.
  defp analyse(chain, frame, seed) do
    # We only need κ — use a fast solve with tight damping and few iterations
    case IK.solve(chain, frame, seed,
                  max_iterations: 100, tolerance: 1.0e-3, damping: 0.05) do
      {:ok,           _js, _w, kappa} -> kappa
      {:near_singular, _js, _w, kappa} -> kappa
      {:constrained,   _js, _w, kappa} -> kappa
      {:error, _}                      -> @default_kappa_high  # treat as worst case
    end
  end

  # Map κ → feedrate ceiling using a linear ramp between kappa_low and kappa_high.
  #
  #   κ ≤ κ_low                  → 1.0
  #   κ_low < κ < κ_high         → lerp(1.0, min_ceiling)
  #   κ ≥ κ_high                 → min_ceiling
  defp kappa_to_ceiling(kappa, state) do
    %{kappa_low: kl, kappa_high: kh, min_ceiling: mc} = state
    cond do
      kappa <= kl -> 1.0
      kappa >= kh -> mc
      true ->
        t = (kappa - kl) / (kh - kl)
        1.0 - t * (1.0 - mc)
    end
  end
end
