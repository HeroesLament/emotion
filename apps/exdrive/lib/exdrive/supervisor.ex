defmodule Exdrive.Supervisor do
  @moduledoc """
  Supervises all Drive processes. Each axis is an independent gen_statem.
  A fault on one axis does not restart others — :one_for_one strategy.
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
    Supervisor.init([], strategy: :one_for_one)
  end
end
