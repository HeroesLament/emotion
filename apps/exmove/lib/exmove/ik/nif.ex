defmodule ExMove.IK.NIF do
  @moduledoc false
  use Rustler,
    otp_app: :exmove,
    crate: :exmove_ik

  def solve(_joints, _seed, _target_pos, _target_rpy,
            _max_iterations, _tolerance, _damping) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def jacobian(_joints, _thetas) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
