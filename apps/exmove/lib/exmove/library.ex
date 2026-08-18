defmodule ExMove.Library do
  @moduledoc """
  A chain in code, for tests.

  This used to be where the controller and the Studio both got the arm from,
  and its own docstring said it would go away when the URDF loader landed. It
  has: the controller reads a URDF the machine was commissioned with, through
  `ExMo.Cell.Loaded`.

  What is left is a fixture. A chain built in code cannot fail to parse, which
  is exactly what you want underneath a test of something else — a Jacobian, a
  limit, a viewport — and exactly what you do not want underneath a machine,
  where the arm's dimensions should be a thing somebody measured rather than a
  thing somebody typed.

  Nothing on the controller path calls this. If something starts to, that is
  the third description growing back.
  """

  alias ExMove.{Chain, Joint}

  @doc "Every chain this build carries, by name."
  @spec all() :: %{atom() => Chain.t()}
  def all, do: %{demo: demo()}

  @doc """
  A six-axis arm, dimensioned in metres like everything else.

  Roughly the proportions of a small industrial arm: a shoulder, a long upper
  arm, a forearm, and a three-axis wrist. Invented, and deliberately not the
  Arctos — a fixture that happened to match a real machine would be a fourth
  description of it, and the point of a fixture is that nothing depends on the
  numbers being true.
  """
  @spec demo() :: Chain.t()
  def demo do
    %Chain{
      name: :demo,
      axis_ids: [:j1, :j2, :j3, :j4, :j5, :j6],
      joints: [
        joint(:j1, "shoulder_pan", {0.0, 0.20, 0.0}, {0.0, 1.0, 0.0}),
        joint(:j2, "shoulder_lift", {0.0, 0.12, 0.0}, {1.0, 0.0, 0.0}),
        joint(:j3, "elbow", {0.0, 0.42, 0.0}, {1.0, 0.0, 0.0}),
        joint(:j4, "wrist_1", {0.0, 0.36, 0.0}, {0.0, 1.0, 0.0}),
        joint(:j5, "wrist_2", {0.0, 0.10, 0.0}, {1.0, 0.0, 0.0}),
        joint(:j6, "wrist_3", {0.0, 0.08, 0.0}, {0.0, 1.0, 0.0})
      ]
    }
  end

  defp joint(id, name, origin, axis) do
    %Joint{
      id: id,
      name: name,
      type: :revolute,
      axis: axis,
      origin: origin,
      rpy: {0.0, 0.0, 0.0},
      limit: {-3.05, 3.05}
    }
  end
end
