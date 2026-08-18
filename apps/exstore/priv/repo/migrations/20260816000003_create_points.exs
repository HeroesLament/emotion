defmodule ExStore.Repo.Migrations.CreatePoints do
  use Ecto.Migration

  @moduledoc """
  A taught point: a pose, the frame it was taught in, the tool that was fitted,
  and the joint solution the arm was actually in.

  See `protocol/PROGRAMS.md` §3. The fourth of those is where this can do
  better than the incumbents rather than merely match them: ABB encodes a
  discrete configuration index because RAPID has to describe a branch
  compactly, and we have the whole joint vector at teach time. Storing it is
  six floats and it removes the failure mode rather than describing it.
  """

  def change do
    create table(:points) do
      add :name, :string, null: false

      # The pose is stored **in the frame**, not in the base. That is the whole
      # mechanism behind "re-teaching a frame moves every point taught in it":
      # the point does not change, the frame does, and the base pose is
      # computed from the two whenever anybody asks.
      add :frame_id, references(:frames, on_delete: :restrict), null: true

      # Which tool was fitted when this was taught. Nullable because a bare
      # flange is a real state, and mandatory in the sense that matters: a pose
      # taught with one tool does not describe the same physical location with
      # another, so what was fitted is recorded even when the answer is
      # "nothing".
      add :tool_id, references(:tools, on_delete: :restrict), null: true

      # Which arm was in that joint configuration. A joint vector is only
      # meaningful for the chain it was measured on — replaying six angles
      # taught on a different mechanism is not an approximation of anything.
      add :robot_id, references(:robots, on_delete: :restrict), null: false

      add :x, :float, null: false, default: 0.0
      add :y, :float, null: false, default: 0.0
      add :z, :float, null: false, default: 0.0
      add :rx, :float, null: false, default: 0.0
      add :ry, :float, null: false, default: 0.0
      add :rz, :float, null: false, default: 0.0

      # The joint solution, as JSON, because its length is a fact about the
      # robot rather than about this build. Six columns would be a six-axis
      # assumption written into a schema that has just stopped making one.
      add :joints, :text, null: false

      # Taught-constant against runtime-mutable, the same axis as frames — what
      # FANUC's P[] against PR[] actually encodes. A vision result writes a
      # mutable point; a taught approach position is not writable by a running
      # program at all.
      add :mutable, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:points, [:name])
    create index(:points, [:frame_id])
    create index(:points, [:tool_id])

    # No `program_id` yet. Points are global until programs exist, and every
    # vendor ended up with both — FANUC's P[] against PR[], Yaskawa's local
    # against global position variables. Adding a nullable column then is one
    # ALTER TABLE; adding a foreign key to a table that does not exist is not
    # possible now and would be a lie if it were.
  end
end
