defmodule ExStore.Repo.Migrations.CreateMasterings do
  use Ecto.Migration

  @moduledoc """
  A **shadow** of what each drive says its joint zero is. Not the source of it.

  The drive owns the number, because on real hardware the encoder is on the
  driver board: the offset is a property of this board bolted to this motor
  bolted into this joint. A board swap legitimately invalidates it, and a
  controller that pushed a stored offset back at boot would silently relocate
  every taught point in the cell — with nothing faulting, because every joint
  would still report a plausible angle. See servo4257-rs/docs/MASTERING.md.

  So this table exists for the three things a shadow is genuinely good for:

    * **backup and restore** — a replacement board can be given the old number
      deliberately, by a person who knows they are doing it;
    * **history** — when did this change, and who changed it;
    * **drift detection** — comparing what the fleet says now against what it
      said last time is the ONLY way to notice that an axis was re-mastered
      underneath a cell full of taught points.

  Insert-only. There is no update path and there is no unique index per axis,
  because a row is not a fact about the present, it is a record that somebody
  once observed a value. Newest wins; the older ones are the history.
  """

  def change do
    create table(:masterings) do
      add :robot_id, references(:robots, on_delete: :delete_all), null: false

      # The drive, not the joint. Mastering relates encoder counts to joint
      # angle, so it is keyed by the thing that holds the encoder — and a
      # joint renamed in a re-exported drawing must not orphan its history.
      add :axis_id, :string, null: false

      # Radians. The controller's whole boundary is SI; the counts/radians
      # conversion belongs to the adapter that talks to a real drive.
      add :offset, :float, null: false

      # What the drive said about itself when this was recorded:
      # "unmastered" | "unreferenced" | "referenced".
      add :state, :string, null: false

      # How the row got here:
      #   "taught"   — somebody drove to the witness mark and declared it
      #   "observed" — read off the drive at boot, no human involved
      #   "restored" — written back to a replacement board from a backup
      add :source, :string, null: false, default: "observed"

      # Free text. The one field a maintenance log actually gets read for.
      add :note, :string

      timestamps()
    end

    # The only query that matters is "newest per axis for this robot", and it
    # is also the one drift detection runs on every boot.
    create index(:masterings, [:robot_id, :axis_id, :inserted_at])
  end
end
