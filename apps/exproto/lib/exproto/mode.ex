defmodule ExProto.Mode do
  @moduledoc """
  The controller's operating mode, and the interlock that hangs off it.

  A grant answers "may this person ever jog". Mode answers a different question —
  "is this machine in a state where jogging is what should be happening" — and
  the two are not substitutes. An operator with the jog grant should still not be
  able to hand-jog an arm that is running a program.

  ## Why this is not writable over the protocol

  On a real machine the mode selector is a keyswitch, and it is a keyswitch
  precisely so that software cannot turn it. A client that can put a controller
  into manual in order to be allowed to jog has not been interlocked; it has been
  asked politely. So `state.controller_mode` is published read-only, and the
  selector is moved by `select/1` from the console — which on a machine with real
  hardware becomes a discrete input, and this module becomes the thing that reads
  it rather than the thing that stores it.

  That is also why the refusal lives here rather than in a pendant. A pendant
  that greys out its own buttons is a suggestion. A controller that refuses is an
  interlock — and it refuses the same way for a pendant, for Studio, and for a
  stored program, which is the property that makes it worth anything.

  ## Leaving manual stops the arm

  A mode change while an axis is being jogged releases every hold, and releasing
  a hold commands zero. Nothing new stops the arm: the watchdog already knows how
  to do that and has been doing it for dropped links and closed laptops since it
  was written. Mode simply becomes another reason for it to fire, which is the
  right shape — one stopping mechanism with several triggers beats several
  mechanisms that must all be correct.

  ## Not a protective function

  Same caveat as everything else on this side of `protocol/DESIGN.md`: this runs
  on the same BEAM as the thing it guards. It is a functional interlock. A
  safety-rated mode selector is hardware, and on a machine that has one this
  module reads it rather than replacing it.
  """

  use GenServer

  require Logger

  # Not `:fault`. The selector has three positions; fault is a *condition* the
  # machine is in, not a place an operator can turn a key to. They are combined
  # into the one published mode by whoever reads both — see
  # `ExProto.Source.Exdrive` — because that is the vocabulary the model declares
  # and an operator thinks in, but conflating them in here would mean a fault
  # silently moving the keyswitch.
  @positions [:idle, :manual, :auto]

  @doc "The three positions the selector has."
  def positions, do: @positions

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Where the selector is."
  def selected(server \\ __MODULE__) do
    GenServer.call(server, :selected)
  catch
    # A controller with no mode process is not in manual. Failing closed is the
    # only defensible direction for an interlock: the failure that matters is the
    # one where the guard is missing and the arm moves anyway.
    :exit, _reason -> :idle
  end

  @doc """
  Move the selector.

  Deliberately not reachable over the protocol. In this build it is called from
  the console; on a machine with a keyswitch it is called by whatever reads the
  discrete input.

  Releases every jog hold on any change, including into manual — an arm being
  jogged when the key turns should stop, and it should stop whichever way the key
  turned.
  """
  def select(position, server \\ __MODULE__) when position in @positions do
    GenServer.call(server, {:select, position})
  end

  @doc """
  Whether jogging is allowed right now, as a result rather than a boolean, so a
  caller can report *why* rather than just refusing.
  """
  def allows_jog?(server \\ __MODULE__) do
    case selected(server) do
      :manual -> :ok
      other -> {:error, {:wrong_mode, other}}
    end
  end

  @doc """
  Whether a stored program may run right now.

  The other half of the same interlock, and deliberately the mirror image:

      manual   jog permitted        program refused
      auto     jog refused          program permitted

  Which is how all four vendors work. An operator hand-jogging an arm that is
  running a program, and a program moving an arm somebody is standing next to
  with a pendant, are the same accident approached from two directions.
  """
  def allows_program?(server \\ __MODULE__) do
    case selected(server) do
      :auto -> :ok
      other -> {:error, {:wrong_mode, other}}
    end
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Manual, because this is a bench controller whose keyswitch is imaginary and
    # whose entire purpose is to be jogged. A machine in a cell would come up
    # wherever its key is, which is the point of reading it rather than storing
    # it.
    {:ok,
     %{
       position: Keyword.get(opts, :position, :manual),
       jog: Keyword.get(opts, :jog, ExProto.Jog),
       run: Keyword.get(opts, :run, ExProto.Program.Run)
     }}
  end

  # Cast, not call, and the reason is a deadlock this found: the run asks Mode
  # whether it may still be running, on every statement, from inside its own
  # message loop. A synchronous stop from here would wait on a process that is
  # waiting on this one. The run may also not exist at all — a controller with
  # no program engine is a perfectly good controller — so this is best-effort in
  # both directions.
  defp stop_program(server) do
    ExProto.Program.Run.stop_async(server)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def handle_call(:selected, _from, state), do: {:reply, state.position, state}

  def handle_call({:select, position}, _from, %{position: position} = state) do
    # Same position. Not a change, so nothing is released — turning a key to
    # where it already is should not stop an arm.
    {:reply, :ok, state}
  end

  def handle_call({:select, position}, _from, state) do
    Logger.info("controller mode: #{state.position} → #{position} — releasing every hold")

    ExProto.Jog.release_all(state.jog)

    # And a running program is a hold of a different shape. Turning the key out
    # of auto stops it, for the same reason turning it out of manual stops a jog:
    # the selector is the one place that says what this machine is currently for.
    stop_program(state.run)

    {:reply, :ok, %{state | position: position}}
  end
end
