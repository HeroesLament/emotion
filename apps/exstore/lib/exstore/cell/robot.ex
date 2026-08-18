defmodule ExStore.Cell.Robot do
  @moduledoc """
  A stored robot description: the URDF document, and a derived index of it.

  This module does not know what a URDF means. Parsing lives in `exmove`, and
  `exstore` deliberately does not depend on it — `exauth` depends on this app,
  and a credential lookup has no business dragging an inverse-kinematics NIF in
  behind it. So whoever stores a robot has already parsed it, and hands over
  the joint summary alongside the document.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "robots" do
    field :name, :string
    field :urdf, :string
    field :joints, {:array, :map}, virtual: true
    field :joints_json, :string, source: :joints
    field :active, :boolean, default: false

    has_many :settings, ExStore.Cell.JointSetting, foreign_key: :robot_id

    timestamps()
  end

  def changeset(robot, attrs) do
    robot
    |> cast(attrs, [:name, :urdf])
    |> put_joints(attrs)
    |> validate_required([:name, :urdf])
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message: "must be lowercase, start with a letter, and contain only letters, digits and _"
    )
    |> validate_length(:urdf, min: 1)
    |> unique_constraint(:name)
  end

  @doc """
  Loading a robot is not editing one, so it is its own changeset.

  Same reason a tool's `fit` is separate from its `teach`: one says what a thing
  is, the other says which one this machine currently has.
  """
  def activate_changeset(robot, active?) do
    robot
    |> change(active: active?)
    # Not the index's name from the migration. SQLite reports a unique
    # violation as "robots.active" — table and column, never the index — so the
    # constraint Ecto derives is the only one that ever matches. Measured, in
    # the tools table, before it was written down here.
    |> unique_constraint(:active)
  end

  @doc "The joint summary, decoded. `[]` on a row that predates one, never nil."
  def joints(%__MODULE__{joints: joints}) when is_list(joints), do: joints

  def joints(%__MODULE__{joints_json: nil}), do: []

  def joints(%__MODULE__{joints_json: json}) do
    case :json.decode(json) do
      list when is_list(list) -> list
      _other -> []
    end
  rescue
    _error -> []
  end

  @doc "The mechanical travel of one joint, or `nil` for a continuous one."
  def travel(robot, joint_name) do
    case Enum.find(joints(robot), &(&1["name"] == joint_name)) do
      %{"lower" => lower, "upper" => upper} when is_number(lower) and is_number(upper) ->
        {lower / 1, upper / 1}

      _no_travel ->
        nil
    end
  end

  @doc "The names of the actuated joints, base to tip."
  def joint_names(robot), do: Enum.map(joints(robot), & &1["name"])

  defp put_joints(changeset, attrs) do
    case attrs[:joints] || attrs["joints"] do
      nil ->
        changeset

      joints when is_list(joints) ->
        summary = Enum.map(joints, &normalise/1)

        changeset
        |> put_change(:joints, summary)
        |> put_change(:joints_json, IO.iodata_to_binary(:json.encode(summary)))

      _other ->
        add_error(changeset, :joints, "must be a list")
    end
  end

  defp normalise(joint) do
    get = fn key -> Map.get(joint, key) || Map.get(joint, to_string(key)) end

    %{
      "name" => get.(:name),
      "lower" => get.(:lower),
      "upper" => get.(:upper),
      "max_vel" => get.(:max_vel)
    }
  end
end
