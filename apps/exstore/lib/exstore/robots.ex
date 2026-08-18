defmodule ExStore.Robots do
  @moduledoc """
  Stored robot descriptions, and the commissioning beside them.

  Two things this module refuses, and both are the point of it existing rather
  than the callers writing these queries themselves:

    * a commissioning row for a joint the robot does not have — which is what
      happens when somebody re-exports a CAD file with a joint renamed, and is
      exactly the quiet failure `ROBOT.md` opens with;
    * a soft limit outside the mechanical travel. A soft limit wider than the
      metal is not a permission, it is a typo, and the only place to catch it is
      before the arm is moving.
  """

  import Ecto.Query

  alias ExStore.Cell.{JointSetting, Robot}
  alias ExStore.Repo

  @doc """
  Stores a robot description, replacing one of the same name.

  `attrs` needs `:name`, `:urdf` and `:joints` — the last being the parsed
  summary, `[%{name:, lower:, upper:, max_vel:}]`, base to tip. This app does
  not parse XML (see `ExStore.Cell.Robot`), so the caller has already read the
  document and is handing over what it said.

  Re-storing keeps the commissioning rows. That is the whole reason they are a
  separate table keyed by joint name: re-exporting a drawing must not lose
  which drive is joint 3.
  """
  def store(attrs) do
    name = attrs[:name] || attrs["name"]

    case by_name(name) do
      nil -> %Robot{} |> Robot.changeset(attrs) |> Repo.insert()
      robot -> robot |> Robot.changeset(attrs) |> Repo.update()
    end
  end

  def list, do: Repo.all(from(r in Robot, order_by: r.name))

  def get(id), do: Repo.get(Robot, id)

  def by_name(nil), do: nil
  def by_name(name) when is_binary(name), do: Repo.get_by(Robot, name: name)
  def by_name(name) when is_atom(name), do: by_name(Atom.to_string(name))

  @doc """
  The robot this controller is, or `nil`.

  `nil` is a real answer: a controller with no robot loaded is one nobody has
  commissioned yet, and it should say so rather than pretend to be something.
  """
  def active, do: Repo.one(from(r in Robot, where: r.active == true))

  @doc """
  Makes this the robot the controller is.

  Unlike fitting a tool, this does not take effect until the controller
  restarts — the Information Model is built once at boot and the axis nodes
  come from the loaded chain, so changing the robot changes the shape of the
  address space. `ROBOT.md` argues why that is the rule rather than a
  limitation.
  """
  def activate(%Robot{} = robot) do
    Repo.transaction(fn ->
      Repo.update_all(from(r in Robot, where: r.active == true and r.id != ^robot.id),
        set: [active: false]
      )

      case Repo.update(Robot.activate_changeset(robot, true)) do
        {:ok, active} -> active
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def activate(name) when is_binary(name) do
    case by_name(name) do
      nil -> {:error, :unknown_robot}
      robot -> activate(robot)
    end
  end

  def delete(%Robot{} = robot), do: Repo.delete(robot)

  # ── Commissioning ─────────────────────────────────────────────────────────

  @doc "Every commissioning row for this robot, in the chain's own order."
  def settings(%Robot{} = robot) do
    order = Robot.joint_names(robot)
    rows = Repo.all(from(s in JointSetting, where: s.robot_id == ^robot.id))

    Enum.sort_by(rows, fn row ->
      case Enum.find_index(order, &(&1 == row.joint_name)) do
        nil -> length(order)
        index -> index
      end
    end)
  end

  def setting(%Robot{} = robot, joint_name) do
    Repo.get_by(JointSetting, robot_id: robot.id, joint_name: joint_name)
  end

  @doc """
  Records what commissioning says about one joint, replacing what it said before.

  Refused when the joint is not one the robot has, or when a soft limit falls
  outside the mechanical travel the document declares.
  """
  def commission(%Robot{} = robot, joint_name, attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{"robot_id" => robot.id, "joint_name" => joint_name})

    existing = setting(robot, joint_name) || %JointSetting{}

    existing
    |> JointSetting.changeset(attrs)
    |> validate_joint_exists(robot, joint_name)
    |> validate_within_travel(robot, joint_name)
    |> Repo.insert_or_update()
  end

  def decommission(%JointSetting{} = setting), do: Repo.delete(setting)

  @doc """
  The drives this robot's joints are wired to, base to tip.

  `nil` for a joint nobody has wired yet, so the list is always the length of
  the chain — a shorter one would line up wrongly against the joints and put
  the wrong number on the wrong axis.
  """
  def axis_ids(%Robot{} = robot) do
    by_joint = Map.new(settings(robot), &{&1.joint_name, &1.axis_id})

    Enum.map(Robot.joint_names(robot), fn name ->
      case Map.get(by_joint, name) do
        nil -> nil
        axis_id -> String.to_atom(axis_id)
      end
    end)
  end

  defp validate_joint_exists(changeset, robot, joint_name) do
    names = Robot.joint_names(robot)

    if joint_name in names do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :joint_name,
        "is not a joint of #{robot.name}; it has " <> Enum.join(names, ", ")
      )
    end
  end

  defp validate_within_travel(changeset, robot, joint_name) do
    case Robot.travel(robot, joint_name) do
      nil ->
        # A continuous joint has no mechanical travel to be inside of, so a soft
        # limit on one is the only thing stopping it, and it is allowed.
        changeset

      {lower, upper} ->
        changeset
        |> outside(:soft_lower, lower, upper)
        |> outside(:soft_upper, lower, upper)
    end
  end

  defp outside(changeset, field, lower, upper) do
    case Ecto.Changeset.get_field(changeset, field) do
      nil ->
        changeset

      value when value < lower or value > upper ->
        Ecto.Changeset.add_error(
          changeset,
          field,
          "is outside the mechanical travel #{lower}..#{upper}"
        )

      _inside ->
        changeset
    end
  end
end
