defmodule ExStore.Repo.Migrations.CreateRobots do
  use Ecto.Migration

  @moduledoc """
  The robot description, and the commissioning that is not part of it.

  See `protocol/ROBOT.md`. Two tables because they are owned by two different
  people: the URDF comes from whoever drew the mechanism, and everything in
  `joint_settings` comes from whoever installed it.
  """

  def change do
    create table(:robots) do
      add :name, :string, null: false

      # The document, byte for byte. Stored rather than normalised because a
      # URDF carries visual meshes, collision geometry and inertia that this
      # build does not model and the Studio's viewport eventually will —
      # normalising on import throws them away, and re-importing after we grow
      # the columns means asking a customer for a file they exported two years
      # ago.
      add :urdf, :text, null: false

      # A derived index of the document, regenerated every time it is stored
      # and never edited: `[{"name", "lower", "upper", "max_vel"}, ...]` for
      # each actuated joint, base to tip.
      #
      # It exists so this table can enforce two things without parsing XML —
      # that a commissioning row names a joint the robot actually has, and that
      # a soft limit is inside the mechanical one. A database that can only
      # store the rule is a database that finds out at speed.
      add :joints, :text, null: false

      # Which robot this controller is. Machine state, like a fitted tool, and
      # the same partial unique index rather than a convention: two loaded
      # robots is not a state, and no rows at all is a controller that has been
      # commissioned with nothing yet.
      add :active, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:robots, [:name])
    create unique_index(:robots, [:active], where: "active = 1", name: :robots_one_active_index)

    create table(:joint_settings) do
      add :robot_id, references(:robots, on_delete: :delete_all), null: false

      # Keyed by the URDF's own joint name rather than by position, so
      # re-exporting a CAD file with a joint inserted does not silently shift
      # every commissioning row one place down the arm.
      add :joint_name, :string, null: false

      # The drive this joint is wired to. The single most installation-specific
      # fact there is, and the one the loader deliberately stopped inventing.
      add :axis_id, :string, null: true

      # What this machine may do, which is not what the mechanism could do.
      add :max_vel, :float, null: true
      add :max_acc, :float, null: true

      # Travel inside the mechanical travel. Wider is refused, not obeyed.
      add :soft_lower, :float, null: true
      add :soft_upper, :float, null: true

      add :home, :float, null: false, default: 0.0

      timestamps()
    end

    create unique_index(:joint_settings, [:robot_id, :joint_name])

    # Two joints wired to one drive is a wiring error, and it is the kind that
    # moves the wrong axis rather than failing to move anything.
    create unique_index(:joint_settings, [:robot_id, :axis_id],
             where: "axis_id IS NOT NULL",
             name: :joint_settings_one_drive_per_joint_index
           )
  end
end
