defmodule ExStore.Cell.Mastering do
  @moduledoc """
  One observation of a drive's joint zero.

  A row here is not "the offset for this axis". It is "on this date, this axis
  said this". The difference is the entire design: the drive owns the number,
  and a controller that treated its own copy as authoritative would eventually
  push a stale one and move a cell full of taught points without saying so.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @sources ~w(taught observed restored)
  @states ~w(unmastered unreferenced referenced)

  schema "masterings" do
    field :axis_id, :string
    field :offset, :float
    field :state, :string
    field :source, :string, default: "observed"
    field :note, :string

    belongs_to :robot, ExStore.Cell.Robot

    timestamps()
  end

  def sources, do: @sources
  def states, do: @states

  def changeset(mastering, attrs) do
    mastering
    |> cast(attrs, [:robot_id, :axis_id, :offset, :state, :source, :note])
    |> validate_required([:robot_id, :axis_id, :offset, :state])
    |> validate_inclusion(:source, @sources)
    # An unmastered axis has no offset to record, so a row claiming both is
    # either a bug or a lie, and there is no reading of it that helps anybody.
    |> validate_inclusion(:state, @states)
    |> validate_not_unmastered()
    |> foreign_key_constraint(:robot_id)
  end

  defp validate_not_unmastered(changeset) do
    if get_field(changeset, :state) == "unmastered" do
      add_error(changeset, :state, "an unmastered axis has no offset to record")
    else
      changeset
    end
  end
end
