defmodule ExProto.Publisher do
  @moduledoc """
  Subscription delivery: what to send, when, and what to leave out.

  Pure. A publisher state, a time, and a way to read values go in; a list of
  notifications and a new state come out. Nothing here owns a clock — see
  `ExProto.Publisher.Server` for the thin process that does, and `Exdrive.Drive`
  for why that separation is not negotiable.

  ## Conflation is the absence of a buffer, not a buffer policy

  Values are read at send time. A node that changed forty times between two
  ticks is read once, and the thirty-nine intermediate values were never stored
  anywhere to be dropped from.

  That is worth stating plainly because the obvious implementation is the wrong
  one: subscribe to changes, push each into a queue, drain the queue on a timer.
  That version has a buffer, the buffer grows when the client is slow, and a
  momentarily slow client falls permanently behind while memory climbs. Reading
  at send time cannot do that — the worst case is that the client sees fewer
  values, never older ones.

  ## Sequence numbers skip

  `seq` counts *ticks*, not notifications. A tick where nothing changed sends
  nothing and still advances the sequence, so a client sees gaps as a matter of
  course. A gap means "you did not receive every tick", which is expected, and
  a client that treats it as loss and resyncs will resync constantly.

  Contrast the event journal, whose sequence is gapless precisely so a gap
  there *does* mean something was missed. Two different guarantees, deliberately
  different, and conflating them would make one of them useless.

  ## Only changes are sent

  A tick sends the nodes whose values differ from what this subscription last
  sent. The first tick after subscribing therefore delivers everything, which
  is what a client wants: it gets a complete picture without a separate
  initial-read round trip.
  """

  alias ExProto.Source

  defstruct subscriptions: %{}

  @type t :: %__MODULE__{subscriptions: %{String.t() => map()}}

  @type notification :: map()

  @doc "An empty publisher."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @method "notifications/nodes/changed"

  @doc """
  The JSON-RPC method name a value notification carries.

  A function rather than a literal in two places. `ExLink` and
  `mix emotion.rpc` filter incoming frames on this, and when the name lived as a
  string at each end the client silently matched nothing — a subscription that
  delivers correctly and a client that shows nothing look identical from the
  outside, which is the worst way to find a typo.
  """
  @spec method() :: String.t()
  def method, do: @method

  @doc """
  Registers a subscription.

  `now_ms` is a monotonic millisecond reading. The first tick is scheduled
  immediately rather than one interval out, so a client sees its initial values
  without waiting — at 1 Hz, a one-second blank panel is a long time to look at
  nothing.
  """
  @spec add(t(), String.t(), [String.t()], number(), integer()) :: t()
  def add(publisher, id, node_ids, rate_hz, now_ms) do
    subscription = %{
      id: id,
      node_ids: node_ids,
      interval_ms: interval_ms(rate_hz),
      seq: 0,
      last: %{},
      due_at: now_ms
    }

    %{publisher | subscriptions: Map.put(publisher.subscriptions, id, subscription)}
  end

  @doc "Removes a subscription. Idempotent."
  @spec remove(t(), String.t()) :: t()
  def remove(publisher, id) do
    %{publisher | subscriptions: Map.delete(publisher.subscriptions, id)}
  end

  @doc "True when nothing is subscribed, so a caller can stop its timer."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{subscriptions: subs}), do: subs == %{}

  @doc """
  Milliseconds until the next subscription is due, or `nil` when none are.

  Lets the process schedule one timer for the nearest deadline rather than one
  timer per subscription, which matters when a pendant holds a dozen of them.
  """
  @spec next_due_in(t(), integer()) :: non_neg_integer() | nil
  def next_due_in(%__MODULE__{subscriptions: subs}, _now_ms) when map_size(subs) == 0, do: nil

  def next_due_in(%__MODULE__{subscriptions: subs}, now_ms) do
    subs
    |> Map.values()
    |> Enum.map(&max(&1.due_at - now_ms, 0))
    |> Enum.min()
  end

  @doc """
  Advances to `now_ms`, producing notifications for every subscription that is
  due.

  `source` is `{module, arg}`. Values are read here, at send time, which is
  what makes this conflating rather than buffering.
  """
  @spec tick(t(), integer(), {module(), term()}) :: {[notification()], t()}
  def tick(publisher, now_ms, source) do
    {notifications, subscriptions} =
      publisher.subscriptions
      |> Enum.map_reduce(%{}, fn {id, subscription}, acc ->
        if subscription.due_at <= now_ms do
          {notification, advanced} = fire(subscription, now_ms, source)
          {notification, Map.put(acc, id, advanced)}
        else
          {nil, Map.put(acc, id, subscription)}
        end
      end)

    {Enum.reject(notifications, &is_nil/1), %{publisher | subscriptions: subscriptions}}
  end

  # ── One subscription's tick ───────────────────────────────────────────────

  defp fire(subscription, now_ms, {module, arg}) do
    seq = subscription.seq + 1
    read = Source.read_many(module, subscription.node_ids, arg)

    {changed, last} = changes(read, subscription.last)

    advanced = %{
      subscription
      | seq: seq,
        last: last,
        # From the deadline rather than from now, so a late tick does not push
        # the whole schedule later and a subscription cannot drift slower than
        # it was granted.
        due_at: next_deadline(subscription.due_at, subscription.interval_ms, now_ms)
    }

    notification =
      if changed == [] do
        # Nothing to say. The sequence still advanced, which is exactly the gap
        # a client is told to expect.
        nil
      else
        %{
          "jsonrpc" => "2.0",
          "method" => method(),
          "params" => %{
            "subscriptionId" => subscription.id,
            "seq" => seq,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "values" => changed
          }
        }
      end

    {notification, advanced}
  end

  # Compares against what this subscription last *sent*, not against what was
  # last read. A node that changes and changes back between ticks is correctly
  # silent — the client's picture was never wrong.
  defp changes(read, last) do
    Enum.reduce(read, {[], last}, fn {node_id, outcome}, {changed, last} ->
      current = entry_value(outcome)

      if Map.get(last, node_id, :__unset__) == current do
        {changed, last}
      else
        {changed ++ [entry(node_id, outcome)], Map.put(last, node_id, current)}
      end
    end)
  end

  defp entry_value({:ok, value}), do: {:ok, value}
  defp entry_value({:error, reason}), do: {:error, reason}

  defp entry(node_id, {:ok, value}) do
    %{"nodeId" => node_id, "value" => value}
  end

  # A node that becomes unreadable mid-subscription reports it once, rather
  # than either going silent — indistinguishable from unchanged — or repeating
  # the error every tick.
  defp entry(node_id, {:error, reason}) do
    %{"nodeId" => node_id, "error" => error_body(reason)}
  end

  defp error_body(:unknown_node), do: %{"code" => -32_003, "message" => "No such node"}
  defp error_body(:not_readable), do: %{"code" => -32_004, "message" => "Node is not readable"}
  defp error_body(other), do: %{"code" => -32_004, "message" => "Unreadable: #{inspect(other)}"}

  # Catches up rather than accumulating debt: if the process was blocked for
  # several intervals, the next deadline is the next one in the future, not a
  # backlog of missed ones to fire in a burst.
  defp next_deadline(due_at, interval_ms, now_ms) do
    behind = now_ms - due_at
    skipped = div(behind, interval_ms) + 1
    due_at + skipped * interval_ms
  end

  defp interval_ms(rate_hz) when rate_hz > 0 do
    # At least 1ms, so a nonsense rate cannot produce a zero-interval loop.
    max(round(1000 / rate_hz), 1)
  end
end
