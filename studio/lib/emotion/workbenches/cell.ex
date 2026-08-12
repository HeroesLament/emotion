defmodule EMotion.Workbenches.Cell do
  @moduledoc """
  The built-in workbench: what is in the cell and where it is.

  Every FreeCAD-alike needs one bench that is always present and assumes
  nothing about the job — somewhere to load a robot, place it, and jog it
  before any specialised bench has an opinion. This is that.

  It is also the reference implementation. A third-party bench can be read off
  this one, and because it ships inside the studio's own application it is the
  thing the registry's discovery is proven against in the tests.
  """

  @behaviour EMotion.Workbench

  alias EMotion.Cell
  alias EMotion.Workbench.Command

  @impl true
  def name, do: "Cell"

  @impl true
  def description, do: "Load, place and jog the machines in this cell"

  @impl true
  def init(%Cell{} = cell) do
    {:ok, %{selected: first_robot(cell)}}
  end

  @impl true
  def commands do
    [
      %Command{
        id: :add_robot,
        label: "Add Robot",
        group: :cell,
        description: "Load a robot from a URDF"
      },
      %Command{
        id: :remove_robot,
        label: "Remove",
        group: :cell,
        enabled?: &selected?/1
      },
      %Command{
        id: :home,
        label: "Home",
        group: :jog,
        description: "Move the selected robot to its zero pose",
        enabled?: &selected?/1
      }
    ]
  end

  @impl true
  def handle_event({:command, :home}, %{selected: nil} = state, _context) do
    {:ok, state}
  end

  def handle_event({:command, :home}, %{selected: id} = state, context) do
    case Cell.robot(context.cell, id) do
      {:ok, robot} ->
        zeros = List.duplicate(0.0, length(robot.joints))
        {:ok, state, [{:set_joints, id, zeros}]}

      :error ->
        # The robot went away between the click and the handler. Not an error
        # worth surfacing; the selection is simply stale.
        {:ok, %{state | selected: nil}}
    end
  end

  def handle_event({:select, id}, state, _context) do
    {:ok, %{state | selected: id}}
  end

  def handle_event(_event, state, _context), do: {:ok, state}

  @impl true
  def view(_state, _context) do
    # The shell that renders this does not exist yet. Returning nothing is
    # honest; returning a stub panel would be a thing to delete later.
    []
  end

  # ==========================================================================

  defp selected?(%{cell: %Cell{} = cell}), do: first_robot(cell) != nil
  defp selected?(_context), do: false

  defp first_robot(%Cell{} = cell) do
    case Cell.robots(cell) do
      [robot | _rest] -> robot.id
      [] -> nil
    end
  end
end
