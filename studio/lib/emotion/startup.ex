defmodule EMotion.Startup do
  @moduledoc """
  What the studio does before it can show you anything.

  Kept separate from the shell so the steps are readable as a list rather than
  buried in a scene, and so a test can run them without a window.

  Every step here is real work. None of them sleep to make the splash look
  busy — see `EMotion.Boot` for why a fake progress bar is worse than no
  progress bar.
  """

  alias EMotion.{Cell, Workbench}
  alias ExMove.{Chain, Joint}

  @doc """
  The boot sequence.

  Run concurrently, so the order here is presentation only.
  """
  @spec steps() :: [{String.t(), (-> term())}]
  def steps do
    [
      {"Workbenches", &Workbench.Registry.refresh/0},
      {"Robot library", &load_library/0},
      {"Controller", &probe_controller/0}
    ]
  end

  @doc """
  A cell to open with.

  Until there is a file format and a start page, the studio opens onto a demo
  arm rather than an empty void — an empty 3D viewport gives a new user no way
  to tell "working but nothing loaded" from "broken".
  """
  @spec demo_cell() :: Cell.t()
  def demo_cell do
    robot = %Cell.Robot{
      id: :arm_a,
      name: "Demo arm",
      chain: demo_chain(),
      base: Cell.origin(),
      joints: [0.0, -0.35, 0.7, 0.0, 0.5, 0.0]
    }

    {:ok, cell} =
      Cell.new(name: "Demo cell")
      |> Cell.apply_change({:add_robot, robot})

    cell
  end

  @doc """
  A six-axis arm, dimensioned in metres like everything else.

  Roughly the proportions of a small industrial arm: a shoulder, a long upper
  arm, a forearm, and a three-axis wrist. Built in code rather than loaded from
  a URDF because the loader is not written yet, and because a chain that cannot
  fail to parse is a better thing to be looking at while the viewport is the
  part under test.
  """
  @spec demo_chain() :: Chain.t()
  def demo_chain do
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

  # ==========================================================================

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

  defp load_library do
    # Where URDF discovery will go. For now the library is the one chain we
    # can build without a parser.
    %{demo: demo_chain()}
  end

  defp probe_controller do
    # No controller on the bench. Returning rather than raising, because an
    # absent controller is the normal case for offline programming and the
    # studio must open regardless - Boot records it either way.
    {:offline, "no controller configured"}
  end
end
