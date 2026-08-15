defmodule ExMove.Library do
  @moduledoc """
  Kinematic chains this build knows about, by name.

  A chain is machine configuration and a library is an odd place to keep it.
  It is here because it is the only place both consumers can reach: the Studio
  path-depends on `exmove` and deliberately not on `exhmi` — a desktop
  application should not have to ship an OPC UA server and a database in order
  to draw an arm — and the controller reaches it through `exhmi`, which builds
  the Information Model from the same description.

  The alternative was a copy on each side, and a second description of a
  machine's kinematics is one that agrees with the first right up until
  somebody edits one of them. When the arm's forearm is 20mm longer than the
  controller believes it is, what fails is a tool centre point that reads
  plausibly and is wrong.

  This goes away when the URDF loader lands and a chain is something a machine
  is configured with rather than something a build is compiled with.
  """

  alias ExMove.{Chain, Joint}

  @doc "Every chain this build carries, by name."
  @spec all() :: %{atom() => Chain.t()}
  def all, do: %{demo: demo()}

  @doc """
  A six-axis arm, dimensioned in metres like everything else.

  Roughly the proportions of a small industrial arm: a shoulder, a long upper
  arm, a forearm, and a three-axis wrist. Built in code rather than loaded from
  a URDF because the loader is not written yet, and because a chain that cannot
  fail to parse is a better thing to be looking at while the viewport is the
  part under test.
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
