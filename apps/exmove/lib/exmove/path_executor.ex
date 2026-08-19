defmodule ExMove.PathExecutor do
  @moduledoc """
  Servo-rate path executor.

  Consumes a stream of `%ExMove.Frame{}` waypoints at 1kHz, converting each
  to joint velocities via `ExMove.IK.solve_velocity/4` and dispatching them
  via an injected push function.

  PathExecutor has no knowledge of Robot, drives, or hardware. All I/O is
  injected at start time, making it fully testable with zero infrastructure.

  Uses a **deadline scheduler** to prevent drift: each tick is scheduled
  against an absolute deadline rather than relative to the previous tick.

      push = fn axis_id, vel -> EMotion.Axis.set_target_velocity(axis_id, vel) end

      {:ok, pid} = ExMove.PathExecutor.start_link(
        chain:  chain,
        seed:   current_joint_state,
        stream: ExMove.Path.linear(frame_a, frame_b, 50.0),
        push:   push,
        notify: self()
      )

      receive do
        {:path_done,  ^pid, stats}      -> IO.inspect(stats)
        {:path_error, ^pid, reason} -> handle_error(reason)
      end

  The executor stops automatically when the stream is exhausted or on error.
  Call `stop/1` for an immediate halt.

  ## Robot integration

  `ExMove.Robot` constructs the push function and starts the executor:

      def execute_path(robot_pid, stream) do
        chain = Robot.chain(robot_pid)
        seed  = Robot.state(robot_pid)
        push  = fn id, vel -> EMotion.Axis.set_target_velocity(id, vel) end
        PathExecutor.start_link(chain: chain, seed: seed, stream: stream,
                                push: push, notify: self())
      end
  """

  use GenServer

  alias ExMove.{FK, IK, JointState}

  @tick_us  1_000    # 1 kHz in microseconds
  @tick_ms  1        # 1 kHz in milliseconds
  @max_consecutive_errors 10

  defstruct [
    chain:          nil,   # %Chain{}          — kinematics, pure data
    current_js:     nil,   # %JointState{}     — integrated each tick
    prev_frame:     nil,   # %Frame{}          — for velocity differentiation
    stream:         nil,   # :queue of %Frame{} — pre-buffered waypoints
    push:           nil,   # (axis_id, vel) -> :ok
    notify:         nil,   # pid | nil         — receives :path_done / :path_error
    deadline:       nil,   # integer           — next tick in monotonic microseconds
    tick_count:     0,     # integer           — total ticks fired
    error_count:    0,     # consecutive IK failures
    min_scale:      1.0,   # lowest velocity scale factor seen (1.0 = never clamped)
    lookahead:      nil,   # ExMove.Lookahead pid | nil — async singularity analyser
    budget:         1.0,   # fractional frame-consumption credit (0..inf)
                           #   += la_ceiling each tick; frame consumed when >= 1.0
    pacing_events:  0,     # ticks where budget < 1.0 and frame was withheld
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a path executor.

  Required opts:
    - `:chain`  — `%ExMove.Chain{}`
    - `:seed`   — `%ExMove.JointState{}` — starting configuration
    - `:stream` — `Enumerable` of `%ExMove.Frame{}`
    - `:push`   — `(axis_id, velocity :: float) -> any` callback

  Optional opts:
    - `:notify` — pid to receive `{:path_done, pid}` or `{:path_error, pid, reason}`
    - `:hz`     — tick rate (default 1000)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Immediate halt — stops the tick loop. Drives are NOT zeroed; caller is responsible."
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc "Current joint state as tracked by the executor."
  def joint_state(pid) do
    GenServer.call(pid, :joint_state)
  end

  @doc "Execution stats."
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    chain  = Keyword.fetch!(opts, :chain)
    seed   = Keyword.fetch!(opts, :seed)
    stream = Keyword.fetch!(opts, :stream)
    push   = Keyword.fetch!(opts, :push)
    notify = Keyword.get(opts, :notify, nil)

    # Optional lookahead — start if caller passes lookahead: true | [opts]
    lookahead = case Keyword.get(opts, :lookahead, false) do
      false -> nil
      true  ->
        {:ok, pid} = ExMove.Lookahead.start_link(chain: chain, seed: seed)
        pid
      la_opts when is_list(la_opts) ->
        {:ok, pid} = ExMove.Lookahead.start_link([chain: chain, seed: seed] ++ la_opts)
        pid
    end

    # Pre-buffer the entire stream into a :queue so that frame consumption
    # is O(1) per tick rather than O(n) due to nested Stream.drop wrappers.
    queue = stream |> Enum.reduce(:queue.new(), fn f, q -> :queue.in(f, q) end)

    state = %__MODULE__{
      chain:      chain,
      current_js: seed,
      stream:     queue,
      push:       push,
      notify:     notify,
      lookahead:  lookahead,
      deadline:   System.monotonic_time(:microsecond) + @tick_us,
    }

    schedule_tick(state.deadline)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    case pull_and_execute(state) do
      {:continue, state} ->
        next = state.deadline + @tick_us
        schedule_tick(next)
        {:noreply, %{state | deadline: next, tick_count: state.tick_count + 1}}

      {:done, state} ->
        notify(state, {:path_done, self(), stats_from_state(state)})
        {:stop, :normal, state}

      {:error, reason, state} ->
        notify(state, {:path_error, self(), reason})
        {:stop, {:error, reason}, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(:joint_state, _from, state) do
    {:reply, state.current_js, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, stats_from_state(state), state}
  end

  # ---------------------------------------------------------------------------
  # Core tick logic
  # ---------------------------------------------------------------------------

  defp pull_and_execute(state) do
    # Accumulate frame-consumption budget gated by the lookahead ceiling.
    # At ceiling=1.0 (clear path) we consume one frame per tick as before.
    # At ceiling<1.0 (near singularity) we slow down: budget accrues slowly
    # and frames are withheld until enough credit has built up.  Joint
    # velocities are also multiplied by la_ceiling so the TCP slows smoothly
    # before the singular region rather than reacting after the fact.
    la_ceiling = lookahead_ceiling(state)
    new_budget  = state.budget + la_ceiling

    if new_budget < 1.0 do
      # Not enough budget yet — hold position, push zeros, accrue credit
      push_all(state, zeros(state.chain))
      state = %{state | budget: new_budget, pacing_events: state.pacing_events + 1}
      {:continue, state}
    else
      # Consume one frame; carry fractional remainder forward
      consumed_budget = new_budget - 1.0

      case :queue.out(state.stream) do
        {:empty, _} ->
          {:done, state}

        {{:value, frame}, rest} ->
          prev = state.prev_frame || FK.solve(state.chain, state.current_js)
          tcp_vel = differentiate(frame, prev)

          case IK.solve_velocity(state.chain, state.current_js, tcp_vel) do
            # The report is dropped here rather than acted on: this executor
            # predates it and does its own scaling below. When path execution
            # moves onto the stream's machinery it inherits the residual and the
            # damping ladder with it.
            {:ok, vel_js, _report} ->
              {scaled, scale} = scale_to_limits(state.chain, vel_js.velocities)

              # Apply lookahead ceiling — already factored into budget gate above,
              # also applied to velocity magnitude for smooth deceleration
              final = Enum.map(scaled, &(&1 * la_ceiling))

              push_all(state, final)
              next_js = integrate(state.current_js, final)

              # Feed the frame `window` ticks ahead into lookahead
              lookahead_push(state, frame, rest)

              # Update lookahead seed to track current configuration
              if state.lookahead do
                ExMove.Lookahead.update_seed(state.lookahead, next_js)
              end

              state = %{state |
                stream:      rest,
                current_js:  next_js,
                prev_frame:  frame,
                error_count: 0,
                budget:      consumed_budget,
                min_scale:   min(state.min_scale, scale * la_ceiling)
              }
              {:continue, state}

            {:error, :singular} ->
              errors = state.error_count + 1
              if errors >= @max_consecutive_errors do
                {:error, {:singular, [at_tick: state.tick_count]},
                 %{state | stream: rest}}
              else
                # Hold — zero velocities, advance stream, count error
                push_all(state, zeros(state.chain))
                state = %{state | stream: rest, prev_frame: frame,
                                  error_count: errors, budget: consumed_budget}
                {:continue, state}
              end
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lookahead helpers
  # ---------------------------------------------------------------------------

  # Non-blocking ceiling read — returns 1.0 if no lookahead or result pending
  defp lookahead_ceiling(%{lookahead: nil}), do: 1.0
  defp lookahead_ceiling(%{lookahead: la, tick_count: idx}) do
    ExMove.Lookahead.ceiling(la, idx)
  end

  # Push the frame `window` ticks ahead into the async analyser
  defp lookahead_push(%{lookahead: nil}, _frame, _rest), do: :ok
  defp lookahead_push(%{lookahead: la, tick_count: idx}, _frame, rest) do
    window = 50
    future_idx = idx + window
    # Drop (window-1) elements then peek the head — O(window) but window is small/constant
    future_frame = drop_n(rest, window - 1)
    case future_frame do
      nil   -> :ok
      frame -> ExMove.Lookahead.push(la, future_idx, frame)
    end
  end

  defp drop_n(queue, 0) do
    case :queue.out(queue) do
      {:empty, _}            -> nil
      {{:value, frame}, _}   -> frame
    end
  end
  defp drop_n(queue, n) do
    case :queue.out(queue) do
      {:empty, _}        -> nil
      {{:value, _}, rest} -> drop_n(rest, n - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Math helpers
  # ---------------------------------------------------------------------------

  # v = (target - prev) / dt  at 1kHz → multiply by 1000
  defp differentiate(target, prev) do
    inv_dt = 1_000.0
    [
      (target.x  - prev.x)  * inv_dt,
      (target.y  - prev.y)  * inv_dt,
      (target.z  - prev.z)  * inv_dt,
      (target.rx - prev.rx) * inv_dt,
      (target.ry - prev.ry) * inv_dt,
      (target.rz - prev.rz) * inv_dt,
    ]
  end

  # Integrate: p[t+1] = p[t] + v * dt
  defp integrate(%JointState{positions: pos} = js, velocities) do
    dt = @tick_ms / 1_000.0
    new_pos = Enum.zip_with(pos, velocities, fn p, v -> p + v * dt end)
    %{js | positions: new_pos, velocities: velocities}
  end

  defp push_all(state, velocities) do
    state.chain.axis_ids
    |> Enum.zip(velocities)
    |> Enum.each(fn {id, vel} -> state.push.(id, vel) end)
  end

  # Scale the whole velocity vector down if any joint exceeds its max_vel.
  # Using a uniform scale preserves path shape — the move just runs slower.
  # Returns velocities unchanged if all joints are within limits or have no limit.
  defp scale_to_limits(chain, velocities) do
    scale = chain.joints
      |> Enum.zip(velocities)
      |> Enum.reduce(1.0, fn {joint, vel}, min_scale ->
        case joint.max_vel do
          nil     -> min_scale
          max_vel ->
            abs_vel = abs(vel)
            if abs_vel > max_vel do
              min(min_scale, max_vel / abs_vel)
            else
              min_scale
            end
        end
      end)

    if scale < 1.0 do
      {Enum.map(velocities, &(&1 * scale)), scale}
    else
      {velocities, 1.0}
    end
  end

  defp zeros(chain), do: List.duplicate(0.0, length(chain.axis_ids))

  # ---------------------------------------------------------------------------
  # Scheduler
  # ---------------------------------------------------------------------------

  # Deadline-based scheduler: sleep to an absolute time, not relative to now.
  # Prevents tick drift accumulating over thousands of iterations.
  # When already behind deadline (delay <= 0), send immediately via self() to
  # avoid the 1ms minimum floor of Process.send_after, allowing catch-up.
  defp schedule_tick(deadline_us) do
    now      = System.monotonic_time(:microsecond)
    delay_us = deadline_us - now
    if delay_us <= 1_000 do
      # Behind or within 1ms — fire immediately, no sleep
      send(self(), :tick)
    else
      Process.send_after(self(), :tick, div(delay_us, 1000))
    end
  end

  defp notify(%{notify: nil}, _msg), do: :ok
  defp notify(%{notify: pid}, msg),  do: send(pid, msg)

  defp stats_from_state(state) do
    %{tick_count:    state.tick_count,
      error_count:   state.error_count,
      min_scale:     state.min_scale,
      pacing_events: state.pacing_events,
      budget:        state.budget}
  end
end
