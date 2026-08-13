defmodule EMotion.Job do
  @moduledoc """
  Work that must not happen in the UI process.

      Job.run(:ik, fn -> ExMove.IK.solve(chain, target) end)

      def handle_info({:job, :ik, ref, {:ok, solution}}, model) do
        # ...
      end

  ## The problem this exists for

  A `cedar` scene is a GenServer. It handles one event at a time, and
  `view/1` runs inside it. Anything slow that happens in `handle_event/2`
  freezes the entire window — not the panel, not the viewport, the window —
  because nothing else can be processed until it returns.

  In this application that is not a hypothetical. Every `ExMove.Robot`
  function is a `GenServer.call`, and `state/1` polls every drive over the
  fieldbus. Calling it from an event handler stalls the UI for as long as the
  bus takes, and against an unresponsive drive it stalls for the full call
  timeout and then kills the scene, taking the window with it.

  So the rule is absolute: **the scene process computes and renders, and does
  nothing else.** Loading a file, solving IK, planning a path, talking to
  hardware, parsing a mesh — all of it goes through here, and the answer
  arrives later as a message.

  ## Superseding

  Jobs are keyed. Starting a job under a key that already has one running
  cancels the old one first, which is what you want for anything driven by a
  human holding a control: dragging a jog target should not queue two hundred
  IK solves, it should run the one for where the mouse is now.

  Results carry the `ref` that `run/3` returned, so a receiver can also match
  explicitly. That matters because cancellation races: a task can send its
  reply in the instant between finishing and being killed, and a stale pose
  applied after a fresh one is a visible glitch.

  ## Failure

  A job that raises delivers `{:error, {:exception, reason}}` rather than
  taking the caller down with it. That is deliberate: a malformed STL or an IK
  solve that diverges is a normal condition in a tool that opens files people
  gave it, and the window should show a message rather than disappear.

  Jobs may also be given a `:timeout`, after which they are killed and deliver
  `{:error, :timeout}`. Anything touching hardware should set one.
  """

  use GenServer

  require Logger

  @type key :: term()
  @type result :: {:ok, term()} | {:error, term()}

  defstruct tasks: %{}, monitors: %{}

  # ==========================================================================
  # API
  # ==========================================================================

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` off the calling process.

  The caller receives `{:job, key, ref, result}` when it finishes. Any job
  already running under `key` for this caller is cancelled first.

  ## Options

    * `:timeout` - milliseconds before the job is killed, default `:infinity`
    * `:owner` - who to notify, default the calling process
  """
  @spec run(key(), (-> term()), keyword()) :: reference()
  def run(key, fun, opts \\ []) when is_function(fun, 0) do
    owner = Keyword.get(opts, :owner, self())
    timeout = Keyword.get(opts, :timeout, :infinity)
    ref = make_ref()

    GenServer.cast(__MODULE__, {:run, owner, key, ref, fun, timeout})

    ref
  end

  @doc """
  Cancels the job running under `key` for the calling process, if any.

  Silent when there is nothing to cancel, because "stop whatever you were
  doing" should not have to know whether anything was.
  """
  @spec cancel(key(), keyword()) :: :ok
  def cancel(key, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    GenServer.cast(__MODULE__, {:cancel, owner, key})
  end

  @doc "Whether a job is currently running under `key` for the calling process."
  @spec running?(key(), keyword()) :: boolean()
  def running?(key, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    GenServer.call(__MODULE__, {:running?, owner, key})
  end

  @doc """
  True when a received result is the one currently expected.

  Belt and braces alongside cancellation: a task can deliver in the instant
  between finishing and being killed, so a receiver that keeps the last `ref`
  per key can drop a straggler that cancellation did not catch.

      if Job.current?(model.ik_ref, ref), do: apply_solution(model, solution), else: model
  """
  @spec current?(reference() | nil, reference()) :: boolean()
  def current?(expected, received), do: expected == received

  # ==========================================================================
  # Server
  # ==========================================================================

  @impl true
  def init(:ok) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:run, owner, key, ref, fun, timeout}, state) do
    state = kill({owner, key}, state)

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            exception -> {:error, {:exception, Exception.message(exception)}}
          catch
            :exit, reason -> {:error, {:exit, reason}}
            thrown -> {:error, {:throw, thrown}}
          end

        send(owner, {:job, key, ref, result})
      end)

    timer =
      case timeout do
        :infinity -> nil
        ms -> Process.send_after(self(), {:timeout, {owner, key}, ref}, ms)
      end

    entry = %{pid: pid, monitor: monitor, ref: ref, owner: owner, key: key, timer: timer}

    {:noreply,
     %{
       state
       | tasks: Map.put(state.tasks, {owner, key}, entry),
         monitors: Map.put(state.monitors, monitor, {owner, key})
     }}
  end

  def handle_cast({:cancel, owner, key}, state) do
    {:noreply, kill({owner, key}, state)}
  end

  @impl true
  def handle_call({:running?, owner, key}, _from, state) do
    {:reply, Map.has_key?(state.tasks, {owner, key}), state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {id, monitors} ->
        {entry, tasks} = Map.pop(state.tasks, id)
        cancel_timer(entry)
        {:noreply, %{state | tasks: tasks, monitors: monitors}}
    end
  end

  def handle_info({:timeout, id, ref}, state) do
    case Map.fetch(state.tasks, id) do
      {:ok, %{ref: ^ref} = entry} ->
        # The owner is told, because a job that silently never answers is
        # worse than one that fails: the UI would sit disabled forever waiting
        # for a reply that is not coming.
        send(entry.owner, {:job, entry.key, ref, {:error, :timeout}})
        {:noreply, kill(id, state)}

      _already_finished_or_superseded ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ==========================================================================

  defp kill(id, state) do
    case Map.pop(state.tasks, id) do
      {nil, _tasks} ->
        state

      {entry, tasks} ->
        Process.demonitor(entry.monitor, [:flush])
        Process.exit(entry.pid, :kill)
        cancel_timer(entry)

        %{state | tasks: tasks, monitors: Map.delete(state.monitors, entry.monitor)}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)
end
