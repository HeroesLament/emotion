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
  alias ExMove.Chain

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
  The arm this Studio opens onto.

  The chain itself lives in `ExMove.Library`, which is the one place both this
  and the controller can reach. Two copies of a machine's kinematics agree
  right up until somebody edits one, and what fails then is a tool centre point
  that reads plausibly and is wrong.
  """
  @spec demo_chain() :: Chain.t()
  defdelegate demo_chain, to: ExMove.Library, as: :demo

  # ==========================================================================


  defp load_library do
    # Where URDF discovery will go. For now the library is the one chain we
    # can build without a parser.
    ExMove.Library.all()
  end

  defp probe_controller do
    # No controller on the bench. Returning rather than raising, because an
    # absent controller is the normal case for offline programming and the
    # studio must open regardless - Boot records it either way.
    {:offline, "no controller configured"}
  end
end
