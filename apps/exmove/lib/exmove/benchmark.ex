defmodule ExMove.Benchmark do
  @moduledoc """
  IK solver performance benchmark.

  Generates random reachable poses, solves IK for each, and reports
  solve time distribution, convergence rate, and TCP accuracy.

      iex> ExMove.Benchmark.run()
      iex> ExMove.Benchmark.run(n: 2000, seed_offset: 42)
  """

  alias ExMove.{FK, IK, JointState}

  @default_n        1000
  @default_restarts 0
  @warmup           50

  # Conservative joint ranges — keeps TCP well within workspace
  @joint_ranges [
    {-2.5,  2.5},  # j1 base
    {-1.5,  1.5},  # j2 shoulder
    {-1.8,  1.8},  # j3 elbow
    {-2.5,  2.5},  # j4 wrist roll
    {-1.5,  1.5},  # j5 wrist pitch
    {-2.5,  2.5},  # j6 wrist yaw
  ]

  def run(opts \\ []) do
    n        = Keyword.get(opts, :n, @default_n)
    restarts = Keyword.get(opts, :restarts, @default_restarts)
    {:ok, chain} = ExMove.URDF.load(:arctos)
    seed = JointState.zero(6)

    label = if restarts > 0, do: " (#{restarts} restarts)", else: ""
    IO.puts("\nExMove IK Benchmark — #{n} random reachable poses#{label}")
    IO.puts(String.duplicate("─", 60))

    IO.write("Warming up (#{@warmup} solves)... ")
    warmup_poses(chain, seed, @warmup)
    IO.puts("done\n")

    poses   = random_joint_states(n)
    targets = Enum.map(poses, &FK.solve(chain, &1))

    IO.write("Solving... ")
    results = Enum.map(targets, fn target ->
      t0 = System.monotonic_time(:microsecond)
      result = if restarts > 0 do
        IK.solve_with_restarts(chain, target, seed, restarts: restarts)
      else
        IK.solve(chain, target, seed)
      end
      t1 = System.monotonic_time(:microsecond)
      {result, t1 - t0, target}
    end)
    IO.puts("done\n")

    report(results, n, chain)
  end

  # --- Reporting -------------------------------------------------------------

  defp report(results, n, chain) do
    # Partition by outcome
    {solved, failed} = Enum.split_with(results, fn
      {{:ok, _, _, _}, _, _}            -> true
      {{:near_singular, _, _, _}, _, _} -> true
      {{:constrained, _, _, _}, _, _}   -> true
      _                                  -> false
    end)

    n_ok          = count_tag(results, :ok)
    n_near_sing   = count_tag(results, :near_singular)
    n_constrained = count_tag(results, :constrained)
    n_failed      = length(failed)

    convergence_pct = Float.round(length(solved) / n * 100, 2)

    IO.puts("CONVERGENCE")
    IO.puts(String.duplicate("─", 60))
    IO.puts("  Total poses    : #{n}")
    IO.puts("  Converged      : #{length(solved)} (#{convergence_pct}%)")
    IO.puts("    :ok            #{n_ok}")
    IO.puts("    :near_singular #{n_near_sing}")
    IO.puts("    :constrained   #{n_constrained}")
    IO.puts("  Failed         : #{n_failed}")
    IO.puts("")

    if length(solved) > 0 do
      times = Enum.map(solved, fn {_, t, _} -> t end) |> Enum.sort()
      report_times(times)

      {w_vals, k_vals} = Enum.map(solved, fn
        {{:ok, _, w, k}, _, _}            -> {w, k}
        {{:near_singular, _, w, k}, _, _} -> {w, k}
        {{:constrained, _, w, k}, _, _}   -> {w, k}
      end) |> Enum.unzip()
      report_quality(w_vals, k_vals)

      tcp_errors = Enum.map(solved, fn
        {{:ok, js, _, _}, _, target}            -> tcp_error(chain, js, target)
        {{:near_singular, js, _, _}, _, target} -> tcp_error(chain, js, target)
        {{:constrained, js, _, _}, _, target}   -> tcp_error(chain, js, target)
      end)
      report_accuracy(tcp_errors)
    end
  end

  defp report_times(sorted_times) do
    n = length(sorted_times)
    IO.puts("SOLVE TIME (μs)")
    IO.puts(String.duplicate("─", 60))
    IO.puts("  min  : #{Enum.min(sorted_times)}")
    IO.puts("  p50  : #{percentile(sorted_times, 0.50)}")
    IO.puts("  p90  : #{percentile(sorted_times, 0.90)}")
    IO.puts("  p95  : #{percentile(sorted_times, 0.95)}")
    IO.puts("  p99  : #{percentile(sorted_times, 0.99)}")
    IO.puts("  max  : #{Enum.max(sorted_times)}")
    IO.puts("  mean : #{Float.round(Enum.sum(sorted_times) / n, 1)}")
    IO.puts("")
  end

  defp report_quality(w_vals, k_vals) do
    n = length(w_vals)
    w_sorted = Enum.sort(w_vals)
    k_sorted = Enum.sort(k_vals)
    IO.puts("MANIPULABILITY (w = sqrt(det(JJᵀ)))")
    IO.puts(String.duplicate("─", 60))
    IO.puts("  min    : #{fmt(Enum.min(w_vals))}")
    IO.puts("  median : #{fmt(percentile(w_sorted, 0.50))}")
    IO.puts("  mean   : #{fmt(Enum.sum(w_vals) / n)}")
    IO.puts("  max    : #{fmt(Enum.max(w_vals))}")
    IO.puts("")
    IO.puts("CONDITION NUMBER (κ = σ_max / σ_min)")
    IO.puts(String.duplicate("─", 60))
    IO.puts("  min    : #{Float.round(Enum.min(k_vals), 2)}")
    IO.puts("  median : #{Float.round(percentile(k_sorted, 0.50), 2)}")
    IO.puts("  mean   : #{Float.round(Enum.sum(k_vals) / n, 2)}")
    IO.puts("  max    : #{Float.round(Enum.max(k_vals), 2)}")
    IO.puts("")
  end

  defp report_accuracy(tcp_errors) do
    pos_errs = Enum.map(tcp_errors, &elem(&1, 0)) |> Enum.sort()
    rot_errs = Enum.map(tcp_errors, &elem(&1, 1)) |> Enum.sort()
    IO.puts("TCP ACCURACY")
    IO.puts(String.duplicate("─", 60))
    IO.puts("  Position error (mm):")
    IO.puts("    p50  : #{Float.round(percentile(pos_errs, 0.50) * 1000, 4)}")
    IO.puts("    p95  : #{Float.round(percentile(pos_errs, 0.95) * 1000, 4)}")
    IO.puts("    p99  : #{Float.round(percentile(pos_errs, 0.99) * 1000, 4)}")
    IO.puts("    max  : #{Float.round(Enum.max(pos_errs) * 1000, 4)}")
    IO.puts("  Orientation error (mrad):")
    IO.puts("    p50  : #{Float.round(percentile(rot_errs, 0.50) * 1000, 4)}")
    IO.puts("    p95  : #{Float.round(percentile(rot_errs, 0.95) * 1000, 4)}")
    IO.puts("    p99  : #{Float.round(percentile(rot_errs, 0.99) * 1000, 4)}")
    IO.puts("    max  : #{Float.round(Enum.max(rot_errs) * 1000, 4)}")
    IO.puts("")
  end

  # --- Helpers ---------------------------------------------------------------

  def random_joint_state do
    positions = Enum.map(@joint_ranges, fn {lo, hi} ->
      lo + :rand.uniform() * (hi - lo)
    end)
    JointState.from_positions(positions)
  end

  defp random_joint_states(n), do: Enum.map(1..n, fn _ -> random_joint_state() end)

  defp warmup_poses(chain, seed, n) do
    random_joint_states(n)
    |> Enum.each(fn js ->
      target = FK.solve(chain, js)
      IK.solve(chain, target, seed)
    end)
  end

  defp tcp_error(chain, js, target) do
    actual = FK.solve(chain, js)
    pos_err = :math.sqrt(
      (actual.x  - target.x)  ** 2 +
      (actual.y  - target.y)  ** 2 +
      (actual.z  - target.z)  ** 2
    )
    rot_err = :math.sqrt(
      angle_diff(actual.rx, target.rx) ** 2 +
      angle_diff(actual.ry, target.ry) ** 2 +
      angle_diff(actual.rz, target.rz) ** 2
    )
    {pos_err, rot_err}
  end

  defp angle_diff(a, b) do
    d = :math.fmod(a - b, 2 * :math.pi())
    cond do
      d >  :math.pi() -> d - 2 * :math.pi()
      d < -:math.pi() -> d + 2 * :math.pi()
      true            -> d
    end
  end

  defp percentile(sorted, p) do
    n = length(sorted)
    idx = trunc(p * (n - 1))
    Enum.at(sorted, idx)
  end

  defp count_tag(results, tag) do
    Enum.count(results, fn
      {{t, _, _, _}, _, _} -> t == tag
      _                    -> false
    end)
  end

  defp fmt(f), do: :io_lib.format("~.3e", [f]) |> IO.iodata_to_binary()
end
