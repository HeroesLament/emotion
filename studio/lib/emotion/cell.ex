defmodule EMotion.Cell do
  @moduledoc """
  The document: a robot cell, as data.

  Robots, the frames they work in, and the fixtures around them. Every
  workbench is a different view onto this one structure, which is the whole
  reason workbenches beat separate applications — the welding bench and the
  scanning bench are looking at the same cell, not exporting between two.

  Pure. No processes, no side effects, nothing that can block. `EMotion.Cell.Server`
  owns the live one and broadcasts changes; this module is what it owns.

  ## Changes rather than setters

  Edits are described as data and applied through `apply_change/2`:

      Cell.apply_change(cell, {:set_joints, :arm_a, [0.0, -0.5, 1.2, 0.0, 0.5, 0.0]})

  That indirection buys three things a pile of setters would not: undo becomes
  a list of changes rather than snapshots of a growing document, a workbench
  can return changes without holding the cell, and every edit funnels through
  one place where it can be validated against joint limits before it reaches a
  machine.

  ## Units

  Canonical SI throughout, per `EMotion.Units`. Joint positions are radians for
  revolute and metres for prismatic, matching `ExMove.Joint` exactly, so
  handing a pose to `ExMove` is never a conversion.
  """

  alias EMotion.Cell.Robot

  @type change ::
          {:add_robot, Robot.t()}
          | {:remove_robot, atom()}
          | {:set_joints, atom(), [float()]}
          | {:set_base, atom(), EMotion.Cell.transform()}
          | {:put_frame, atom(), EMotion.Cell.transform()}
          | {:remove_frame, atom()}
          | {:rename, String.t()}

  @typedoc """
  A pose: position in metres and orientation as roll-pitch-yaw in radians.

  Deliberately the same shape as `ExMove.Frame`, and convertible to it without
  arithmetic.
  """
  @type transform :: %{x: float(), y: float(), z: float(), rx: float(), ry: float(), rz: float()}

  @type t :: %__MODULE__{
          name: String.t(),
          robots: %{atom() => Robot.t()},
          frames: %{atom() => transform()},
          version: non_neg_integer()
        }

  defstruct name: "Untitled cell",
            robots: %{},
            frames: %{},
            version: 0

  defmodule Robot do
    @moduledoc """
    One arm in the cell.

    `chain` is an `ExMove.Chain` — the studio does not model kinematics, it
    displays what `ExMove` already knows. `joints` is the pose being shown,
    which is not necessarily the pose the hardware is in: a cell open for
    offline programming has no hardware at all.
    """

    @type t :: %__MODULE__{
            id: atom(),
            name: String.t(),
            chain: term(),
            base: EMotion.Cell.transform(),
            joints: [float()]
          }

    @enforce_keys [:id, :name]
    defstruct [:id, :name, :chain, base: nil, joints: []]
  end

  @doc "The identity pose."
  @spec origin() :: transform()
  def origin, do: %{x: 0.0, y: 0.0, z: 0.0, rx: 0.0, ry: 0.0, rz: 0.0}

  @doc "An empty cell."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{name: Keyword.get(opts, :name, "Untitled cell")}
  end

  @doc """
  Applies one change.

  Returns `{:ok, cell}` with the version bumped, or `{:error, reason}` for a
  change that does not make sense against this cell — moving a robot that is
  not here, or a pose with the wrong number of joints. Those are refused
  rather than absorbed, because a joint list of the wrong length reaching
  forward kinematics produces a plausible wrong answer instead of an error.
  """
  @spec apply_change(t(), change()) :: {:ok, t()} | {:error, term()}
  def apply_change(%__MODULE__{} = cell, change) do
    case change(cell, change) do
      {:ok, updated} -> {:ok, %{updated | version: cell.version + 1}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies changes in order, stopping at the first failure.

  All or nothing: a failed change leaves the original cell untouched rather
  than half-applied, so a workbench returning three related edits cannot leave
  the document inconsistent.
  """
  @spec apply_changes(t(), [change()]) :: {:ok, t()} | {:error, term()}
  def apply_changes(%__MODULE__{} = cell, changes) when is_list(changes) do
    Enum.reduce_while(changes, {:ok, cell}, fn change, {:ok, acc} ->
      case apply_change(acc, change) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "A robot by id."
  @spec robot(t(), atom()) :: {:ok, Robot.t()} | :error
  def robot(%__MODULE__{robots: robots}, id), do: Map.fetch(robots, id)

  @doc "Every robot, in a stable order."
  @spec robots(t()) :: [Robot.t()]
  def robots(%__MODULE__{robots: robots}) do
    robots |> Map.values() |> Enum.sort_by(& &1.id)
  end

  # ==========================================================================

  defp change(cell, {:rename, name}) when is_binary(name) do
    {:ok, %{cell | name: name}}
  end

  defp change(cell, {:add_robot, %Robot{} = robot}) do
    if Map.has_key?(cell.robots, robot.id) do
      {:error, {:duplicate_robot, robot.id}}
    else
      robot = %{robot | base: robot.base || origin()}
      {:ok, %{cell | robots: Map.put(cell.robots, robot.id, robot)}}
    end
  end

  defp change(cell, {:remove_robot, id}) do
    with_robot(cell, id, fn _robot ->
      {:ok, %{cell | robots: Map.delete(cell.robots, id)}}
    end)
  end

  defp change(cell, {:set_joints, id, positions}) when is_list(positions) do
    with_robot(cell, id, fn robot ->
      expected = length(robot.joints)

      cond do
        expected != 0 and length(positions) != expected ->
          {:error, {:wrong_joint_count, id, expected, length(positions)}}

        not Enum.all?(positions, &is_number/1) ->
          {:error, {:not_numbers, id}}

        true ->
          updated = %{robot | joints: Enum.map(positions, &(&1 * 1.0))}
          {:ok, %{cell | robots: Map.put(cell.robots, id, updated)}}
      end
    end)
  end

  defp change(cell, {:set_base, id, transform}) do
    with_robot(cell, id, fn robot ->
      {:ok, %{cell | robots: Map.put(cell.robots, id, %{robot | base: transform})}}
    end)
  end

  defp change(cell, {:put_frame, name, transform}) when is_atom(name) do
    {:ok, %{cell | frames: Map.put(cell.frames, name, transform)}}
  end

  defp change(cell, {:remove_frame, name}) when is_atom(name) do
    {:ok, %{cell | frames: Map.delete(cell.frames, name)}}
  end

  defp change(_cell, other), do: {:error, {:unknown_change, other}}

  defp with_robot(cell, id, fun) do
    case Map.fetch(cell.robots, id) do
      {:ok, robot} -> fun.(robot)
      :error -> {:error, {:no_such_robot, id}}
    end
  end
end
