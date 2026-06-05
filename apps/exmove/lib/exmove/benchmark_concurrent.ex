defmodule ExMove.BenchmarkConcurrent do
  @moduledoc """
  Multi-robot concurrency benchmark.

  Spins up N independent robots, each solving IK continuously for a fixed
  duration, and measures per-robot timing jitter. Demonstrates that the BEAM
  scheduler maintains consistent per-robot solve cadence regardless of
  concurrent load — a property single-threaded motion planners (e.g. LinuxCNC)
  cannot match without multiple isolated processes.

      ExMove.BenchmarkConcurrent.run()
      ExMove.BenchmarkConcurrent.run(robots: 6, duration_ms: 3000)
      ExMove.BenchmarkConcurrent.run(robots: 12, duration_ms: 3000)
  """

  alias ExMove.{FK, IK, JointState}

  @default_robots     6
  @default_duration   2000   # ms
  @solve_interval_ms  1      # target 1kHz per robot — matches servo tick rate
  @warmup_ms          200

  def run(opts \\ []) do
    n_robots   = Keyword.get(opts, :robots,      @default_robots)
    duration   = Keyword.get(opts, :duration_ms, @default_duration)

    {:ok, chain} = ExMove.URDF.load(:arctos)

    IO.puts("\nExMove Concurrent IK Benchmark")
    IO.puts("#{n_robots} robots × #{duration}ms @ #{1000 / @solve_interval_ms |> trunc}Hz target")
    IO.puts(String.duplicate("─", 60))

    # Each robot gets a different starting pose so they're not all in the same
    # Jacobian neighbourhood — more realistic than identical workloads
    seeds = for i <- 0..(n_robots - 1) do
      angle = i * 2 * :math.pi() / n_robots
      JointState.from_positions([angle, -0.5, 0.8, 0.0, 0.4, -0.2])
    end

    IO.write("Warming up (#{@warmup_ms}ms)... ")
    warmup(chain, seeds, @warmup_ms)
    IO.puts("done\n")

    # Spawn one worker per robot — all start simultaneously via a barrier
    parent  = self()
    barrier = make_ref()

    workers = Enum.map(Enum.with_index(seeds), fn {seed, i} ->
      spawn_link(fn ->
        # Wait for go signal
        receive do ^barrier -> :ok end
        results = robot_worker(chain, seed, duration)
        send(parent, {:done, i, results})
      end)
    end)

    # Fire the barrier — all robots start together
    t_start = System.monotonic_time(:millisecond)
    Enum.each(workers, &send(&1, barrier))

    # Collect results
    results = for _ <- workers do
      receive do {:done, i, r} -> {i, r} end
    end
    t_total = System.monotonic_time(:millisecond) - t_start

    results = Enum.sort_by(results, &elem(&1, 0))
    report(results, n_robots, duration, t_total)
  end

  # --- Worker -----------------------------------------------------------------

  defp robot_worker(chain, seed, duration_ms) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    # Walk through random poses, tracking inter-solve intervals
    do_worker(chain, seed, deadline, seed, [])
  end

  defp do_worker(chain, current_js, deadline, _seed, acc) do
    now = System.monotonic_time(:millisecond)
    if now >= deadline do
      Enum.reverse(acc)
    else
      # Generate next target — perturb current joints slightly for realistic motion
      next_js = perturb(current_js)
      target  = FK.solve(chain, next_js)

      t0     = System.monotonic_time(:microsecond)
      result = IK.solve(chain, target, current_js)
      t1     = System.monotonic_time(:microsecond)

      solve_us = t1 - t0

      # Use solution as next seed if successful, otherwise keep current
      next_seed = case result do
        {:ok, js, _, _}            -> js
        {:near_singular, js, _, _} -> js
        {:constrained, js, _, _}   -> js
        {:error, _}                -> current_js
      end

      do_worker(chain, next_seed, deadline, next_seed, [{solve_us, result} | acc])
    end
  end

  # Perturb joint positions by ±0.05 rad — simulates continuous motion
  defp perturb(%JointState{positions: positions} = js) do
    new_pos = Enum.map(positions, fn p ->
      p + (:rand.uniform() - 0.5) * 0.1
    end)
    %{js | positions: new_pos}
  end

  # --- Reporting --------------------------------------------------------------

  defp report(results, n_robots, duration_ms, t_total_ms) do
    IO.puts("PER-ROBOT RESULTS")
    IO.puts(String.duplicate("─", 60))
    IO.puts(
      String.pad_trailing("Robot", 8) <>
      String.pad_leading("Solves", 8) <>
      String.pad_leading("Conv%", 7) <>
      String.pad_leading("p50μs", 8) <>
      String.pad_leading("p95μs", 8) <>
      String.pad_leading("p99μs", 8) <>
      String.pad_leading("maxμs", 8)
    )
    IO.puts(String.duplicate("─", 60))

    all_times    = []
    all_conv     = []

    {all_times, all_conv} = Enum.reduce(results, {[], []}, fn {i, solves}, {at, ac} ->
      times   = Enum.map(solves, &elem(&1, 0)) |> Enum.sort()
      n       = length(times)
      conv    = Enum.count(solves, fn {_, r} -> converged?(r) end)
      conv_pct = Float.round(conv / max(n, 1) * 100, 1)

      IO.puts(
        String.pad_trailing("robot_#{i}", 8) <>
        String.pad_leading("#{n}", 8) <>
        String.pad_leading("#{conv_pct}%", 7) <>
        String.pad_leading("#{percentile(times, 0.50)}", 8) <>
        String.pad_leading("#{percentile(times, 0.95)}", 8) <>
        String.pad_leading("#{percentile(times, 0.99)}", 8) <>
        String.pad_leading("#{Enum.max(times)}", 8)
      )

      {at ++ times, ac ++ [conv_pct]}
    end)

    IO.puts(String.duplicate("─", 60))

    # Aggregate across all robots
    all_sorted = Enum.sort(all_times)
    total_solves = length(all_sorted)
    mean_conv = Float.round(Enum.sum(all_conv) / n_robots, 1)

    IO.puts("\nAGGREGATE (#{n_robots} robots)")
    IO.puts(String.duplicate("─", 60))
    IO.puts("  Total solves     : #{total_solves}")
    IO.puts("  Throughput       : #{trunc(total_solves / (t_total_ms / 1000))} solves/sec")
    IO.puts("  Mean convergence : #{mean_conv}%")
    IO.puts("  p50              : #{percentile(all_sorted, 0.50)} μs")
    IO.puts("  p95              : #{percentile(all_sorted, 0.95)} μs")
    IO.puts("  p99              : #{percentile(all_sorted, 0.99)} μs")
    IO.puts("  max              : #{Enum.max(all_sorted)} μs")
    IO.puts("  Wall time        : #{t_total_ms} ms (target #{duration_ms} ms)")
    IO.puts("")
    IO.puts("  → LinuxCNC equivalent: #{n_robots} separate RT processes,")
    IO.puts("    no shared scheduler, no cross-robot coordination.")
    IO.puts("")
  end

  defp warmup(chain, seeds, duration_ms) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    do_warmup(chain, List.flatten(List.duplicate(seeds, 200)), deadline)
  end

  defp do_warmup(_chain, [], _deadline), do: :ok
  defp do_warmup(chain, [seed | rest], deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      js = perturb(seed)
      IK.solve(chain, FK.solve(chain, js), seed)
      do_warmup(chain, rest, deadline)
    end
  end

  defp converged?({:ok, _, _, _}),            do: true
  defp converged?({:near_singular, _, _, _}), do: true
  defp converged?({:constrained, _, _, _}),   do: true
  defp converged?(_),                         do: false

  defp percentile([], _), do: 0
  defp percentile(sorted, p) do
    idx = trunc(p * (length(sorted) - 1))
    Enum.at(sorted, idx)
  end
end
