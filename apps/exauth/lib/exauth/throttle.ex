defmodule ExAuth.Throttle do
  @moduledoc """
  Exponential backoff on repeated authentication failures.

  ## Why this is not optional

  Argon2 is deliberately expensive. That is a defence against someone who has
  stolen the database, and a liability against someone who has merely found the
  port: every guess costs the controller 32 MiB and ~100 ms of a core it also
  needs for a control loop. Without throttling, adding a slow KDF makes the
  login endpoint a better denial-of-service target than it was before.

  So the counter is load-bearing twice over — it bounds guessing, and it bounds
  what guessing costs us.

  ## Keys

  Deliberately opaque. `ExAuth` throttles on the username *and* on the peer
  address, because either alone leaves a hole: username-only lets one client
  spray a thousand usernames at one guess each, address-only lets a botnet
  grind one account. Neither is complete either, but the pair is materially
  harder to walk around than the usual single counter.

  ## State is memory-only, on purpose

  A restart clears the counters. That is the right trade for a controller: the
  alternative is a disk write on every failed login, and an attacker who can
  force a restart to clear a counter can already do worse. It does mean a crash
  loop resets the backoff, which is noted rather than solved.
  """

  use GenServer

  require Logger

  @table :exauth_throttle

  # Failures below this cost nothing. Fat fingers are not an attack, and an
  # operator locked out by two typos will write the password on the machine.
  @free_attempts 4

  @max_lock_seconds 300
  @forget_after_seconds 3_600
  @sweep_interval_ms 60_000

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether `key` may attempt an authentication right now.
  """
  @spec check(term()) :: :ok | {:error, {:throttled, pos_integer()}}
  def check(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, _failures, locked_until, _last}] when locked_until > now ->
        {:error, {:throttled, locked_until - now}}

      _ ->
        :ok
    end
  end

  @doc """
  Records a failed attempt and returns the lock now in force, if any.
  """
  @spec record_failure(term()) :: :ok | {:locked, pos_integer()}
  def record_failure(key) do
    now = System.system_time(:second)

    failures =
      case :ets.lookup(@table, key) do
        [{^key, failures, _locked_until, last}] when now - last < @forget_after_seconds ->
          failures + 1

        _ ->
          1
      end

    lock = lock_seconds(failures)
    locked_until = if lock > 0, do: now + lock, else: 0
    :ets.insert(@table, {key, failures, locked_until, now})

    if lock > 0, do: {:locked, lock}, else: :ok
  end

  @doc "Clears the counter for `key` after a successful authentication."
  @spec record_success(term()) :: :ok
  def record_success(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  How long a lock lasts after `failures` consecutive failures.

  Doubling from one second, capped at five minutes. The cap matters: an
  unbounded backoff is indistinguishable from a permanently bricked account,
  and an operator who cannot get in during an incident will simply pull power.
  """
  @spec lock_seconds(non_neg_integer()) :: non_neg_integer()
  def lock_seconds(failures) when failures <= @free_attempts, do: 0

  def lock_seconds(failures) do
    min(Bitwise.bsl(1, failures - @free_attempts - 1), @max_lock_seconds)
  end

  @doc false
  def reset_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - @forget_after_seconds

    # {key, failures, locked_until, last} — drop anything untouched since cutoff
    # and no longer locked, so the table tracks live pressure rather than
    # accumulating every username ever mistyped.
    :ets.select_delete(@table, [
      {{:_, :_, :"$1", :"$2"}, [{:andalso, {:<, :"$2", cutoff}, {:"=<", :"$1", cutoff}}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
