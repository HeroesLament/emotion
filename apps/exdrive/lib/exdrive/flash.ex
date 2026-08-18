defmodule Exdrive.Flash do
  @moduledoc """
  The part of a drive that is not the drive process: what survives a restart.

  A simulated drive used to be *more* forgetful than the firmware in one way
  and *less* in another, and both directions were wrong. It had a `:homing`
  mode the firmware does not implement, and it had no mastering at all — so a
  simulated fleet could never exercise the one thing the controller most needs
  to get right: noticing that an axis came back up not knowing where it is.

  This module is the seam that fixes it. Two things live here, and the whole
  design turns on their being different:

  * **`:rotor`** — where the arm physically is. Metal remembers. It survives a
    power cycle because it is not information, it is a position, and the only
    thing that changes it is something moving the joint.

  * **`:record`** — what the drive wrote to flash on the way down: the master
    offset, and where it believed the rotor was at that moment. This is the
    MASTER page in `servo4257-rs` (see that repo's `docs/MASTERING.md`).

  A drive coming up compares the two. Small difference: the record is still
  good, restore the position. Large difference: somebody moved the joint while
  the power was off, and every turn count above the encoder is a guess.

  ## What a power cycle means here

  | event | rotor | record |
  |---|---|---|
  | drive process restarts (crash, supervisor) | kept | kept |
  | graceful stop | kept | **rewritten** — this is the PVD save |
  | `backdrive/2` | **moved** | kept |
  | `erase/1` | kept | gone — a factory-fresh board |

  A crash is therefore a hard power cut: no save happened, so the record holds
  whatever the last save wrote, and the drift check decides. That asymmetry is
  the point. `terminate/2` runs on a graceful stop and does not run on a kill,
  which is exactly the distinction real hardware makes between a clean
  power-down and yanking the plug.

  ## Why ETS and not a file

  The table dies with the VM, and a VM restart is the one thing that genuinely
  IS a power cycle for the simulated cell — the metal would still be where it
  was, but nothing in this process tree can claim to know that. Persisting to
  disk would model a drive that remembers across power cycles *better* than the
  real one, which is the failure this module exists to stop repeating.
  """

  use GenServer

  @table :exdrive_flash

  defmodule Record do
    @moduledoc """
    One MASTER-page record. `position` is the accumulator value at the moment of
    the save — the thing the boot check compares the rotor against.
    """
    defstruct master_offset: nil, position: 0.0

    @type t :: %__MODULE__{master_offset: float() | nil, position: float()}

    @doc "True once somebody has declared a joint zero."
    def mastered?(%__MODULE__{master_offset: nil}), do: false
    def mastered?(%__MODULE__{}), do: true
  end

  # --- Public API -----------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Where the joint physically is. `nil` for an axis this VM has never run, which
  is not the same as zero: a fresh table means "no idea", and a caller that
  treats it as zero has invented a position.
  """
  def rotor(axis_id) do
    case lookup(axis_id) do
      %{rotor: r} -> r
      nil -> nil
    end
  end

  @doc "Update the physical position. Called by the drive on every tick."
  def set_rotor(axis_id, position) when is_number(position) do
    upsert(axis_id, &%{&1 | rotor: position * 1.0})
  end

  @doc """
  Move the joint without the drive knowing — gravity sag, a person leaning on
  it, a rigging crew. The record is deliberately untouched: that is what makes
  this the thing the boot check must catch.
  """
  def backdrive(axis_id, delta) when is_number(delta) do
    upsert(axis_id, fn e -> %{e | rotor: (e.rotor || 0.0) + delta} end)
  end

  @doc "The saved MASTER record, or `nil` on a blank page."
  def record(axis_id) do
    case lookup(axis_id) do
      %{record: rec} -> rec
      nil -> nil
    end
  end

  @doc """
  Append a record. The PVD save.

  Carries the master offset forward rather than taking one: a power-down must
  never be able to master or unmaster an axis, or a power cut at the wrong
  moment declares a joint zero wherever the arm happened to be hanging.
  """
  def save(axis_id, position) when is_number(position) do
    upsert(axis_id, fn e ->
      offset = if e.record, do: e.record.master_offset, else: nil
      %{e | record: %Record{master_offset: offset, position: position * 1.0}}
    end)
  end

  @doc """
  Declare that the axis is right now at `joint_zero_is`, and persist it.

  `position` is the accumulator value at this instant; the offset is the
  difference. A witness mark deliberately outside the working range is
  supported — that is what `joint_zero_is` is for.
  """
  def master(axis_id, position, joint_zero_is \\ 0.0)
      when is_number(position) and is_number(joint_zero_is) do
    upsert(axis_id, fn e ->
      %{e | record: %Record{master_offset: position - joint_zero_is, position: position * 1.0}}
    end)
  end

  @doc "A factory-fresh board: the page is blank. The rotor does not move."
  def erase(axis_id), do: upsert(axis_id, &%{&1 | record: nil})

  @doc "Wipe everything. Test support; a real fleet has no such button."
  def erase_all do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- Boot resolution ------------------------------------------------------

  @doc """
  Resolve a boot: what the axis knows about itself, given the record and where
  the rotor actually is.

  Pure, and separated from the drive process on purpose — this is the entire
  recovery decision, and it is worth being able to test it without starting
  anything. It mirrors `resolve()` in `servo4257-rs`'s mastering module; keep
  the two in step.

  Returns `{state, position, offset_or_nil, drift_or_nil}` where `state` is one
  of `:unmastered`, `:unreferenced`, `:referenced`. These are not severity
  levels, they are different missing facts, and each owes the caller a
  different refusal:

  * `:unmastered` — no joint zero was ever declared. Nothing about joint angle
    is knowable.
  * `:unreferenced` — the zero is known, the turn count is not. Joint jog is
    still allowed, **because driving to the witness mark is the recovery**. An
    axis that refused to report a position at all could not be recovered.
  * `:referenced` — nothing is missing.
  """
  def resolve(record, rotor, tolerance)

  def resolve(nil, rotor, _tolerance), do: {:unmastered, rotor || 0.0, nil, nil}

  def resolve(%Record{} = rec, rotor, tolerance) do
    rotor = rotor || rec.position
    drift = rotor - rec.position
    retained? = abs(drift) <= tolerance

    state =
      case {Record.mastered?(rec), retained?} do
        {true, true} -> :referenced
        {true, false} -> :unreferenced
        {false, _} -> :unmastered
      end

    # The position is the rotor's either way. An unreferenced axis still has a
    # position — it just does not have one anybody may act on, and saying so is
    # the state's job, not the number's.
    {state, rotor, rec.master_offset, drift}
  end

  # --- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  # --- Table ----------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @table
    end
  end

  # Keys are normalised to strings, and this is not tidiness.
  #
  # A drive is started with whatever its caller had: `ExProto.Controller`
  # derives axis ids from node ids and hands over binaries, while a chain
  # carries atoms and every test writes `:j1`. The drive itself is consistent —
  # it always uses its own `axis_id` — so mastering worked, and the mismatch
  # showed up only when something OUTSIDE the drive went looking: `rotor(:j3)`
  # returned nil for an axis that had been running for minutes, and the caller
  # would have gone on to invent a position for it.
  #
  # Found live rather than in a test, because every test starts drives the same
  # way it looks them up.
  defp key(axis_id) when is_binary(axis_id), do: axis_id
  defp key(axis_id) when is_atom(axis_id), do: Atom.to_string(axis_id)
  defp key(axis_id), do: to_string(axis_id)

  defp lookup(axis_id) do
    ensure_table()
    k = key(axis_id)

    case :ets.lookup(@table, k) do
      [{^k, entry}] -> entry
      [] -> nil
    end
  end

  defp upsert(axis_id, fun) do
    ensure_table()
    entry = lookup(axis_id) || %{rotor: nil, record: nil}
    :ets.insert(@table, {key(axis_id), fun.(entry)})
    :ok
  end
end
