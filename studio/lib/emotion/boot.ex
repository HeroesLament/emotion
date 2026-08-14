defmodule EMotion.Boot do
  @moduledoc """
  Startup, as something the interface can show honestly.

      EMotion.Boot.start_link(steps: [
        {"Workbenches", fn -> Registry.refresh() end},
        {"Robot library", fn -> load_library() end},
        {"Controller", fn -> Link.probe() end}
      ])

      EMotion.Boot.subscribe()

      def handle_info({:boot, progress}, model), do: ...

  ## Why this is a process and not a function

  A splash screen exists to cover slow startup. On most desktop toolkits it is
  theatre: the work happens on the UI thread anyway, so the progress bar is
  either a lie or a series of forced repaints between blocking calls.

  Here the steps genuinely run off the UI process, through `EMotion.Job`, and
  concurrently with each other. A controller that takes four seconds to answer
  does not hold up loading the robot library, and the splash shows what has
  actually finished rather than a timer pretending to be one.

  ## Steps are independent by construction

  Every step runs at once. There is no dependency ordering, and that is a
  deliberate constraint rather than an omission — a step that needs another
  step's output is really one step, and expressing it as two invites a race
  that only shows up on a slow machine. If ordering is genuinely needed, do the
  sequencing inside a single step's function where it is visible.

  ## Failure does not stop the boot

  A step that raises is recorded as failed and the rest carry on, because most
  startup work is not load-bearing: an unreachable controller should open the
  studio with a disconnected indicator, not refuse to open it. `failures/1`
  reports what did not work so the shell can say so.
  """

  use GenServer

  alias EMotion.Job

  require Logger

  @type step :: {String.t(), (-> term())}

  @type progress :: %{
          total: non_neg_integer(),
          done: non_neg_integer(),
          running: [String.t()],
          failed: [{String.t(), term()}],
          results: %{String.t() => term()},
          complete?: boolean()
        }

  defstruct steps: [],
            running: %{},
            results: %{},
            failed: [],
            total: 0,
            subscribers: %{},
            timeout: 15_000

  # ==========================================================================
  # API
  # ==========================================================================

  @doc false
  def start_link(opts \\ []) do
    {steps, opts} = Keyword.pop(opts, :steps, [])
    {timeout, opts} = Keyword.pop(opts, :timeout, 15_000)

    GenServer.start_link(
      __MODULE__,
      {steps, timeout},
      Keyword.put_new(opts, :name, __MODULE__)
    )
  end

  @doc """
  Subscribes the caller and returns the progress so far.

  Same shape as `Cedar.Cell.Server`: one synchronous read to seed a replica,
  then pushed updates. A scene that polled this would be polling the thing it
  is drawing.
  """
  @spec subscribe(GenServer.server()) :: progress()
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Progress as it stands."
  @spec progress(GenServer.server()) :: progress()
  def progress(server \\ __MODULE__) do
    GenServer.call(server, :progress)
  end

  @doc """
  Starts the steps.

  Separate from `start_link/1` so a supervision tree can bring the process up
  before anything is ready to run, and so tests can drive it deterministically.
  """
  @spec run(GenServer.server()) :: :ok
  def run(server \\ __MODULE__) do
    GenServer.cast(server, :run)
  end

  @doc "Whether every step has finished, successfully or not."
  @spec complete?(progress()) :: boolean()
  def complete?(%{complete?: complete}), do: complete

  @doc "What failed, as `{step, reason}`."
  @spec failures(progress()) :: [{String.t(), term()}]
  def failures(%{failed: failed}), do: failed

  @doc """
  A one-line summary for a status label.

  Names what is still running rather than what just finished, because the
  interesting question during a slow boot is what everyone is waiting for.
  """
  @spec status(progress()) :: String.t()
  def status(%{complete?: true, failed: []}), do: "Ready"
  def status(%{complete?: true, failed: failed}), do: "Ready — #{length(failed)} step(s) failed"
  def status(%{running: []}), do: "Starting…"
  def status(%{running: [one]}), do: "#{one}…"
  def status(%{running: many}), do: "#{Enum.join(Enum.take(many, 2), ", ")}…"

  # ==========================================================================
  # Server
  # ==========================================================================

  @impl true
  def init({steps, timeout}) do
    {:ok, %__MODULE__{steps: steps, total: length(steps), timeout: timeout}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    monitor = Process.monitor(pid)
    {:reply, snapshot(state), %{state | subscribers: Map.put(state.subscribers, pid, monitor)}}
  end

  def handle_call(:progress, _from, state) do
    {:reply, snapshot(state), state}
  end

  @impl true
  def handle_cast(:run, state) do
    # All at once. See the moduledoc on why there is no ordering.
    running =
      Map.new(state.steps, fn {label, fun} ->
        Job.run({:boot, label}, fun, timeout: state.timeout)
        {label, true}
      end)

    state = %{state | running: running}
    broadcast(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:job, {:boot, label}, _ref, result}, state) do
    state =
      case result do
        {:ok, value} ->
          %{
            state
            | running: Map.delete(state.running, label),
              results: Map.put(state.results, label, value)
          }

        {:error, reason} ->
          Logger.warning("Boot: #{label} failed: #{inspect(reason)}")

          %{
            state
            | running: Map.delete(state.running, label),
              failed: state.failed ++ [{label, reason}]
          }
      end

    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ==========================================================================

  defp snapshot(state) do
    done = map_size(state.results) + length(state.failed)

    %{
      total: state.total,
      done: done,
      running: state.running |> Map.keys() |> Enum.sort(),
      failed: state.failed,
      results: state.results,
      complete?: state.total > 0 and done >= state.total
    }
  end

  defp broadcast(state) do
    progress = snapshot(state)
    Enum.each(Map.keys(state.subscribers), &send(&1, {:boot, progress}))
  end
end
