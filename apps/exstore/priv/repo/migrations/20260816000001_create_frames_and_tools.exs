defmodule ExStore.Repo.Migrations.CreateFramesAndTools do
  use Ecto.Migration

  @moduledoc """
  Frames and tools: the first geometry the controller stores rather than
  compiles.

  Two tables of the same six numbers, deliberately not one. They are looked up
  by different questions — "where is the work" against "what is fitted" — they
  are re-taught by different procedures, and a taught point will reference one
  of each. A single table with a `kind` column would make every query say
  `where kind = ?` to buy nothing.
  """

  def change do
    create table(:frames) do
      add :name, :string, null: false
      # Nullable, and resolved: a frame defined relative to another is how a
      # fixture on a positioner is described, and every vendor grew one. The
      # column costs nothing now and a migration over taught data later.
      add :parent_id, references(:frames, on_delete: :restrict), null: true

      add :x, :float, null: false, default: 0.0
      add :y, :float, null: false, default: 0.0
      add :z, :float, null: false, default: 0.0
      add :rx, :float, null: false, default: 0.0
      add :ry, :float, null: false, default: 0.0
      add :rz, :float, null: false, default: 0.0

      # Taught-constant against runtime-mutable, which is the axis that turned
      # out to matter — not private against shared. A vision offset writes a
      # mutable frame at line rate; a taught fixture origin is configuration and
      # is not writable by a program at all.
      add :mutable, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:frames, [:name])
    create index(:frames, [:parent_id])

    create table(:tools) do
      add :name, :string, null: false

      add :x, :float, null: false, default: 0.0
      add :y, :float, null: false, default: 0.0
      add :z, :float, null: false, default: 0.0
      add :rx, :float, null: false, default: 0.0
      add :ry, :float, null: false, default: 0.0
      add :rz, :float, null: false, default: 0.0

      # Which tool is on the flange is machine state, and it is state that has
      # to survive a power cycle — the arm does not shed its gripper when the
      # cabinet is switched off. A column rather than a runtime variable, and a
      # partial unique index rather than a convention, so the database itself
      # refuses two tools fitted at once. No row fitted is a real state: it is
      # a bare flange, and it is what the arm has after a changeover nobody
      # finished.
      add :fitted, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:tools, [:name])
    create unique_index(:tools, [:fitted], where: "fitted = 1", name: :tools_one_fitted_index)
  end
end
