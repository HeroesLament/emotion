defmodule ExStore.Tools do
  @moduledoc """
  End-of-arm tools, stored, and the one that is fitted.

  The tool used to be a field on `ExMove.Chain`, which made the arm's reach
  compile-time geometry and re-teaching a gripper a deploy. Here it is a row,
  and the concept that falls out of that is the one this suite wants:
  **the fitted tool is machine state, not a constant.**
  """

  import Ecto.Query

  alias ExStore.Geometry.Tool
  alias ExStore.Repo

  def list, do: Repo.all(from(t in Tool, order_by: t.name))

  def get(id), do: Repo.get(Tool, id)

  def by_name(name) when is_binary(name), do: Repo.get_by(Tool, name: name)

  def create(attrs) do
    %Tool{}
    |> Tool.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Re-teaches a tool: a new TCP for the same physical thing."
  def teach(%Tool{} = tool, attrs) do
    tool
    |> Tool.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a tool, unless something was taught with it fitted.

  A point records which tool was fitted so that replaying it under a different
  one can be caught. Deleting the tool would delete the evidence, leaving a
  point that looks like it was taught on a bare flange.
  """
  def delete(%Tool{} = tool) do
    if Repo.exists?(from(p in ExStore.Cell.Point, where: p.tool_id == ^tool.id)) do
      changeset =
        tool
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:id, "was fitted when a point was taught")

      {:error, changeset}
    else
      Repo.delete(tool)
    end
  end

  @doc """
  The fitted tool, or `nil` for a bare flange.

  `nil` is a real answer rather than a missing one. An arm with nothing bolted
  on has a TCP at the flange, and pretending otherwise by inventing a default
  tool would make "which tool was this point taught with" unanswerable at
  exactly the moment it matters.
  """
  def fitted, do: Repo.one(from(t in Tool, where: t.fitted == true))

  @doc """
  Fits a tool, unfitting whatever was on the flange.

  In one transaction, because the intermediate state — two tools fitted, or
  none — is a state the partial unique index refuses anyway, and a crash
  between two statements would leave a controller that believes it is bare
  while holding a gripper.
  """
  def fit(%Tool{} = tool) do
    Repo.transaction(fn ->
      Repo.update_all(from(t in Tool, where: t.fitted == true and t.id != ^tool.id), set: [fitted: false])

      case Repo.update(Tool.fit_changeset(tool, true)) do
        {:ok, fitted} -> fitted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def fit(name) when is_binary(name) do
    case by_name(name) do
      nil -> {:error, :unknown_tool}
      tool -> fit(tool)
    end
  end

  @doc "Takes whatever is fitted off the flange. A bare flange is a valid state."
  def unfit do
    {count, _} = Repo.update_all(from(t in Tool, where: t.fitted == true), set: [fitted: false])
    {:ok, count}
  end
end
