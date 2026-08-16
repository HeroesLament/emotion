defmodule ExStore.Geometry.Tool do
  @moduledoc """
  An end-of-arm tool: the transform from the flange to the tool centre point.

  The same six numbers as a frame and a different meaning. `fitted` is the one
  extra field, and it is the whole reason tools are swappable rather than
  configured: which tool is on the arm is machine state, and a taught point
  records which one was fitted when it was taught.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ExStore.Geometry.Pose

  @reserved ~w(none base)

  schema "tools" do
    field :name, :string
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    field :z, :float, default: 0.0
    field :rx, :float, default: 0.0
    field :ry, :float, default: 0.0
    field :rz, :float, default: 0.0
    field :fitted, :boolean, default: false

    timestamps()
  end

  def reserved, do: @reserved

  def changeset(tool, attrs) do
    tool
    |> Pose.cast_name(attrs, @reserved)
    |> Pose.cast_pose(attrs)
    |> unique_constraint(:name)
  end

  @doc """
  Fitting is its own changeset because it is not editing.

  Teaching a tool changes what the arm believes about geometry it can check;
  fitting one changes what is physically bolted on, which the controller cannot
  check at all. Different operations, different grants, different changesets.
  """
  def fit_changeset(tool, fitted?) do
    tool
    |> change(fitted: fitted?)
    # Not the index's name, which is `tools_one_fitted_index` in the migration.
    # SQLite's error text is "UNIQUE constraint failed: tools.fitted" — it names
    # the table and column, never the index — so the adapter can only hand Ecto
    # the derived `tools_fitted_index`. Naming the real index here would match
    # nothing and the constraint would raise instead of becoming an error.
    |> unique_constraint(:fitted)
  end
end
