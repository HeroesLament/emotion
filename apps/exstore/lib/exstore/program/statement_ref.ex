defmodule ExStore.Program.StatementRef do
  @moduledoc """
  A statement's reference to something that has its own life: a point, a frame,
  a tool, another program.

  Four nullable columns and a check constraint rather than one polymorphic id,
  because a polymorphic reference is a foreign key the database cannot enforce —
  and enforcement is the entire reason references live in a table instead of in
  the statement's JSON. This is what makes "refuse to delete a point a program
  uses" a constraint rather than a policy.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @referents [:point_id, :frame_id, :tool_id, :program_id]

  schema "statement_refs" do
    field :arg_name, :string
    field :point_id, :id
    field :frame_id, :id
    field :tool_id, :id
    field :program_id, :id

    belongs_to :statement, ExStore.Program.Statement

    timestamps()
  end

  def referents, do: @referents

  def changeset(ref, attrs) do
    ref
    |> cast(attrs, [:statement_id, :arg_name | @referents])
    |> validate_required([:statement_id, :arg_name])
    |> validate_exactly_one_referent()
    |> unique_constraint([:statement_id, :arg_name])
    |> foreign_key_constraint(:point_id)
    |> foreign_key_constraint(:frame_id)
    |> foreign_key_constraint(:tool_id)
    |> foreign_key_constraint(:program_id)
    |> check_constraint(:statement_id,
      name: :exactly_one_referent,
      message: "must reference exactly one thing"
    )
  end

  @doc "What this reference points at, as `{kind, id}`."
  def referent(%__MODULE__{} = ref) do
    Enum.find_value(@referents, fn field ->
      case Map.fetch!(ref, field) do
        nil -> nil
        id -> {field |> Atom.to_string() |> String.trim_trailing("_id") |> String.to_atom(), id}
      end
    end)
  end

  defp validate_exactly_one_referent(changeset) do
    set = Enum.count(@referents, &(get_field(changeset, &1) != nil))

    case set do
      1 -> changeset
      0 -> add_error(changeset, :point_id, "a reference must point at something")
      _many -> add_error(changeset, :point_id, "a reference points at one thing, not #{set}")
    end
  end
end
