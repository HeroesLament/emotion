defmodule ExProto.Source.Exdrive do
  @moduledoc """
  Binds the node table to the running simulated drives.

  `ExProto.Source.Static` proved the protocol without a machine behind it. This
  is the same behaviour backed by `Exdrive.Drive` processes, which is what turns
  a served node table into a served robot.

  ## One status call per axis, not one per node

  A pendant rendering an axis asks for its position, target, velocity, state and
  fault together. Reading those one at a time is five `:gen_statem.call/2`
  round trips into the same process for one snapshot that the process could
  have handed over once — and worse, five snapshots taken at five different
  instants, so the velocity a client renders need not be the velocity that went
  with the position beside it.

  So `read_many/2` groups by axis and calls `Exdrive.Drive.status/1` once each.
  Every value in a batch for one axis comes from the same observation.

  ## Writes are checked, cast, and read back

  `Exdrive.Drive.set_target_position/2` is a cast, and a setpoint sent to a
  drive that is not in `switched_on` or `operation_enabled` is discarded rather
  than queued. A source that cast and reported success would tell a client the
  arm had been commanded when nothing had happened.

  So the state is checked first and a write to a drive that cannot accept one is
  `:rejected`. After the cast, `status/1` reads the value back — a call is
  ordered behind the casts already sent to that process, so the read cannot
  overtake the write — and the value returned to the client is what the drive
  actually holds, not what was asked for.
  """

  @behaviour ExProto.Source

  require Logger

  # CiA 402 states in which the drive accepts a setpoint. Everything else
  # discards it; see Exdrive.Drive.
  @accepting [:switched_on, :operation_enabled]

  @impl ExProto.Source
  def read(node_id, arg) do
    case read_many([node_id], arg) do
      [{^node_id, result}] -> result
      _ -> {:error, :unknown_node}
    end
  end

  @impl ExProto.Source
  def read_many(node_ids, _arg) do
    node_ids
    |> Enum.group_by(&axis_of/1)
    |> Enum.flat_map(fn
      {nil, ids} ->
        Enum.map(ids, &{&1, {:error, :unknown_node}})

      {axis, ids} ->
        case status(axis) do
          {:ok, status} -> Enum.map(ids, &{&1, project(&1, status)})
          {:error, reason} -> Enum.map(ids, &{&1, {:error, reason}})
        end
    end)
  end

  @impl ExProto.Source
  def write(node_id, value, _arg) do
    with {:ok, axis, "target_position"} <- parse(node_id),
         {:ok, target} <- as_float(value),
         {:ok, status} <- status(axis),
         :ok <- accepting?(status) do
      Exdrive.Drive.set_target_position(axis, target)

      # A call is ordered behind the casts already sent, so this observes the
      # drive after the setpoint landed rather than racing it.
      case status(axis) do
        {:ok, applied} -> {:ok, applied.target_position}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, _axis, _other_field} -> {:error, :not_writable}
      :error -> {:error, :unknown_node}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Projection: drive status → model nodes ────────────────────────────────

  defp project(node_id, status) do
    case parse(node_id) do
      {:ok, _axis, field} -> field_value(field, status)
      :error -> {:error, :unknown_node}
    end
  end

  defp field_value("position", status), do: {:ok, status.actual_position}
  defp field_value("target_position", status), do: {:ok, status.target_position}
  defp field_value("velocity", status), do: {:ok, status.actual_velocity}

  # The model types this as a string and the drive holds an atom. Converting
  # here rather than letting an atom reach the encoder: JSON has no atoms, and
  # a projection that relies on the encoder guessing is one refactor away from
  # emitting something a client cannot parse.
  defp field_value("drive_state", status), do: {:ok, Atom.to_string(status.state)}

  # The model says uint16, "0 when healthy". The drive says nil when healthy.
  # The model wins — it is the published contract.
  defp field_value("fault_code", %{fault_code: nil}), do: {:ok, 0}
  defp field_value("fault_code", status), do: {:ok, status.fault_code}

  # Derived, which is why it is read-only in the model.
  defp field_value("direction", status) do
    cond do
      status.actual_velocity > 1.0e-6 -> {:ok, "ccw"}
      status.actual_velocity < -1.0e-6 -> {:ok, "cw"}
      true -> {:ok, "stopped"}
    end
  end

  defp field_value(_unknown, _status), do: {:error, :unknown_node}

  # ── Talking to the drive ──────────────────────────────────────────────────

  defp status(axis) do
    {:ok, Exdrive.Drive.status(axis)}
  catch
    :exit, {:noproc, _} ->
      # The model declares an axis no drive is running for. That is a wiring
      # error rather than a client error, so it is logged here as well as
      # reported — a client seeing :rejected should not be the only trace.
      Logger.warning("ExProto.Source.Exdrive: no drive running for axis #{inspect(axis)}")
      {:error, :rejected}

    :exit, reason ->
      Logger.warning("ExProto.Source.Exdrive: axis #{inspect(axis)} failed: #{inspect(reason)}")
      {:error, :rejected}
  end

  defp accepting?(%{state: state}) when state in @accepting, do: :ok
  defp accepting?(_status), do: {:error, :rejected}

  # ── Node ids ──────────────────────────────────────────────────────────────

  # "axes.j1.position" -> {:ok, "j1", "position"}
  defp parse(node_id) do
    case String.split(node_id, ".") do
      ["axes", axis, field] -> {:ok, axis, field}
      _ -> :error
    end
  end

  defp axis_of(node_id) do
    case parse(node_id) do
      {:ok, axis, _field} -> axis
      :error -> nil
    end
  end

  defp as_float(value) when is_float(value), do: {:ok, value}
  defp as_float(value) when is_integer(value), do: {:ok, value * 1.0}
  defp as_float(_value), do: {:error, :rejected}
end
