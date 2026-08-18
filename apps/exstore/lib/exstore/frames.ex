defmodule ExStore.Frames do
  @moduledoc """
  User frames, stored.

  This module deals in rows and names. It deliberately does not compose a
  frame with its parent into a transform — that is matrix arithmetic, it lives
  in `exmove`, and a database app that reached for it would drag the IK NIF
  behind every credential lookup. What this module owns is the tree's
  *integrity*: names, parents, and the guarantee that walking up terminates.
  """

  import Ecto.Query

  alias ExStore.Geometry.Frame
  alias ExStore.Repo

  # A frame ten deep is a modelling mistake, not a cell. The cap exists so a
  # cycle that survives the check below still cannot hang a resolve at 200 Hz.
  @max_depth 8

  def max_depth, do: @max_depth

  def list, do: Repo.all(from(f in Frame, order_by: f.name))

  def get(id), do: Repo.get(Frame, id)

  def by_name(name) when is_binary(name), do: Repo.get_by(Frame, name: name)

  @doc """
  Creates a frame.

  Six numbers and a name is the whole of it, which is what makes frames the
  smallest piece of work in `PROGRAMS.md` and the one everything else needs.
  """
  def create(attrs) do
    %Frame{}
    |> Frame.changeset(attrs)
    |> validate_parent()
    |> Repo.insert()
  end

  @doc """
  Re-teaches a frame.

  The operation the table exists for: this moves every point taught in the
  frame and nothing else. Points do not exist yet, which is why the test for
  that property is written against the transform rather than against rows.
  """
  def teach(%Frame{} = frame, attrs) do
    frame
    |> Frame.changeset(attrs)
    |> validate_parent()
    |> Repo.update()
  end

  @doc """
  Deletes a frame, unless another frame is defined relative to it.

  The check is a query rather than a caught constraint, and that is not a
  preference. SQLite reports a foreign key violation as the bare text "FOREIGN
  KEY constraint failed" with no constraint name in it, so `foreign_key_
  constraint/3` has nothing to match on and the violation raises instead of
  becoming an error — measured, not assumed. `on_delete: :restrict` stays in
  the migration as the backstop for whatever writes this table that is not this
  function.
  """
  def delete(%Frame{} = frame) do
    cond do
      Repo.exists?(from(f in Frame, where: f.parent_id == ^frame.id)) ->
        refuse(frame, "is a parent of another frame")

      # And now the reason the restrict was there in the first place. A frame
      # that can be deleted out from under a taught point is a point that
      # silently means somewhere else — the pose is stored *in* the frame, so
      # losing the frame does not orphan the point, it changes where it is.
      Repo.exists?(from(p in ExStore.Cell.Point, where: p.frame_id == ^frame.id)) ->
        refuse(frame, "still has points taught in it")

      true ->
        Repo.delete(frame)
    end
  end

  defp refuse(frame, message) do
    {:error, frame |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(:id, message)}
  end

  @doc """
  The frames from the root down to and including this one.

  Base-first, because that is the order they compose in and getting it
  backwards produces a pose that is wrong in a way that looks plausible.
  """
  def lineage(%Frame{} = frame), do: walk_up(frame, [], @max_depth)

  defp walk_up(%Frame{parent_id: nil} = frame, acc, _fuel), do: [frame | acc]

  defp walk_up(_frame, _acc, 0), do: {:error, :too_deep}

  defp walk_up(%Frame{parent_id: parent_id} = frame, acc, fuel) do
    case get(parent_id) do
      nil -> {:error, :missing_parent}
      parent -> walk_up(parent, [frame | acc], fuel - 1)
    end
  end

  # A cycle is refused when it is written, not survived when it is read.
  #
  # The depth cap in `lineage/1` is the second line of defence and exists for
  # rows written by something that is not this function — a restored backup, a
  # migration, a future importer. Defence in depth is cheap here; a 200 Hz loop
  # walking a ring is not.
  defp validate_parent(changeset) do
    case Ecto.Changeset.get_change(changeset, :parent_id) do
      nil -> changeset
      parent_id -> check_ancestry(changeset, parent_id)
    end
  end

  defp check_ancestry(changeset, parent_id) do
    id = Ecto.Changeset.get_field(changeset, :id)

    # `- 1` because the frame being written is itself a level. A parent already
    # at the cap means this one would be past it.
    case ancestors(parent_id, @max_depth - 1) do
      {:error, :too_deep} ->
        Ecto.Changeset.add_error(changeset, :parent_id, "is nested deeper than #{@max_depth}")

      {:ok, ids} ->
        if id != nil and id in ids do
          Ecto.Changeset.add_error(changeset, :parent_id, "would make a cycle")
        else
          changeset
        end
    end
  end

  defp ancestors(nil, _fuel), do: {:ok, []}
  defp ancestors(_id, 0), do: {:error, :too_deep}

  defp ancestors(id, fuel) do
    case get(id) do
      nil ->
        {:ok, [id]}

      frame ->
        case ancestors(frame.parent_id, fuel - 1) do
          {:ok, rest} -> {:ok, [id | rest]}
          error -> error
        end
    end
  end
end
