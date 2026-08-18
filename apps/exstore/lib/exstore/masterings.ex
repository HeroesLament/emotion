defmodule ExStore.Masterings do
  @moduledoc """
  The controller's shadow of what the fleet says its joint zeros are.

  Four verbs, and "apply" is deliberately not among them:

    * `record/1` — write down what a drive said.
    * `current/1` — what it said most recently.
    * `history/3` — everything it has ever said.
    * `compare/2` — what it says NOW against what it said last.

  The fourth is the one this module exists for. Re-mastering an axis is a
  legitimate thing to do — you replace a board, you rebuild a joint — and it
  invalidates every point ever taught on that robot. Nothing about the arm
  looks wrong afterwards: every joint reports a plausible angle, every move
  executes cleanly, and the work lands somewhere else. Comparing the fleet
  against its own history is the only place that can be caught.
  """

  import Ecto.Query

  alias ExStore.Cell.Mastering
  alias ExStore.Repo

  @doc """
  Records an observation.

  Insert-only: re-recording an axis adds a row rather than replacing one. The
  old value is the thing you want most on the day something has gone wrong.
  """
  def record(attrs) do
    %Mastering{} |> Mastering.changeset(attrs) |> Repo.insert()
  end

  @doc """
  The newest row per axis for a robot, as `%{axis_id => %Mastering{}}`.

  Ordered by `inserted_at` then `id`, because two rows can share a timestamp —
  timestamps have second resolution and a `restore` writes every axis at once.
  Ordering by time alone would make "the newest" arbitrary on exactly the
  operation that most needs to be reconstructable.
  """
  def current(robot_id) do
    Mastering
    |> where([m], m.robot_id == ^robot_id)
    |> order_by([m], asc: m.inserted_at, asc: m.id)
    |> Repo.all()
    |> Map.new(&{&1.axis_id, &1})
  end

  @doc "Everything an axis has ever said, newest first."
  def history(robot_id, axis_id, limit \\ 50) do
    Mastering
    |> where([m], m.robot_id == ^robot_id and m.axis_id == ^axis_id)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Compares what the fleet says now against what it said last.

  `observed` is `%{axis_id => offset_or_nil}` — `nil` for an axis that reports
  no joint zero at all. Returns a list of findings, one per axis that has
  something to say:

    * `{:changed, axis_id, was, now}` — **the dangerous one.** The offset moved
      under a cell full of taught points. Nothing else will notice.
    * `{:lost, axis_id, was}` — the axis had a zero and now reports none. A
      replaced board, or a wiped page.
    * `{:new, axis_id, now}` — an axis reporting a zero for the first time.
      Expected right after commissioning, and worth a mention any other time.

  An axis that agrees is absent from the result, so an empty list means the
  fleet is exactly as it was left. That is the answer a boot check wants.

  `epsilon` is deliberately loose relative to the drive's own retention
  tolerance: this is comparing two records of the same declared number, not
  measuring a rotor, so anything above float noise is a real change.
  """
  def compare(robot_id, observed, epsilon \\ 1.0e-9) when is_map(observed) do
    shadow = current(robot_id)

    observed
    |> Enum.sort_by(fn {axis_id, _} -> axis_id end)
    |> Enum.flat_map(fn {axis_id, now} ->
      case {Map.get(shadow, axis_id), now} do
        {nil, nil} -> []
        {nil, now} -> [{:new, axis_id, now}]
        {%{offset: was}, nil} -> [{:lost, axis_id, was}]
        {%{offset: was}, now} when abs(was - now) <= epsilon -> []
        {%{offset: was}, now} -> [{:changed, axis_id, was, now}]
      end
    end)
  end

  @doc """
  Records everything the fleet currently says, in one go.

  `observed` is `%{axis_id => %{offset: float, state: binary}}`. Axes with no
  offset are skipped rather than recorded as zero — "no joint zero" is not an
  offset of nought, and a row saying otherwise would be a fabricated fact that
  outlives the boot that invented it.
  """
  def snapshot(robot_id, observed, opts \\ []) when is_map(observed) do
    source = Keyword.get(opts, :source, "observed")
    note = Keyword.get(opts, :note)

    observed
    |> Enum.reject(fn {_axis, %{offset: offset}} -> is_nil(offset) end)
    |> Enum.map(fn {axis_id, %{offset: offset, state: state}} ->
      record(%{
        robot_id: robot_id,
        axis_id: to_string(axis_id),
        offset: offset,
        state: to_string(state),
        source: source,
        note: note
      })
    end)
  end
end
