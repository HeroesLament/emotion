defmodule ExStore.Repo.Migrations.CreatePrograms do
  use Ecto.Migration

  @moduledoc """
  Programs, and the statements that are their body.

  `PROGRAMS.md` §8. A statement is a row rather than a line of text, and the
  arguments split in two: literals in JSON on the row, references in their own
  table so the database holds real foreign keys and can refuse to delete a point
  a program still uses.
  """

  def change do
    create table(:programs) do
      add :name, :string, null: false
      add :description, :string, null: true
      timestamps()
    end

    create unique_index(:programs, [:name])

    create table(:statements) do
      add :program_id, references(:programs, on_delete: :delete_all), null: false

      # Nesting is deferred, not designed out. Branching turns a program from a
      # list into a tree, and adding this column afterwards means migrating
      # every program that exists by then.
      add :parent_id, references(:statements, on_delete: :delete_all), null: true

      # `id` for identity, `seq` for order. Renumbering a program must not
      # invalidate a jump, which is exactly what FANUC's `JMP LBL[]` — a label,
      # not a line number — exists to avoid.
      add :seq, :integer, null: false

      # A validated string, not an enum. Validated against the live registry, so
      # a program referencing an extension whose module is not loaded still
      # loads and names the kind it is missing. An enum in a migration would
      # make every extension a schema change.
      add :kind, :string, null: false

      # Literals only: a feedrate is a number and belongs on the row. A point is
      # an entity, and putting its id in here would make the foreign key a
      # comment.
      add :args, :text, null: false, default: "{}"

      timestamps()
    end

    create unique_index(:statements, [:program_id, :seq])
    create index(:statements, [:parent_id])

    # Written as SQL, and the reason is worth a note: SQLite cannot ALTER TABLE
    # ADD CONSTRAINT, so a table-level CHECK has to be part of the CREATE. Ecto's
    # `create constraint(...)` emits the ALTER and fails at run time — measured,
    # not assumed.
    #
    # Four nullable columns and a check rather than one polymorphic id, because a
    # polymorphic reference is a foreign key the database cannot enforce, and
    # enforcement is the entire reason references live in a table instead of in
    # the statement's JSON.
    execute(
      """
      CREATE TABLE statement_refs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        statement_id INTEGER NOT NULL REFERENCES statements(id) ON DELETE CASCADE,
        arg_name TEXT NOT NULL,
        point_id INTEGER REFERENCES points(id) ON DELETE RESTRICT,
        frame_id INTEGER REFERENCES frames(id) ON DELETE RESTRICT,
        tool_id INTEGER REFERENCES tools(id) ON DELETE RESTRICT,
        program_id INTEGER REFERENCES programs(id) ON DELETE RESTRICT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CONSTRAINT exactly_one_referent CHECK (
          (CASE WHEN point_id   IS NULL THEN 0 ELSE 1 END) +
          (CASE WHEN frame_id   IS NULL THEN 0 ELSE 1 END) +
          (CASE WHEN tool_id    IS NULL THEN 0 ELSE 1 END) +
          (CASE WHEN program_id IS NULL THEN 0 ELSE 1 END) = 1
        )
      )
      """,
      "DROP TABLE statement_refs"
    )

    create unique_index(:statement_refs, [:statement_id, :arg_name])
    create index(:statement_refs, [:point_id])
  end
end
