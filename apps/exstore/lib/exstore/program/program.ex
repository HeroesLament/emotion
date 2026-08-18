defmodule ExStore.Program.Program do
  @moduledoc "A named sequence of statements."

  use Ecto.Schema

  import Ecto.Changeset

  schema "programs" do
    field :name, :string
    field :description, :string

    has_many :statements, ExStore.Program.Statement,
      foreign_key: :program_id,
      preload_order: [asc: :seq]

    timestamps()
  end

  def changeset(program, attrs) do
    program
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message: "must be lowercase, start with a letter, and contain only letters, digits and _"
    )
    |> validate_length(:name, max: 48)
    |> unique_constraint(:name)
  end
end
