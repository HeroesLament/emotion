defmodule ExStore.Geometry.Frame do
  @moduledoc """
  A named place to teach a path in.

  Six numbers relative to `parent`, or to the arm's base when there is no
  parent. The point of the table is a single property: re-teaching a frame
  moves every point taught in it and nothing else.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ExStore.Geometry.Pose

  # `base` and `tool` are not stored and never will be: base is the arm's
  # origin and tool is re-resolved from the joint angles every tick. Allowing a
  # row to shadow either would make a pendant showing BASE mean two things.
  @reserved ~w(base tool world flange)

  schema "frames" do
    field :name, :string
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    field :z, :float, default: 0.0
    field :rx, :float, default: 0.0
    field :ry, :float, default: 0.0
    field :rz, :float, default: 0.0
    field :mutable, :boolean, default: false

    belongs_to :parent, __MODULE__

    timestamps()
  end

  @doc "The names the controller already means something by."
  def reserved, do: @reserved

  def changeset(frame, attrs) do
    frame
    |> Pose.cast_name(attrs, @reserved)
    |> Pose.cast_pose(attrs)
    |> cast(attrs, [:mutable, :parent_id])
    |> unique_constraint(:name)
    |> foreign_key_constraint(:parent_id)
    |> refuse_self_parent()
  end

  defp refuse_self_parent(changeset) do
    id = get_field(changeset, :id)
    parent_id = get_field(changeset, :parent_id)

    if id != nil and id == parent_id do
      add_error(changeset, :parent_id, "cannot be itself")
    else
      changeset
    end
  end
end
