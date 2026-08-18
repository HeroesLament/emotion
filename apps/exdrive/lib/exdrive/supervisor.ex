defmodule Exdrive.Supervisor do
  @moduledoc """
  Supervises all Drive processes. Each axis is an independent gen_statem.
  A fault on one axis does not restart others.

  `:rest_for_one` rather than `:one_for_one` for exactly one reason: the first
  child is `Exdrive.Flash`, which owns what survives a drive restart. If it
  goes, every drive above it is holding a position no longer backed by
  anything, and coming back up unmastered is the honest outcome. Drives are
  started dynamically after it, so nothing else is disturbed by the ordering.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Dynamically start a new drive axis"
  def start_drive(opts) do
    Supervisor.start_child(__MODULE__, {Exdrive.Drive, opts})
  end

  @doc "List all running axis IDs"
  def axes do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @impl true
  def init(_opts) do
    # Flash first, and it is not a drive: it holds what survives a drive
    # restart, so it must outlive every child it serves. See Exdrive.Flash.
    Supervisor.init([Exdrive.Flash], strategy: :rest_for_one)
  end
end
