defmodule ExMove.Mastering do
  @moduledoc """
  The one place that decides whether a drive's number may be used as a joint
  angle.

  Two different positions come back from a drive, and conflating them is the
  bug this exists to prevent:

    * `actual_position` — the drive's own accumulator. Always a number, never
      meaningful on its own. Jogging uses it, because jogging is relative and
      because driving to a witness mark is how an axis is recovered.
    * `joint_position` — that number related to a declared zero. `nil` exactly
      when nobody may act on it.

  Everything that computes a POSE goes through here: forward kinematics,
  teaching a point, Cartesian motion. If an axis does not know where it is,
  those must refuse — not because the arm cannot move, but because a pose
  assembled from a guess looks like a plausible position rather than a fault,
  and it is discovered at the workpiece.

  See `servo4257-rs/docs/MASTERING.md` for why the drive owns the number.
  """

  @doc """
  The joint angle a drive's status supports, or why it does not.

  `{:error, :unreferenced}` and `{:error, :unmastered}` are kept apart on
  purpose: they are different missing facts with different recoveries, and an
  operator told only "not ready" has to go and find out which.
  """
  def joint_position(%{mastering: :referenced, joint_position: position})
      when is_number(position),
      do: {:ok, position}

  def joint_position(%{mastering: state}) when is_atom(state), do: {:error, state}

  # A status map from something that predates mastering — a hand-built fixture,
  # or a drive adapter not yet taught the concept. Reading the accumulator as
  # the joint angle is the old behaviour, and keeping it means adding a concept
  # does not silently disable every axis that has not heard of it yet.
  def joint_position(%{actual_position: position}) when is_number(position),
    do: {:ok, position}

  def joint_position(_other), do: {:error, :unreadable}

  @doc """
  Reads one axis, refusing rather than guessing.

  Returns `{:error, {reason, axis_id}}` — the axis id is carried because
  "unreferenced" without naming which joint is a message that sends somebody
  to check six of them.
  """
  def read_axis(axis_id) do
    case Exdrive.Drive.status(axis_id) do
      status when is_map(status) ->
        case joint_position(status) do
          {:ok, position} -> {:ok, position, status}
          {:error, reason} -> {:error, {reason, axis_id}}
        end

      _other ->
        {:error, {:unreadable, axis_id}}
    end
  catch
    :exit, _reason -> {:error, {:unreadable, axis_id}}
  end

  @doc """
  What every axis in a chain says about itself, in chain order.

  A plain report, not a judgement: `[%{axis_id:, state:, offset:, drift:}]`.
  The drift is carried even when it passed, because a drift that creeps toward
  the limit over months is a slipping coupling, and swallowing it because it
  passed is how that finding is lost.
  """
  def report(%ExMove.Chain{axis_ids: axis_ids}) do
    Enum.map(axis_ids, fn axis_id ->
      case safe_status(axis_id) do
        nil ->
          %{axis_id: axis_id, state: :unreadable, offset: nil, drift: nil}

        status ->
          %{
            axis_id: axis_id,
            state: Map.get(status, :mastering, :referenced),
            offset: Map.get(status, :master_offset),
            drift: Map.get(status, :mastering_drift)
          }
      end
    end)
  end

  @doc """
  `:ok` when every axis in the chain knows where it is.

  `{:error, {:not_referenced, [{axis_id, state}]}}` names all of them rather
  than the first: an operator who has to power-cycle a cell wants the list, not
  a sequence of one-at-a-time refusals.
  """
  def check(%ExMove.Chain{} = chain) do
    case Enum.reject(report(chain), &(&1.state == :referenced)) do
      [] -> :ok
      bad -> {:error, {:not_referenced, Enum.map(bad, &{&1.axis_id, &1.state})}}
    end
  end

  defp safe_status(axis_id) do
    case Exdrive.Drive.status(axis_id) do
      status when is_map(status) -> status
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end
end
