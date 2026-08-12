defmodule EMotion.Cell.Server do
  @moduledoc """
  Owns the live cell and tells subscribers when it changes.

      Cell.Server.subscribe()
      Cell.Server.change({:set_joints, :arm_a, positions})

      def handle_info({:cell, cell}, model), do: {:noreply, %{model | cell: cell}}

  ## Push, never pull

  A subscriber keeps its own replica and re-renders from it. Nothing in the UI
  ever calls in to ask for the current cell, and that is the point: a
  `GenServer.call` from the scene is a stall waiting for a slow moment, and
  under a document server that is also handling a large import it is a
  guaranteed one.

  The one exception is `snapshot/0` at subscribe time, to seed a replica. It
  is a call, it is made once, and it happens before a window is showing.

  ## Why the document is a process at all

  It could live in the scene's model. Making it a process buys three things:
  a second window can open onto the same cell without the two disagreeing;
  everything not in the GUI — an importer, a planner, a live telemetry feed —
  can propose changes without knowing a GUI exists; and the document survives
  a scene crash, so a rendering bug does not lose an afternoon of work.

  ## Changes are asynchronous

  `change/1` is a cast. A caller that needs to know whether an edit was
  accepted gets told the same way everyone else does — by receiving the new
  cell, or a `{:cell_error, reason}` if it was refused. Making it a call would
  reintroduce exactly the blocking this design exists to avoid, on the hot
  path of dragging a joint.
  """

  use GenServer

  alias EMotion.Cell

  require Logger

  defstruct cell: nil, subscribers: %{}

  # ==========================================================================
  # API
  # ==========================================================================

  @doc false
  def start_link(opts \\ []) do
    {cell, opts} = Keyword.pop(opts, :cell, Cell.new())
    GenServer.start_link(__MODULE__, cell, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes the calling process and returns the cell as it stands.

  The only synchronous read in this module. Call it once, keep the replica,
  and update it from `{:cell, cell}` messages.
  """
  @spec subscribe(GenServer.server()) :: Cell.t()
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Stops sending updates to the calling process."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.cast(server, {:unsubscribe, self()})
  end

  @doc """
  Proposes a change, or a list of them applied atomically.

  Asynchronous. Success arrives as a `{:cell, cell}` broadcast; refusal as
  `{:cell_error, reason}` to the caller alone, since a change one workbench
  got wrong is not news to the others.
  """
  @spec change(Cell.change() | [Cell.change()], GenServer.server()) :: :ok
  def change(change, server \\ __MODULE__) do
    GenServer.cast(server, {:change, self(), List.wrap(change)})
  end

  @doc """
  Replaces the whole cell — opening a file, or undoing to a checkpoint.

  Distinct from `change/2` because it is not an edit to be validated against
  what is there; it is a new document.
  """
  @spec replace(Cell.t(), GenServer.server()) :: :ok
  def replace(%Cell{} = cell, server \\ __MODULE__) do
    GenServer.cast(server, {:replace, cell})
  end

  @doc """
  The cell as it stands.

  For tests and for seeding. Not for rendering — see the module docs.
  """
  @spec snapshot(GenServer.server()) :: Cell.t()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  # ==========================================================================
  # Server
  # ==========================================================================

  @impl true
  def init(cell) do
    {:ok, %__MODULE__{cell: cell}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    # Monitored rather than linked: a subscriber crashing is a normal event
    # for a document that outlives its windows, and must not take the
    # document with it.
    monitor = Process.monitor(pid)

    {:reply, state.cell, %{state | subscribers: Map.put(state.subscribers, pid, monitor)}}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.cell, state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, drop(state, pid)}
  end

  def handle_cast({:change, from, changes}, state) do
    case Cell.apply_changes(state.cell, changes) do
      {:ok, cell} ->
        broadcast(state, cell)
        {:noreply, %{state | cell: cell}}

      {:error, reason} ->
        Logger.warning("Cell: refused #{inspect(changes)}: #{inspect(reason)}")
        send(from, {:cell_error, reason})
        {:noreply, state}
    end
  end

  def handle_cast({:replace, cell}, state) do
    broadcast(state, cell)
    {:noreply, %{state | cell: cell}}
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {:noreply, drop(state, pid)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ==========================================================================

  defp broadcast(state, cell) do
    Enum.each(Map.keys(state.subscribers), fn pid -> send(pid, {:cell, cell}) end)
  end

  defp drop(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers}
    end
  end
end
