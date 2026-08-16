defmodule ExMove.IK.NIF do
  @moduledoc false
  use Rustler,
    otp_app: :exmove,
    crate: :exmove_ik

  # `tool` is {x, y, z, roll, pitch, yaw} — the TCP offset from the last joint.
  # Both functions take it, and take the same one, because a solver and a
  # Jacobian that disagree about which point they are talking about produce an
  # answer that is self-consistent and wrong.
  def solve(_joints, _seed, _target_pos, _target_rpy, _tool,
            _max_iterations, _tolerance, _damping) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def jacobian(_joints, _thetas, _tool) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
