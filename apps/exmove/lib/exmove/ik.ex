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

      case NIF.solve(nif_joints, seed.positions, target_pos, target_rpy, to_nif_tool(chain.tool),
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
  `:ok` or `:near_singular`. If every attempt fails, returns the first solver
  failure rather than a summary: the NIF reports a reason and no residual, so
  there is nothing to rank failures by.

  Restart policy lives here in Elixir — the NIF stays a pure function.

      ExMove.IK.solve_with_restarts(chain, target, seed, restarts: 5)
  """
  def solve_with_restarts(%Chain{} = chain, %Frame{} = target, %JointState{} = seed, opts \\ []) do
    restarts = Keyword.get(opts, :restarts, 5)

    seeds = [seed | random_seeds(chain, restarts)]

    # `nil` rather than a placeholder error as the accumulator, so "nothing has
    # failed yet" and "something failed" are distinguishable. The previous
    # version seeded the fold with {:no_solution, "no seeds tried"} and compared
    # against it with a better/2 that could never prefer the real failure — so a
    # run that tried six seeds and failed six times reported "no seeds tried".
    seeds
    |> Enum.reduce_while(nil, fn s, first_failure ->
      case solve(chain, target, s, opts) do
        {:ok, _, _, _} = result            -> {:halt, result}
        {:near_singular, _, _, _} = result -> {:halt, result}
        {:constrained, _, _, _} = result   -> {:halt, result}
        {:error, _} = result               -> {:cont, first_failure || result}
      end
    end)
    |> case do
      nil    -> {:error, {:no_solution, "no seeds tried"}}
      result -> result
    end
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
    flat = NIF.jacobian(nif_joints, positions, to_nif_tool(chain.tool))
    n = length(chain.joints)
    # flat is row-major 6×n — rows 0-2 linear, rows 3-5 angular
    linear  = for i <- 0..2, do: (for j <- 0..(n - 1), do: Enum.at(flat, i * n + j))
    angular = for i <- 3..5, do: (for j <- 0..(n - 1), do: Enum.at(flat, i * n + j))
    %{linear: linear, angular: angular, flat: flat, n: n}
  end

  # Damping for velocity IK.
  #
  # Not a guard, and deliberately not tunable. It is the smallest number that
  # keeps the 6×6 elimination well posed at an exact singularity, where JJᵀ is
  # rank deficient and would otherwise divide by zero.
  #
  # A larger λ is the textbook answer to unbounded joint rates near a
  # singularity, and it is the wrong one here. Damping bounds the rates by
  # bending the answer away from what was asked for — measured on this arm,
  # damping a 1.19 rad/s solve down to 0.5 rad/s costs half the commanded twist.
  # Scaling the whole joint vector meets the same ceiling with the direction
  # exactly preserved and the speed reduced instead. Speed is the cheaper thing
  # to lose, and it is the one an operator can see. See `ExMove.CartesianStream`,
  # which owns that policy because it is policy.
  @velocity_lambda 1.0e-6

  @doc """
  Velocity IK — given current joint state and a desired TCP velocity, return the
  joint velocities that produce it.

  `tcp_vel` is a 6-vector `[vx, vy, vz, wx, wy, wz]` in m/s and rad/s. Returns
  `{:ok, %JointState{velocities: [...]}, report}`, or `{:error, :singular}` when
  even the damped system cannot be solved.

  This is pure kinematics and applies no policy. It does not limit the rates it
  returns, and near a singularity they can be very large — that is the honest
  answer to the question asked, and what to do about it belongs to whoever owns
  the drives.

  ## The report

    * `:manipulability` — `sqrt(det(J·Jᵀ))`. Zero at a singularity.
    * `:residual` — `|J·dq − v| / |v|`, the fraction of the commanded twist the
      joints fail to deliver. Zero wherever the command is achievable at all,
      which is almost everywhere; it rises only where the arm genuinely cannot go
      in the direction asked.
    * `:peak_rate` — the largest joint rate in the answer, rad/s.

  ## Why the residual is the interesting number and not the manipulability

  Measured on a six-axis arm, approaching full extension drops `w` and sends the
  joint rates for a 0.05 m/s translation from 0.2 rad/s to 128 rad/s. Approaching
  the wrist singularity drops `w` exactly as far and does not move those rates at
  all: the freedom being lost is a wrist rotation, and a translation never needed
  it.

  So `w` cannot tell "this arm is stuck" from "this arm is in an awkward pose and
  perfectly able to do what you asked". It is a property of the pose. The
  residual is a property of the pose *and the command*, which is the pair the
  question is actually about. `w` is still reported — it is the standard number
  and it is what a viewport shades reachability with — but nothing keys off it.
  """
  def solve_velocity(%Chain{} = chain, %JointState{} = js, tcp_vel, _opts \\ [])
      when length(tcp_vel) == 6 do
    %{flat: jac, n: n} = jacobian(chain, js)

    a = jjt(jac, n)

    case dls_velocity(a, jac, tcp_vel, n, @velocity_lambda) do
      {:ok, dq} ->
        report = %{
          manipulability: :math.sqrt(abs(determinant(a))),
          residual: residual(jac, dq, tcp_vel, n),
          peak_rate: peak(dq)
        }

        {:ok, %JointState{js | velocities: dq}, report}

      :singular ->
        {:error, :singular}
    end
  end

  @doc """
  `sqrt(det(J·Jt))` at the given pose — zero at a singularity, larger where the
  arm has more room to manoeuvre.

  Available on its own because it is a fact about a pose and needs no command:
  a viewport shading reachability wants it for an arm that is standing still,
  which is exactly when somebody is deciding where to send it.

  It is not what a controller should decide on. See `solve_velocity/4`.
  """
  def manipulability(%Chain{} = chain, %JointState{} = js) do
    %{flat: jac, n: n} = jacobian(chain, js)
    :math.sqrt(abs(determinant(jjt(jac, n))))
  end

  defp peak([]), do: 0.0
  defp peak(dq), do: dq |> Enum.map(&abs/1) |> Enum.max()

  # How much of the commanded twist the joints do not deliver, as a fraction.
  #
  # This is the number a refusal belongs on. Unlike the manipulability it knows
  # what was asked for, so it stays at zero through a singularity whose lost
  # degree of freedom the command never needed.
  defp residual(jac, dq, v, n) do
    norm_v = v |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    if norm_v < 1.0e-12 do
      0.0
    else
      achieved =
        for i <- 0..5 do
          Enum.reduce(0..(n - 1), 0.0, fn k, acc ->
            acc + Enum.at(jac, i * n + k) * Enum.at(dq, k)
          end)
        end

      Enum.zip(achieved, v)
      |> Enum.map(fn {a, b} -> (a - b) * (a - b) end)
      |> Enum.sum()
      |> :math.sqrt()
      |> Kernel./(norm_v)
    end
  end

  # J·Jᵀ, 6×6. Built once and used for both the determinant and the solve.
  defp jjt(jac, n) do
    for i <- 0..5 do
      for j <- 0..5 do
        Enum.reduce(0..(n - 1), 0.0, fn k, acc ->
          acc + Enum.at(jac, i * n + k) * Enum.at(jac, j * n + k)
        end)
      end
    end
  end

  # Product of the pivots, with the sign of the row swaps. Zero at a singularity,
  # which is the answer rather than a failure.
  defp determinant(a) do
    Enum.reduce_while(0..5, {a, 1.0}, fn col, {rows, acc} ->
      {pivot_row, magnitude} =
        rows
        |> Enum.drop(col)
        |> Enum.with_index(col)
        |> Enum.max_by(fn {row, _i} -> abs(Enum.at(row, col)) end)
        |> then(fn {row, i} -> {i, abs(Enum.at(row, col))} end)

      if magnitude < 1.0e-15 do
        {:halt, {rows, 0.0}}
      else
        sign = if pivot_row == col, do: 1.0, else: -1.0
        rows = swap_rows(rows, col, pivot_row)
        p = Enum.at(rows, col)
        pivot = Enum.at(p, col)

        rows =
          rows
          |> Enum.with_index()
          |> Enum.map(fn {row, i} ->
            if i > col do
              f = Enum.at(row, col) / pivot
              Enum.zip(row, p) |> Enum.map(fn {rv, pv} -> rv - f * pv end)
            else
              row
            end
          end)

        {:cont, {rows, acc * pivot * sign}}
      end
    end)
    |> elem(1)
  end

  # DLS pseudoinverse for velocity IK: dq = Jᵀ(JJᵀ + λ²I)⁻¹ v
  defp dls_velocity(a, jac, v, n, lambda) do
    lambda2 = lambda * lambda

    damped =
      a
      |> Enum.with_index()
      |> Enum.map(fn {row, i} -> List.update_at(row, i, &(&1 + lambda2)) end)

    case gaussian_solve(damped, v) do
      {:ok, av} ->
        dq =
          for k <- 0..(n - 1) do
            Enum.reduce(0..5, 0.0, fn i, acc ->
              acc + Enum.at(jac, i * n + k) * Enum.at(av, i)
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
  def max_reach(%Chain{joints: joints} = chain) do
    links =
      Enum.reduce(joints, 0.0, fn joint, acc ->
        {ox, oy, oz} = joint.origin
        acc + :math.sqrt(ox * ox + oy * oy + oz * oz)
      end)

    # Plus the tool, which is part of the reach whether or not anyone counted it.
    # This bound is used to reject targets before iterating; a bound that stops
    # short of the tool rejects points the arm can comfortably touch.
    links + tool_reach(chain.tool)
  end

  defp tool_reach(nil), do: 0.0
  defp tool_reach(%Frame{x: x, y: y, z: z}), do: :math.sqrt(x * x + y * y + z * z)

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

  # The Frame the Chain carries, flattened for the NIF boundary.
  defp to_nif_tool(nil), do: {0.0, 0.0, 0.0, 0.0, 0.0, 0.0}

  defp to_nif_tool(%Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}) do
    {x, y, z, rx, ry, rz}
  end

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
