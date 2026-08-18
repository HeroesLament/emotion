defmodule ExStore.Cell.Point do
  @moduledoc """
  A place the arm was driven to, and everything needed to send it back.

  Four things, and the argument for each is in `PROGRAMS.md` §3:

    * **a pose**, expressed in the frame it was taught in, so re-teaching the
      frame moves the point;
    * **the frame**, because a pose without one is six numbers relative to
      something the operator has forgotten;
    * **the tool that was fitted**, because a pose taught with one tool does
      not describe the same physical location with another;
    * **the joint solution the arm was actually in**, because a pose can be
      reachable two ways and the difference between them is a collision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ExStore.Geometry.Pose

  schema "points" do
    field :name, :string
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    field :z, :float, default: 0.0
    field :rx, :float, default: 0.0
    field :ry, :float, default: 0.0
    field :rz, :float, default: 0.0
    field :mutable, :boolean, default: false

    field :joints, {:array, :float}, virtual: true
    field :joints_json, :string, source: :joints

    belongs_to :frame, ExStore.Geometry.Frame
    belongs_to :tool, ExStore.Geometry.Tool
    belongs_to :robot, ExStore.Cell.Robot

    timestamps()
  end

  # `base` and `tool` are not frame names and never will be, and a point is not
  # allowed to be called after one either — a program reading `move_linear to
  # base` would be ambiguous in a way no amount of documentation fixes.
  @reserved ~w(base tool here home)

  def changeset(point, attrs) do
    point
    |> Pose.cast_name(attrs, @reserved)
    |> Pose.cast_pose(attrs)
    |> cast(attrs, [:frame_id, :tool_id, :robot_id, :mutable])
    |> put_joints(attrs)
    |> validate_required([:robot_id])
    |> unique_constraint(:name)
    |> foreign_key_constraint(:frame_id)
    |> foreign_key_constraint(:tool_id)
    |> foreign_key_constraint(:robot_id)
  end

  @doc "The taught joint solution. `[]` never happens on a stored row."
  def joints(%__MODULE__{joints: joints}) when is_list(joints), do: joints

  def joints(%__MODULE__{joints_json: nil}), do: []

  def joints(%__MODULE__{joints_json: json}) do
    case :json.decode(json) do
      list when is_list(list) -> Enum.map(list, &(&1 / 1))
      _other -> []
    end
  rescue
    _error -> []
  end

  defp put_joints(changeset, attrs) do
    case attrs[:joints] || attrs["joints"] do
      nil ->
        if get_field(changeset, :joints_json) do
          changeset
        else
          add_error(changeset, :joints, "is required: a point without one cannot be replayed safely")
        end

      joints when is_list(joints) ->
        if Enum.all?(joints, &is_number/1) do
          floats = Enum.map(joints, &(&1 / 1))

          changeset
          |> put_change(:joints, floats)
          |> put_change(:joints_json, IO.iodata_to_binary(:json.encode(floats)))
        else
          add_error(changeset, :joints, "must be numbers")
        end

      _other ->
        add_error(changeset, :joints, "must be a list of joint positions")
    end
  end
end
