defmodule ExStore.Points do
  @moduledoc """
  Taught points.

  The rule this module exists to enforce is that a point is only ever stored
  with everything needed to replay it: a robot whose chain the joint vector
  actually fits, and a frame that exists. Storing a point that cannot be
  replayed is worse than refusing to teach one, because the refusal happens
  while the operator is still standing at the arm.
  """

  import Ecto.Query

  alias ExStore.Cell.{Point, Robot}
  alias ExStore.Repo

  def list, do: Repo.all(from(p in Point, order_by: p.name))

  def get(id), do: Repo.get(Point, id)

  def by_name(name) when is_binary(name), do: Repo.get_by(Point, name: name)

  @doc "Every point taught in this frame. What a re-teach moves."
  def in_frame(frame_id), do: Repo.all(from(p in Point, where: p.frame_id == ^frame_id))

  @doc """
  Teaches a point, or re-teaches one of the same name.

  One function rather than a create and an update, for the same reason
  `teach_frame` is one: a position that was taught slightly wrong and taught
  again is the same position.
  """
  def teach(attrs), do: store(attrs, "taught")

  @doc """
  Records a point that arrived from somewhere else.

  Same storage, different claim. `teach/1` means the arm was here and somebody
  said so; this means a file said so. The joint vector that comes with it is a
  measurement made on another machine, which is worth being able to tell apart
  later — a pendant showing a program's points can say which ones this arm has
  never actually been to.

  It does not manufacture a joint vector. A point with no measured solution
  would have to be solved, and `move_joint` "does not solve anything — it
  commands the six angles that were recorded"; commanding a solver's opinion as
  though it were a recording is the configuration-flip failure the taught joint
  vector exists to remove. Planning a pose from geometry is a different feature
  and is named as one in `INSTALLATION.md`.
  """
  def define(attrs), do: store(attrs, "defined")

  defp store(attrs, source) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("source", source)

    case by_name(attrs["name"]) do
      nil -> %Point{} |> Point.changeset(attrs) |> validate_joint_count() |> Repo.insert()
      point -> point |> Point.changeset(attrs) |> validate_joint_count() |> Repo.update()
    end
  end

  @doc """
  Deletes a point, unless a program still moves to it.

  Asked as a query rather than caught as a constraint, for the reason measured
  when frames landed: SQLite reports a foreign key violation as bare text with
  no constraint name in it, so `foreign_key_constraint/3` has nothing to match
  and the violation raises instead of becoming an error. The restrict stays in
  the migration as the backstop.
  """
  def delete(%Point{} = point) do
    if Repo.exists?(from(r in ExStore.Program.StatementRef, where: r.point_id == ^point.id)) do
      changeset =
        point
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:id, "is used by a program")

      {:error, changeset}
    else
      Repo.delete(point)
    end
  end

  # A joint vector of the wrong length is a point taught on another arm, and
  # the only place to notice is here — six numbers replayed on a seven-axis
  # chain do not fail, they leave one joint wherever it happened to be.
  defp validate_joint_count(changeset) do
    with robot_id when not is_nil(robot_id) <- Ecto.Changeset.get_field(changeset, :robot_id),
         %Robot{} = robot <- Repo.get(Robot, robot_id) do
      expected = length(Robot.joint_names(robot))
      taught = length(Ecto.Changeset.get_field(changeset, :joints) || [])

      if expected == taught do
        changeset
      else
        Ecto.Changeset.add_error(
          changeset,
          :joints,
          "has #{taught} positions; #{robot.name} has #{expected} joints"
        )
      end
    else
      _no_robot -> changeset
    end
  end
end
