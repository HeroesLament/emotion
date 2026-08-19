defmodule ExStore.Repo.Migrations.AddPointSource do
  @moduledoc """
  How a point got its numbers.

  `taught` — the arm was at this pose and somebody said so. The joint vector is
  a measurement.

  `defined` — the pose arrived from somewhere else: a program file pushed from
  a studio, or a backup. The joint vector is a measurement *made on another
  machine*, which is a different claim and worth being able to tell apart.

  Not a quality ranking. `MASTERING.md` makes the same distinction one layer
  down with three states rather than a boolean, for the same reason: these are
  different facts, and a pendant that cannot show which is which cannot warn
  anybody.

  Existing rows are `taught`, which is true — until now the only way to make a
  point was to put the arm on it.
  """
  use Ecto.Migration

  def change do
    alter table(:points) do
      add :source, :string, null: false, default: "taught"
    end
  end
end
