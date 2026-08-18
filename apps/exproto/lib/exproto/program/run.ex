defmodule ExProto.Program.Run do
  @moduledoc """
  Runs one stored program, and is the reason this is a controller rather than a
  motion library.

  `PROGRAMS.md` §5 is the design; this is the engine. The parts worth knowing
  from the outside:

  ## Nothing about a run depends on a client

  It is started by a call and then it is on its own. The client that started it
  may disconnect, close its laptop, or crash, and the program finishes. That is
  the property that distinguishes a stored program from a document, and it has
  its own test.

  ## Look-ahead stops at anything that is not motion

  Motion statements are pushed into the Cartesian queue ahead of the arm, which
  is what makes blending between consecutive moves work at all. Everything else
  is a barrier: the interpreter waits until the arm has arrived and the queue is
  empty before running it. So `wait 2 seconds` means the arm stands still for two
  seconds, rather than two seconds beginning somewhere earlier — which is the
  only reading of that statement nobody has to be taught.

  ## Its death is a stop

  A monitoring process outlives the run and releases the stream when it goes
  away, which commands zero on every joint. Not `terminate/2`: that callback
  does not run when a process is killed, and "the arm stops when the run dies"
  is exactly the guarantee that has to survive the ugliest death.
  """

  # A bounded shutdown, and it is bounded because it can be. The arm's stop does
  # not live in this process — see `watch_for_death/1` — so a run that is slow to
  # answer may be killed without consequence. A run whose shutdown had to be
  # trusted would be a run that could hang a controller restart.
  use GenServer, shutdown: 1_000

  require Logger

  alias ExMo.Cell
  alias ExMo.Program.Kinds
  alias ExMove.{CartesianStream, JointState}
  alias ExProto.Mode
  alias ExStore.Program.{Statement, StatementRef}
  alias ExStore.{Points, Programs}

  # How many motion statements may be in the queue at once. Two is enough for
  # blending — a move and the one it gives way to — and small enough that a hold
  # abandons very little work. A deeper queue buys nothing until there is
  # look-ahead worth doing across more than a corner.
  @lookahead 2

  # How often the interpreter looks again when it is waiting for the arm. The
  # stream does not announce arrival, so this polls; 20 ms is far below human
  # perception and far above the cost of a `GenServer.call`. When the stream
  # grows a subscription this becomes a message and this constant goes away.
  @poll_ms 20

  # A joint move is done when every joint is within this of its target. The
  # drives follow exponentially, so "exactly" never arrives.
  @joint_tolerance 1.0e-3

  # Programs run in auto, and auto's tool speed cap is the one in
  # `ExProto.Source.Exdrive`. Stated here rather than read from there because a
  # run is not a jog and should not inherit a jog's number by accident.
  @auto_tool_velocity 1.0

  defstruct [
    :mode,
    :program,
    :body,
    :index,
    :status,
    :reason,
    # Captured when the run starts and never re-read. The chain cannot change
    # while a controller is up — loading a robot is a restart, by design — and
    # reading it per poll meant a SQLite query and six drive calls every 20 ms
    # inside the interpreter's own loop. That is how a program engine acquires a
    # mysterious stall, and it made this file's shutdown flaky before it made
    # anything else fail.
    :chain,
    # True while a joint move is outstanding. Cartesian motion is answered by
    # the stream's own status; joint moves are not, and are the only reason to
    # go and read where the arm is.
    settling?: false,
    # The statements whose motion is in the queue but has not finished, oldest
    # first. This is the second pointer — the interpreter's `index` has already
    # moved past them, which is what look-ahead means — and it is the one a
    # pendant highlights and a hold rewinds to, because it is where the arm is.
    in_flight: []
  ]

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts a program by name.

  Refused when one is already running, when the mode selector is not in auto,
  when the program has no statements, or when a statement references a kind this
  build does not know — that last one being why an unloaded extension makes a
  program *refuse to start* rather than fail halfway down it.
  """
  def start(program_name, server \\ __MODULE__) do
    GenServer.call(server, {:start, program_name})
  end

  @doc "Stops the arm where it is. Resumable."
  def hold(server \\ __MODULE__), do: GenServer.call(server, :hold)

  @doc """
  Re-issues the statement the run was on, from wherever the arm is standing.

  Exact for a linear move — the target is absolute and resolved-rate motion is
  differential, so the remainder of the line is the same line. Refused during an
  arc, whose via point may be behind the arm: a circle recomputed through a via
  already passed is a different path, and drawing it quietly is worse than
  saying so.
  """
  def resume(server \\ __MODULE__), do: GenServer.call(server, :resume)

  @doc "Abandons the run. There is no resume from a stop."
  def stop_run(server \\ __MODULE__), do: GenServer.call(server, :stop)

  @doc """
  Abandons the run without waiting for it.

  For callers the run may itself be calling. `ExProto.Mode` is the one that
  matters: the run asks it whether it may still be running on every statement,
  so a synchronous stop from a mode change deadlocks the two.
  """
  def stop_async(server \\ __MODULE__), do: GenServer.cast(server, :stop)

  @doc "Runs exactly one statement and holds again."
  def step(server \\ __MODULE__), do: GenServer.call(server, :step)

  @doc "What a pendant renders: the program, the state, the line, the reason."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> idle_status()
  end

  def idle_status do
    %{program: "", state: :idle, statement: -1, statements: 0, kind: "", reason: ""}
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    watch_for_death(self())

    {:ok,
     %__MODULE__{
       mode: Keyword.get(opts, :mode, ExProto.Mode),
       status: :idle,
       index: 0,
       body: [],
       in_flight: [],
       settling?: false,
       chain: nil,
       reason: nil
     }}
  end

  @impl GenServer
  def handle_call({:start, _name}, _from, %{status: status} = state)
      when status in [:running, :held] do
    # One program at a time. A second concurrent run is two things commanding one
    # arm, and the honest version of that is coordinated motion across groups,
    # which this build does not have.
    {:reply, {:error, {:already_running, state.program.name}}, state}
  end

  def handle_call({:start, name}, _from, state) do
    with :ok <- Mode.allows_program?(state.mode),
         {:ok, program} <- fetch_program(name),
         {:ok, body} <- fetch_body(program) do
      Logger.info("program #{program.name}: starting, #{length(body)} statements")

      state = %{
        state
        | program: program,
          body: body,
          index: 0,
          in_flight: [],
          settling?: false,
          chain: Cell.chain(),
          status: :running,
          reason: nil
      }

      send(self(), :advance)
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:hold, _from, %{status: :running} = state) do
    {:reply, :ok, hold_arm(state)}
  end

  def handle_call(:hold, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:resume, _from, %{status: :held} = state) do
    case current_kind(state) do
      "move_arc" ->
        {:reply, {:error, {:cannot_resume_arc, state.index}}, state}

      _resumable ->
        send(self(), :advance)
        {:reply, :ok, %{state | status: :running}}
    end
  end

  def handle_call(:resume, _from, state), do: {:reply, {:error, :not_held}, state}

  def handle_call(:step, _from, %{status: status} = state) when status in [:held, :idle] do
    if state.program && state.index < length(state.body) do
      send(self(), {:advance, :once})
      {:reply, :ok, %{state | status: :running}}
    else
      {:reply, {:error, :nothing_to_step}, state}
    end
  end

  def handle_call(:step, _from, state), do: {:reply, {:error, :not_held}, state}

  def handle_call(:stop, _from, %{status: status} = state) when status in [:running, :held] do
    Logger.info("program #{state.program.name}: stopped at statement #{state.index}")
    {:reply, :ok, %{hold_arm(state) | status: :idle, index: 0, reason: nil}}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  def handle_call(:status, _from, state), do: {:reply, render(state), state}

  @impl GenServer
  def handle_cast(:stop, %{status: status} = state) when status in [:running, :held] do
    Logger.info("program #{state.program.name}: stopped at statement #{state.index}")
    {:noreply, %{hold_arm(state) | status: :idle, index: 0, reason: nil}}
  end

  def handle_cast(:stop, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:advance, state), do: {:noreply, advance(state, :continuous)}
  def handle_info({:advance, :once}, state), do: {:noreply, advance(state, :once)}

  def handle_info({:waited, index}, %{index: index, status: :running} = state) do
    {:noreply, advance(%{state | index: index + 1}, :continuous)}
  end

  def handle_info({:waited, _stale}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # The stop lives outside the run, in one monitoring process whose only job is
  # to release the stream when the run goes away — for any reason at all,
  # including the kill that skips `terminate/2` entirely.
  #
  # It is deliberately the *only* releaser. An earlier version also released in
  # `terminate/2`, and the two raced on an orderly shutdown: a `GenServer.stop`
  # against a stream that was already going away, from inside a terminate that
  # the supervisor was waiting on. That produced a controller that would not
  # restart, intermittently, which is a far worse failure than the one the
  # second releaser was meant to cover.
  #
  # Same argument as the jog watchdog: the thing that stops the machine must not
  # be the thing that might be broken.
  defp watch_for_death(runner) do
    name = ExMo.Schema.Registry.arm_chain().name

    spawn(fn ->
      ref = Process.monitor(runner)

      receive do
        {:DOWN, ^ref, :process, ^runner, reason} ->
          if reason not in [:normal, :shutdown] do
            Logger.warning("program run died (#{inspect(reason)}) — releasing the arm")
          end

          release_chain(name)
      end
    end)
  end

  # ── The interpreter ───────────────────────────────────────────────────────

  defp advance(%{status: status} = state, _mode) when status != :running, do: state

  # A motion can be accepted and then refused: the queue takes it, and three ticks
  # later the arm is at a singularity or against a joint limit. Without this the
  # interpreter waits for a `done` that never comes — a machine that has stopped
  # and says it is running, which is the worst of the three available behaviours.
  defp advance(state, mode) do
    case stream_refusal(state) do
      nil -> step_forward(state, mode)
      refusal -> fault(state, refusal)
    end
  end

  defp step_forward(state, mode) do
    cond do
      # Mode is checked every step rather than only at the start. Turning the key
      # out of auto stops the program, and it does so at the next statement
      # boundary even if nothing else notices.
      Mode.allows_program?(state.mode) != :ok ->
        Logger.info("program #{state.program.name}: mode left auto, stopping")
        %{hold_arm(state) | status: :idle, index: 0}

      state.index >= length(state.body) ->
        finish(state)

      true ->
        run_statement(state, Enum.at(state.body, state.index), mode)
    end
  end

  defp run_statement(state, statement, mode) do
    if Kinds.motion?(statement.kind) do
      issue_motion(state, statement, mode)
    else
      run_barrier(state, statement, mode)
    end
  end

  # A motion statement may go into the queue ahead of the arm, up to the
  # look-ahead. Past that the interpreter waits, which is what keeps a hold from
  # having to unwind half a program.
  defp issue_motion(state, statement, mode) do
    if queued(state) >= @lookahead do
      poll(:advance, mode)
      state
    else
      case issue(state, statement) do
        :ok ->
          state = %{
            state
            | index: state.index + 1,
              in_flight: state.in_flight ++ [state.index],
              settling?: state.settling? or statement.kind == "move_joint"
          }
          # Stepping does not stop the arm: the statement that was issued gets to
          # finish. A step that commanded a move and then cancelled it would be a
          # button that does nothing, slowly.
          if mode == :once, do: %{state | status: :held}, else: continue(state)

        {:error, reason} ->
          fault(state, reason)
      end
    end
  end

  # Everything that is not motion waits for the arm to catch up first. This is
  # the whole of the look-ahead decision, in one branch.
  defp run_barrier(state, statement, mode) do
    if drained?(state) do
      state = %{state | in_flight: [], settling?: false}
      case statement.kind do
        "wait" ->
          seconds = Statement.args(statement)["seconds"] || 0.0
          Process.send_after(self(), {:waited, state.index}, round(seconds * 1000))
          if mode == :once, do: %{state | status: :held, index: state.index + 1}, else: state

        other ->
          fault(state, {:unimplemented, other})
      end
    else
      poll(:advance, mode)
      state
    end
  end

  defp continue(state) do
    send(self(), :advance)
    state
  end

  defp poll(_message, :once), do: Process.send_after(self(), {:advance, :once}, @poll_ms)
  defp poll(message, _continuous), do: Process.send_after(self(), message, @poll_ms)

  defp finish(state) do
    if drained?(state) do
      Logger.info("program #{state.program.name}: done")
      %{state | status: :done, in_flight: [], settling?: false}
    else
      poll(:advance, :continuous)
      state
    end
  end

  defp stream_refusal(state) do
    case CartesianStream.status(chain_name(state)) do
      {:refused, reason} -> {:refused, reason}
      _otherwise -> nil
    end
  end

  defp fault(state, reason) do
    Logger.warning("program #{state.program.name}: refused at statement #{state.index} — #{inspect(reason)}")
    %{hold_arm(state) | status: :faulted, reason: reason}
  end

  # ── Statements ────────────────────────────────────────────────────────────

  defp issue(state, statement) do
    args = Statement.args(statement)

    with {:ok, point} <- referenced(statement, "point"),
         :ok <- tool_matches(point) do
      case statement.kind do
        "move_joint" -> move_joint(state.chain, point)
        "move_linear" -> move_linear(state, point, args)
        "move_arc" -> move_arc(state, statement, point, args)
        other -> {:error, {:unimplemented, other}}
      end
    end
    |> tap(fn _ -> state end)
  end

  defp move_joint(chain, point) do
    joints = ExStore.Cell.Point.joints(point)

    if length(joints) == length(chain.axis_ids) do
      for {axis_id, position} <- Enum.zip(chain.axis_ids, joints) do
        Exdrive.Drive.set_mode(axis_id, :profile_position)
        Exdrive.Drive.set_target_position(axis_id, position)
      end

      :ok
    else
      {:error, {:wrong_arm, length(joints)}}
    end
  catch
    :exit, _reason -> {:error, :unreadable}
  end

  defp move_linear(state, point, args) do
    with {:ok, target} <- Cell.point_in_base(point) do
      state.chain
      |> CartesianStream.move_linear(target, motion_opts(args))
      |> accepted()
    end
  end

  defp move_arc(state, statement, point, args) do
    with {:ok, via_point} <- referenced(statement, "via"),
         {:ok, via} <- Cell.point_in_base(via_point),
         {:ok, target} <- Cell.point_in_base(point) do
      state.chain
      |> CartesianStream.move_arc(via, target, motion_opts(args))
      |> accepted()
    end
  end

  defp motion_opts(args) do
    opts = [
      feedrate: args["feedrate"] || 0.125,
      max_tool_velocity: @auto_tool_velocity
    ]

    case args["blend"] do
      nil -> opts
      blend -> Keyword.put(opts, :blend, blend)
    end
  end

  defp accepted(:ok), do: :ok
  defp accepted({:error, reason}), do: {:error, reason}

  # The decision from PROGRAMS.md §5: a move to a point taught with a tool other
  # than the one fitted is refused, and names both. Recomputing the pose through
  # the fitted tool drives the arm at a location nobody taught it to reach with
  # that tool.
  defp tool_matches(point) do
    if Cell.tool_matches?(point) do
      :ok
    else
      {:error,
       {:wrong_tool, Cell.point_tool_name(point) || "none", Cell.tool_name() || "none"}}
    end
  end

  defp referenced(statement, arg_name) do
    ref = Enum.find(statement.refs || [], &(&1.arg_name == arg_name))

    case ref && StatementRef.referent(ref) do
      {:point, id} ->
        case Points.get(id) do
          nil -> {:error, {:missing_point, arg_name}}
          point -> {:ok, point}
        end

      _absent ->
        {:error, {:missing_argument, arg_name}}
    end
  end

  # ── The arm ───────────────────────────────────────────────────────────────

  defp chain_name(%{chain: nil}), do: ExMo.Schema.Registry.arm_chain().name
  defp chain_name(%{chain: chain}), do: chain.name

  defp queued(state) do
    case CartesianStream.queued(chain_name(state)) do
      count when is_integer(count) -> count
      _no_stream -> 0
    end
  end

  # Arrived, and nothing left in the queue.
  #
  # `:idle` is deliberately *not* drained. A stream reports idle between being
  # handed a motion and its first tick, so treating idle as finished declared a
  # program done while the arm had not started moving — which every other test
  # in the file happily passed. `nil` is no stream at all, which is what a
  # program that has only done joint moves looks like.
  defp drained?(state) do
    settled?(state) and
      case CartesianStream.status(chain_name(state)) do
        nil -> true
        {:done, _reached} -> queued(state) == 0
        _running -> false
      end
  end

  defp settled?(%{settling?: false}), do: true
  defp settled?(state), do: joints_settled?(state.chain)

  defp joints_settled?(chain) do
    case JointState.read(chain) do
      {:ok, %JointState{positions: positions}} ->
        Enum.zip(chain.axis_ids, positions)
        |> Enum.all?(fn {axis_id, position} ->
          case Exdrive.Drive.status(axis_id) do
            %{mode: :profile_position, target_position: target} ->
              abs(target - position) < @joint_tolerance

            _other ->
              true
          end
        end)

      _unreadable ->
        true
    end
  catch
    :exit, _reason -> true
  end

  # Holding abandons whatever is in the queue, so the interpreter rewinds to the
  # oldest statement that had not finished. Resume then re-issues from there —
  # for a blended pair that means re-running the first of the two from wherever
  # the arm is standing, which for linear moves is exactly the remainder of that
  # line. Rewinding is the honest direction: the alternative is resuming past a
  # move that was cancelled halfway.
  defp hold_arm(state) do
    release(state)

    index =
      case state.in_flight do
        [] -> state.index
        [oldest | _rest] -> oldest
      end

    %{state | status: :held, index: index, in_flight: []}
  end

  # Tolerant of a stream that is already going away. Two things release the arm
  # on purpose — the run itself and the monitor that outlives it — and they race
  # on a normal shutdown. A `GenServer.stop` on a dying process exits, and an
  # exit inside `terminate/2` turns an orderly stop into a hang.
  defp release(state), do: release_chain(chain_name(state))

  # Tolerant of a stream that is already going away: a hold and the monitor can
  # arrive at the same stream a moment apart, and a `GenServer.stop` on a dying
  # process exits rather than returning.
  defp release_chain(name) do
    CartesianStream.release(name)
  catch
    :exit, _reason -> :ok
  end

  # ── Reading ───────────────────────────────────────────────────────────────

  defp current_kind(%{index: index} = state), do: kind_at(state, index)

  defp kind_at(%{body: body}, index) do
    case Enum.at(body, index) do
      nil -> ""
      statement -> statement.kind
    end
  end

  defp render(%{program: nil}), do: idle_status()

  defp render(state) do
    executing = List.first(state.in_flight) || state.index

    %{
      program: state.program.name,
      state: state.status,
      statement: executing,
      statements: length(state.body),
      kind: kind_at(state, executing),
      reason: reason_string(state.reason)
    }
  end

  defp reason_string(nil), do: ""
  defp reason_string({:wrong_tool, taught, fitted}), do: "taught with #{taught}, fitted #{fitted}"
  defp reason_string({:refused, {:joint_limit, joint}}), do: "#{joint} is at its limit"
  defp reason_string({:refused, reason}), do: "the arm refused: #{inspect(reason)}"
  defp reason_string({:unimplemented, kind}), do: "no executor for #{kind}"
  defp reason_string({:missing_argument, name}), do: "no #{name}"
  defp reason_string(other), do: inspect(other)

  defp fetch_program(name) do
    case Programs.by_name(name) do
      nil -> {:error, {:unknown_program, name}}
      program -> {:ok, program}
    end
  end

  # A body is read once, at the start. A program edited while it runs is a
  # different program, and picking up half of the change is worse than either.
  defp fetch_body(program) do
    case Programs.body(program) do
      [] ->
        {:error, {:empty_program, program.name}}

      body ->
        case Enum.find(body, &(not Kinds.known?(&1.kind))) do
          nil -> {:ok, body}
          unknown -> {:error, {:unknown_kind, unknown.kind}}
        end
    end
  end
end
