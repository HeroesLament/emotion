defmodule ExMove.IK do
  @moduledoc """
  Inverse kinematics via damped least squares Jacobian iteration.

  Pure function interface — no process, no side effects.

      {:ok, chain} = ExMove.URDF.load(:arctos)
      seed   = ExMove.JointState.zero(6)
      target = %ExMove.Frame{x: 0.1, y: 0.0, z: 0.4}

      case ExMove.IK.solve(chain, target, seed) do
        {:ok,           %ExMove.JointState{} = js, w, k} -> js  # w=manipulability, k=condition
        {:near_singular, %ExMove.JointState{} = js, w, k} -> js  # near-singular (w low, k high)
        {:constrained,   %ExMove.JointState{} = js, w, k} -> js  # joint limits active, best effort
        {:error, reason}                                  -> handle_error(reason)
      end

  Options:
    :max_iterations — default 500
    :tolerance      — position+orientation error norm, default 1.0e-4
    :damping        — base DLS damping factor λ (auto-increases near singularities)
  """

  alias ExMove.{Chain, Frame, JointState}
  alias ExMove.IK.NIF

  @default_max_iter  500
  @default_tolerance 1.0e-4
  @default_damping   0.05

  @doc "Solve IK for a target Frame given a seed JointState"
  def solve(%Chain{} = chain, %Frame{} = target, %JointState{} = seed, opts \\ []) do
    with :ok <- check_workspace(chain, target) do
      max_iter  = Keyword.get(opts, :max_iterations, @default_max_iter)
      tolerance = Keyword.get(opts, :tolerance,      @default_tolerance)
      damping   = Keyword.get(opts, :damping,        @default_damping)

      nif_joints = Enum.map(chain.joints, &to_nif_joint/1)
      target_pos = {target.x,  target.y,  target.z}
      target_rpy = {target.rx, target.ry, target.rz}

      case NIF.solve(nif_joints, seed.positions, target_pos, target_rpy,
                     max_iter, tolerance, damping) do
        {:ok, positions, w, k}            -> {:ok,           JointState.from_positions(positions), w, k}
        {:near_singular, positions, w, k} -> {:near_singular, JointState.from_positions(positions), w, k}
        {:constrained, positions, w, k}   -> {:constrained,   JointState.from_positions(positions), w, k}
        {:no_solution, reason}         -> {:error, {:no_solution, reason}}
      end
    end
  end

  @doc """
  Solve IK with multiple random restarts if the first attempt fails.

  Tries the provided seed first, then up to `restarts` random seeds drawn
  from the joint ranges of the chain. Stops as soon as any attempt returns
  `:ok` or `:near_singular`. Returns the best result seen across all attempts
  (lowest TCP error) if all fail.

  Restart policy lives here in Elixir — the NIF stays a pure function.

      ExMove.IK.solve_with_restarts(chain, target, seed, restarts: 5)
  """
  def solve_with_restarts(%Chain{} = chain, %Frame{} = target, %JointState{} = seed, opts \\ []) do
    restarts = Keyword.get(opts, :restarts, 5)

    seeds = [seed | random_seeds(chain, restarts)]

    Enum.reduce_while(seeds, {:error, {:no_solution, "no seeds tried"}}, fn s, best ->
      case solve(chain, target, s, opts) do
        {:ok, _, _, _} = result            -> {:halt, result}
        {:near_singular, _, _, _} = result -> {:halt, result}
        {:constrained, _, _, _} = result   -> {:halt, result}
        {:error, _} = result               -> {:cont, better(result, best)}
      end
    end)
  end

  @doc """
  Compute the 6×n geometric Jacobian for the chain at the given joint state.

  Returns `%{linear: [[fx, fy, fz], ...], angular: [[ax, ay, az], ...]}` —
  one 3-vector per joint for each of the linear and angular partitions.

  Used by the velocity IK and feedrate controller to map TCP velocity → joint
  velocities: `dq = J⁻¹ · v_tcp`.

      J = ExMove.IK.jacobian(chain, js)
      # J.linear[i]  — how joint i contributes to TCP linear velocity
      # J.angular[i] — how joint i contributes to TCP angular velocity
  """
  def jacobian(%Chain{} = chain, %JointState{positions: positions}) do
    nif_joints = Enum.map(chain.joints, &to_nif_joint/1)
    flat = NIF.jacobian(nif_joints, positions)
    n = length(chain.joints)
    # flat is row-major 6×n — rows 0-2 linear, rows 3-5 angular
    linear  = for i <- 0..2, do: for j <- 0..(n-1), do: Enum.at(flat, i*n + j)
    angular = for i <- 3..5, do: for j <- 0..(n-1), do: Enum.at(flat, i*n + j)
    %{linear: linear, angular: angular, flat: flat, n: n}
  end

  @doc """
  Velocity IK — given current joint state and desired TCP velocity vector,
  return the joint velocities that produce it.

  `tcp_vel` is a 6-vector `[vx, vy, vz, wx, wy, wz]` in m/s and rad/s.
  Returns `{:ok, %JointState{velocities: [...]}}` or `{:error, :singular}`.

  This is the hot path for feedrate-maintaining Cartesian motion.
  Much cheaper than the iterative position solver — one matrix multiply.
  """
  def solve_velocity(%Chain{} = chain, %JointState{} = js, tcp_vel)
      when length(tcp_vel) == 6 do
    %{flat: jac, n: n} = jacobian(chain, js)
    case dls_velocity(jac, tcp_vel, n) do
      {:ok, dq} ->
        {:ok, %JointState{js | velocities: dq}}
      :singular ->
        {:error, :singular}
    end
  end

  # DLS pseudoinverse for velocity IK: dq = Jᵀ(JJᵀ + λ²I)⁻¹ v
  # Uses a very small λ — just enough to prevent divide-by-zero at singularities.
  # Caller should check κ before calling if singularity handling matters.
  @velocity_lambda 1.0e-6
  defp dls_velocity(jac, v, n) do
    lambda2 = @velocity_lambda * @velocity_lambda
    # JJᵀ (6×6) + λ²I
    a = for i <- 0..5 do
      for j <- 0..5 do
        s = Enum.reduce(0..(n-1), 0.0, fn k, acc ->
          acc + Enum.at(jac, i*n+k) * Enum.at(jac, j*n+k)
        end)
        if i == j, do: s + lambda2, else: s
      end
    end
    # Jᵀ · (A⁻¹ · v) — Gaussian elimination on 6×6 augmented [A|v]
    case gaussian_solve(a, v) do
      {:ok, av} ->
        dq = for k <- 0..(n-1) do
          Enum.reduce(0..5, 0.0, fn i, acc ->
            acc + Enum.at(jac, i*n+k) * Enum.at(av, i)
          end)
        end
        {:ok, dq}
      :singular ->
        :singular
    end
  end

  defp gaussian_solve(a, b) do
    n = 6
    # Build augmented matrix [A|b]
    aug = Enum.map(0..(n-1), fn i -> Enum.at(a, i) ++ [Enum.at(b, i)] end)
    case gauss_elim(aug, n) do
      {:ok, aug} -> {:ok, back_sub(aug, n)}
      :singular  -> :singular
    end
  end

  defp gauss_elim(aug, n) do
    Enum.reduce_while(0..(n-1), {:ok, aug}, fn col, {:ok, aug} ->
      # Find row with largest absolute value in this column (partial pivot)
      {max_row, max_val} = Enum.drop(aug, col)
        |> Enum.with_index(col)
        |> Enum.max_by(fn {row, _i} -> abs(Enum.at(row, col)) end)
        |> then(fn {row, i} -> {i, abs(Enum.at(row, col))} end)

      if max_val < 1.0e-14 do
        {:halt, :singular}
      else
        aug   = swap_rows(aug, col, max_row)
        pivot_row = Enum.at(aug, col)
        pivot = Enum.at(pivot_row, col)
        aug   = Enum.with_index(aug) |> Enum.map(fn {row, i} ->
          if i > col do
            f = Enum.at(row, col) / pivot
            Enum.zip(row, pivot_row) |> Enum.map(fn {rv, pv} -> rv - f * pv end)
          else
            row
          end
        end)
        {:cont, {:ok, aug}}
      end
    end)
  end

  defp back_sub(aug, n) do
    # Solve from last row upward, storing results in a map keyed by index
    Enum.reduce((n-1)..0//-1, %{}, fn i, solved ->
      row = Enum.at(aug, i)
      s = Enum.reduce((i+1)..(n-1)//1, 0.0, fn j, acc ->
        acc + Enum.at(row, j) * Map.fetch!(solved, j)
      end)
      d = Enum.at(row, i)
      xi = if abs(d) < 1.0e-14, do: 0.0, else: (Enum.at(row, n) - s) / d
      Map.put(solved, i, xi)
    end)
    |> then(fn m -> Enum.map(0..(n-1), &Map.fetch!(m, &1)) end)
  end

  defp swap_rows(list, i, j) when i == j, do: list
  defp swap_rows(list, i, j) do
    ri = Enum.at(list, i)
    rj = Enum.at(list, j)
    list |> List.replace_at(i, rj) |> List.replace_at(j, ri)
  end


  @doc """
  Maximum reach of the chain — sum of all link origin magnitudes.
  This is a conservative upper bound; actual reachable workspace is smaller.
  """
  def max_reach(%Chain{joints: joints}) do
    Enum.reduce(joints, 0.0, fn joint, acc ->
      {ox, oy, oz} = joint.origin
      acc + :math.sqrt(ox*ox + oy*oy + oz*oz)
    end)
  end

  # --- Private --------------------------------------------------------------

  # Fast workspace pre-check — reject targets that are geometrically impossible
  # before spending any iterations on them.
  defp check_workspace(chain, target) do
    reach = max_reach(chain)

    # Distance from base origin to target position
    dist = :math.sqrt(target.x * target.x +
                      target.y * target.y +
                      target.z * target.z)

    if dist > reach do
      {:error, {:out_of_reach,
        target_dist: Float.round(dist, 4),
        max_reach:   Float.round(reach, 4)}}
    else
      :ok
    end
  end

  # Generate n random seeds drawn uniformly from each joint's limit range.
  # Continuous joints (no limit) use [-π, π].
  defp random_seeds(%Chain{joints: joints}, n) do
    dof = length(joints)
    Enum.map(1..n, fn _ ->
      positions = Enum.map(joints, fn joint ->
        {lo, hi} = case joint.limit do
          {lo, hi} -> {lo, hi}
          nil      -> {-:math.pi(), :math.pi()}
        end
        lo + :rand.uniform() * (hi - lo)
      end)
      JointState.from_positions(positions)
    end)
  end

  # Pick the better of two results — success > constrained > error.
  # Used to track best-effort across restarts.
  defp better({:ok, _, _, _} = a,            _),                          do: a
  defp better(_,                              {:ok, _, _, _} = b),         do: b
  defp better({:near_singular, _, _, _} = a, _),                          do: a
  defp better(_,                              {:near_singular, _, _, _} = b), do: b
  defp better({:constrained, _, _, _} = a,   {:error, _}),                do: a
  defp better(_,                              b),                          do: b

  defp to_nif_joint(%ExMove.Joint{
    origin: {ox, oy, oz},
    rpy:    {roll, pitch, yaw},
    axis:   {ax, ay, az},
    limit:  limit
  }) do
    {lo, hi} = case limit do
      {lo, hi} -> {lo, hi}
      nil      -> {1.0, -1.0}  # lo > hi = continuous
    end
    %ExMove.IK.Joint{
      origin_x: ox, origin_y: oy, origin_z: oz,
      roll: roll, pitch: pitch, yaw: yaw,
      axis_x: ax, axis_y: ay, axis_z: az,
      limit_lo: lo, limit_hi: hi,
    }
  end
end
