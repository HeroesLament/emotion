defmodule ExStore.Cell.JointSetting do
  @moduledoc """
  What commissioning says about one joint, keyed by the URDF's name for it.

  A URDF describes a mechanism. This describes an installation: which drive
  turns this joint, how fast it may go *in this cell*, where home is, and what
  travel it is allowed inside the travel the metal permits.

  None of it belongs in the CAD file, and the test of that is what happens when
  the file is re-exported — every value here survives, because none of them
  changed when the drawing did.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "joint_settings" do
    field :joint_name, :string
    field :axis_id, :string
    field :max_vel, :float
    field :max_acc, :float
    field :soft_lower, :float
    field :soft_upper, :float
    field :home, :float, default: 0.0

    belongs_to :robot, ExStore.Cell.Robot

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :robot_id,
      :joint_name,
      :axis_id,
      :max_vel,
      :max_acc,
      :soft_lower,
      :soft_upper,
      :home
    ])
    |> validate_required([:robot_id, :joint_name])
    |> validate_positive(:max_vel)
    |> validate_positive(:max_acc)
    |> validate_travel_order()
    |> unique_constraint([:robot_id, :joint_name])
    # By columns, not by the index's name — the migration calls this one
    # `joint_settings_one_drive_per_joint_index` and SQLite will never say so.
    # It reports a unique violation as the columns that collided, so the only
    # name that ever matches is the one Ecto derives from them. The same lesson
    # as the tools table, one level deeper: it holds for composite indexes too.
    |> unique_constraint([:robot_id, :axis_id])
    |> foreign_key_constraint(:robot_id)
  end

  defp validate_positive(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset
      value when value > 0.0 -> changeset
      _zero_or_less -> add_error(changeset, field, "must be greater than zero")
    end
  end

  # A soft limit whose lower is above its upper is not a narrow limit, it is a
  # joint that may not move at all, and nobody ever meant one.
  defp validate_travel_order(changeset) do
    lower = get_field(changeset, :soft_lower)
    upper = get_field(changeset, :soft_upper)

    if is_number(lower) and is_number(upper) and lower >= upper do
      add_error(changeset, :soft_lower, "must be below the upper soft limit")
    else
      changeset
    end
  end
end
