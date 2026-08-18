defmodule ExStore.Program.Statement do
  @moduledoc """
  One statement: a kind, its literal arguments, and its references.

  This module does not know what any kind means. The registry of kinds lives
  above `exstore` — it is populated by compiled extensions, which are a layer
  this app cannot see — so what is stored here is a validated *string*, and
  whoever stores it has already checked it against the registry.

  That split is the same one the URDF took: the store holds the artifact and
  enforces what a database can enforce; meaning lives where meaning can be
  computed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "statements" do
    field :seq, :integer
    field :kind, :string
    field :args, :map, virtual: true, default: %{}
    field :args_json, :string, source: :args

    belongs_to :program, ExStore.Program.Program
    belongs_to :parent, __MODULE__

    has_many :refs, ExStore.Program.StatementRef, foreign_key: :statement_id

    timestamps()
  end

  def changeset(statement, attrs) do
    statement
    |> cast(attrs, [:program_id, :parent_id, :seq, :kind])
    |> put_args(attrs)
    |> validate_required([:program_id, :seq, :kind])
    |> validate_number(:seq, greater_than_or_equal_to: 0)
    |> unique_constraint([:program_id, :seq])
    |> foreign_key_constraint(:program_id)
  end

  @doc "The literal arguments, decoded. Never nil."
  def args(%__MODULE__{args: args}) when is_map(args) and map_size(args) > 0, do: args

  def args(%__MODULE__{args_json: nil}), do: %{}

  def args(%__MODULE__{args_json: json}) do
    case :json.decode(json) do
      map when is_map(map) -> map
      _other -> %{}
    end
  rescue
    _error -> %{}
  end

  defp put_args(changeset, attrs) do
    case attrs[:args] || attrs["args"] do
      nil ->
        changeset

      args when is_map(args) ->
        encodable = Map.new(args, fn {key, value} -> {to_string(key), value} end)

        changeset
        |> put_change(:args, encodable)
        |> put_change(:args_json, IO.iodata_to_binary(:json.encode(encodable)))

      _other ->
        add_error(changeset, :args, "must be a map of literal arguments")
    end
  end
end
