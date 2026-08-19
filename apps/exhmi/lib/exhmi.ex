defmodule ExHMI do
  @moduledoc """
  ExHMI — Northbound gateway for the E-Motion motion controller.

  Exposes arm state and accepts motion commands from external clients
  via OPC UA (primary transport, port 4840).

  ## Quick start

  Add to your umbrella's root `mix.exs` apps list and configure:

      # config/config.exs
      config :exhmi, ExHMI.Transport.OpcUA,
        port: 4840,
        hostname: "emotion-controller",
        users: [{"admin", "change-me"}],
        tick_ms: 100

  ## Pushing telemetry from ExMove

  Call `ExHMI.push_joint_state/3` from your ExMove.Robot subscription or
  PathExecutor tick callback:

      ExHMI.push_joint_state(joint_positions_rad, tcp_xyz_m, tcp_rpy_rad)

  ## Receiving commands from RoboDK

  RoboDK (or any OPC UA client) writes a string to the `Command` node.
  ExHMI.AddressSpace parses and dispatches:

    - `"stop"`              — halt current motion
    - `"home"`              — return to zero pose
    - `"movej:r1,r2,…,r6"` — absolute joint move (radians)

  The parsed command becomes a `pending_target` that your supervisor can
  consume via `ExHMI.pop_pending_target/0` and dispatch to ExMove.
  """

  @doc "Push a joint-state snapshot into the OPC UA address space."
  defdelegate push_joint_state(positions, tcp_xyz, tcp_rpy),
    to: ExHMI.AddressSpace,
    as: :update_joint_state

  @doc "Update the motion state visible to OPC UA clients."
  defdelegate set_motion_state(state), to: ExHMI.AddressSpace, as: :update_motion_state

  @doc """
  Returns and clears any pending motion target written by an OPC UA client.

      case ExHMI.pop_pending_target() do
        {:movej, angles} -> ExMove.move_joints(angles)
        nil              -> :ok
      end
  """
  defdelegate pop_pending_target(), to: ExHMI.AddressSpace
end
