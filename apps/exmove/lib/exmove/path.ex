defmodule ExMove.Path do
  @moduledoc """
  Cartesian path generators for motion planning.

  Produces lazy streams of `%ExMove.Frame{}` waypoints parameterised by
  arc-length. The consumer pulls one frame per servo tick and feeds it to
  `ExMove.IK.solve_velocity/3` to get joint velocities.

  Feedrate is in mm/s. Tick rate (hz) defaults to 1000 (1kHz).

      # G1 linear move at 50mm/s
      stream = ExMove.Path.linear(frame_a, frame_b, 50.0)

      # Consume at 1kHz
      Enum.each(stream, fn frame ->
        {:ok, vel_js} = ExMove.IK.solve_velocity(chain, current_js, ...)
        Exdrive.push(axis_id, ...)
      end)

  Orientation is interpolated via SLERP (quaternion) to avoid gimbal lock.
  """

  alias ExMove.Frame

  @default_hz 1000

  # --- Public API ------------------------------------------------------------

  @doc """
  Linear interpolation between two frames at the given feedrate (mm/s).

  Returns a `Stream` of `%Frame{}` from `a` to `b` inclusive.
  Each frame is one servo tick apart at `hz` (default 1000Hz).

  The stream length is `ceil(distance_mm / step_mm)` frames where
  `step_mm = feedrate_mm_s / hz`.
  """
  def linear(%Frame{} = a, %Frame{} = b, feedrate_mm_s, opts \\ []) do
    hz   = Keyword.get(opts, :hz, @default_hz)
    dist = position_distance(a, b)

    if dist < 1.0e-9 do
      # Zero-length move — single frame (orientation-only change handled below)
      Stream.once(fn -> b end)
    else
      step     = feedrate_mm_s / hz / 1000.0   # mm/s ÷ hz → m per tick
      n_steps  = ceil(dist / step)
      q_a      = rpy_to_quat(a.rx, a.ry, a.rz)
      q_b      = rpy_to_quat(b.rx, b.ry, b.rz)

      Stream.map(0..n_steps, fn i ->
        t = min(i / n_steps, 1.0)
        pos = lerp_position(a, b, t)
        {rx, ry, rz} = slerp_to_rpy(q_a, q_b, t)
        %Frame{x: pos.x, y: pos.y, z: pos.z, rx: rx, ry: ry, rz: rz}
      end)
    end
  end

  @doc """
  Arc interpolation in the XY plane (G2/G3 equivalent).

  `a` and `b` are start/end frames. `center` is `{cx, cy}` — the arc center
  in the plane of motion. `direction` is `:cw` or `:ccw`.

  Orientation interpolates linearly (SLERP) from `a` to `b` over the arc.
  Feedrate is in mm/s.
  """
  def arc(%Frame{} = a, %Frame{} = b, {cx, cy}, direction, feedrate_mm_s, opts \\ []) do
    hz    = Keyword.get(opts, :hz, @default_hz)
    step  = feedrate_mm_s / hz / 1000.0   # m per tick

    # Radius and angles from center
    ra    = :math.sqrt((a.x - cx) ** 2 + (a.y - cy) ** 2)
    ang_a = :math.atan2(a.y - cy, a.x - cx)
    ang_b = :math.atan2(b.y - cy, b.x - cx)

    # Sweep angle — sign depends on direction
    sweep = case direction do
      :ccw ->
        d = ang_b - ang_a
        if d < 0, do: d + 2 * :math.pi(), else: d
      :cw ->
        d = ang_a - ang_b
        if d < 0, do: d + 2 * :math.pi(), else: d
    end

    arc_len = ra * sweep
    n_steps = max(ceil(arc_len / step), 1)

    q_a = rpy_to_quat(a.rx, a.ry, a.rz)
    q_b = rpy_to_quat(b.rx, b.ry, b.rz)

    Stream.map(0..n_steps, fn i ->
      t     = min(i / n_steps, 1.0)
      angle = case direction do
        :ccw -> ang_a + t * sweep
        :cw  -> ang_a - t * sweep
      end
      x = cx + ra * :math.cos(angle)
      y = cy + ra * :math.sin(angle)
      z = a.z + t * (b.z - a.z)
      {rx, ry, rz} = slerp_to_rpy(q_a, q_b, t)
      %Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}
    end)
  end

  @doc """
  Total Cartesian distance between two frames (position only), in meters.
  """
  def distance(%Frame{} = a, %Frame{} = b), do: position_distance(a, b)

  @doc """
  Estimated number of ticks to traverse from `a` to `b` at `feedrate_mm_s`.
  """
  def tick_count(%Frame{} = a, %Frame{} = b, feedrate_mm_s, opts \\ []) do
    hz   = Keyword.get(opts, :hz, @default_hz)
    dist = position_distance(a, b)
    step = feedrate_mm_s / hz / 1000.0
    ceil(dist / step)
  end

  # --- Math helpers ----------------------------------------------------------

  defp position_distance(a, b) do
    :math.sqrt(
      (b.x - a.x) ** 2 +
      (b.y - a.y) ** 2 +
      (b.z - a.z) ** 2
    )
  end

  defp lerp_position(a, b, t) do
    %{x: a.x + t * (b.x - a.x),
      y: a.y + t * (b.y - a.y),
      z: a.z + t * (b.z - a.z)}
  end

  # --- Quaternion SLERP ------------------------------------------------------

  # Convert RPY (roll, pitch, yaw) to unit quaternion {w, x, y, z}
  defp rpy_to_quat(roll, pitch, yaw) do
    cr = :math.cos(roll  / 2)
    sr = :math.sin(roll  / 2)
    cp = :math.cos(pitch / 2)
    sp = :math.sin(pitch / 2)
    cy = :math.cos(yaw   / 2)
    sy = :math.sin(yaw   / 2)
    w = cr * cp * cy + sr * sp * sy
    x = sr * cp * cy - cr * sp * sy
    y = cr * sp * cy + sr * cp * sy
    z = cr * cp * sy - sr * sp * cy
    normalize_quat({w, x, y, z})
  end

  # Spherical linear interpolation between two quaternions
  defp slerp({w0, x0, y0, z0} = q0, {w1, x1, y1, z1}, t) do
    dot = w0*w1 + x0*x1 + y0*y1 + z0*z1

    # If dot < 0, negate one quaternion to take the short path
    {w1, x1, y1, z1, dot} = if dot < 0.0 do
      {-w1, -x1, -y1, -z1, -dot}
    else
      {w1, x1, y1, z1, dot}
    end

    # Clamp to valid range for acos
    dot = min(dot, 1.0)

    if dot > 0.9995 do
      # Nearly identical — linear interpolation to avoid div by zero
      normalize_quat({
        w0 + t * (w1 - w0),
        x0 + t * (x1 - x0),
        y0 + t * (y1 - y0),
        z0 + t * (z1 - z0)
      })
    else
      theta_0 = :math.acos(dot)
      theta   = theta_0 * t
      sin_t   = :math.sin(theta)
      sin_t0  = :math.sin(theta_0)
      s0 = :math.cos(theta) - dot * sin_t / sin_t0
      s1 = sin_t / sin_t0
      normalize_quat({
        s0 * w0 + s1 * w1,
        s0 * x0 + s1 * x1,
        s0 * y0 + s1 * y1,
        s0 * z0 + s1 * z1
      })
    end
  end

  defp slerp_to_rpy(q_a, q_b, t) do
    {w, x, y, z} = slerp(q_a, q_b, t)
    quat_to_rpy(w, x, y, z)
  end

  # Convert unit quaternion to RPY
  defp quat_to_rpy(w, x, y, z) do
    roll  = :math.atan2(2*(w*x + y*z), 1 - 2*(x*x + y*y))
    pitch = :math.asin(max(-1.0, min(1.0, 2*(w*y - z*x))))
    yaw   = :math.atan2(2*(w*z + x*y), 1 - 2*(y*y + z*z))
    {roll, pitch, yaw}
  end

  defp normalize_quat({w, x, y, z}) do
    n = :math.sqrt(w*w + x*x + y*y + z*z)
    if n < 1.0e-10, do: {1.0, 0.0, 0.0, 0.0}, else: {w/n, x/n, y/n, z/n}
  end
end
