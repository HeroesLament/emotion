defmodule ExProto.PublisherTest do
  @moduledoc """
  Subscription delivery.

  Everything runs under an external clock, so a test can advance an hour of
  subscription time instantly and assert on exactly which frames came out. The
  properties worth pinning are the ones whose failure is silent: a buffer
  quietly forming, a sequence that does not skip, a value repeated when nothing
  changed.
  """

  use ExUnit.Case, async: true

  alias ExProto.Publisher
  alias ExProto.Publisher.Server
  alias ExProto.Source.Static

  setup do
    {:ok, source} =
      Static.start_link(
        values: %{
          "axes.j1.position" => 0.0,
          "axes.j2.position" => 1.0
        }
      )

    {:ok, source: source}
  end

  defp publisher(source, opts \\ []) do
    {:ok, pid} =
      Server.start_link(
        Keyword.merge([source: {Static, source}, clock: :external, owner: self()], opts)
      )

    pid
  end

  defp drain(acc \\ []) do
    receive do
      {:notify, notification} -> drain([notification | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp values(notification), do: notification["params"]["values"]
  defp seq(notification), do: notification["params"]["seq"]

  # ── conflation ────────────────────────────────────────────────────────────

  describe "conflation" do
    test "forty changes between ticks produce one value", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)
      drain()

      # The whole point: nothing accumulates. There is no buffer for these to
      # go into, because values are read at send time.
      for i <- 1..40, do: Static.put(source, "axes.j1.position", i * 0.01)

      Server.tick(pub, 100)

      assert [notification] = drain()
      assert [%{"nodeId" => "axes.j1.position", "value" => value}] = values(notification)
      assert_in_delta value, 0.40, 1.0e-9
    end

    test "a slow client falls behind in values, never in time", %{source: source} do
      # Simulate a client that misses many intervals: advance a long way in one
      # step. A buffering implementation would emit a burst of stale frames.
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 100)
      Server.tick(pub, 0)
      drain()

      Static.put(source, "axes.j1.position", 9.9)
      # Ten seconds at 100 Hz is a thousand missed intervals.
      Server.tick(pub, 10_000)

      assert [one] = drain()
      assert [%{"value" => 9.9}] = values(one)
    end

    test "a value that changes and changes back is silent", %{source: source} do
      # The client's picture was never wrong, so there is nothing to correct.
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)
      drain()

      Static.put(source, "axes.j1.position", 5.0)
      Static.put(source, "axes.j1.position", 0.0)
      Server.tick(pub, 100)

      assert [] = drain()
    end
  end

  # ── sequence ──────────────────────────────────────────────────────────────

  describe "sequence numbers" do
    test "the first tick delivers everything", %{source: source} do
      # So a client gets a complete picture without a separate initial read.
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position", "axes.j2.position"], 10)

      Server.tick(pub, 0)

      assert [notification] = drain()
      assert length(values(notification)) == 2
      assert seq(notification) == 1
    end

    test "skip when a tick has nothing to say", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)
      drain()

      # Two silent ticks, then a change.
      Server.tick(pub, 100)
      Server.tick(pub, 100)
      Static.put(source, "axes.j1.position", 1.0)
      Server.tick(pub, 100)

      assert [notification] = drain()
      # 1 was the initial frame; 2 and 3 happened and said nothing.
      assert seq(notification) == 4
    end

    test "are monotonic per subscription and independent across them", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "a", ["axes.j1.position"], 10)
      Server.tick(pub, 0)
      drain()

      Server.add(pub, "b", ["axes.j2.position"], 10)
      Server.tick(pub, 0)

      assert [b_first] = drain()
      assert b_first["params"]["subscriptionId"] == "b"
      assert seq(b_first) == 1, "a new subscription starts its own sequence"
    end
  end

  # ── scheduling ────────────────────────────────────────────────────────────

  describe "scheduling" do
    test "a subscription fires immediately rather than one interval out",
         %{source: source} do
      # At 1 Hz, waiting a second before showing anything is a long blank panel.
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 1)

      Server.tick(pub, 0)

      assert [_notification] = drain()
    end

    test "does not fire before its interval elapses", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)
      drain()

      Static.put(source, "axes.j1.position", 1.0)
      # 10 Hz is a 100ms interval; 50 is not due.
      Server.tick(pub, 50)

      assert [] = drain()

      Server.tick(pub, 50)
      assert [_notification] = drain()
    end

    test "a late tick does not push the schedule later", %{source: source} do
      # Deadlines advance from the previous deadline, not from now, so a
      # subscription cannot drift slower than the rate it was granted.
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)
      drain()

      # Arrive very late.
      Static.put(source, "axes.j1.position", 1.0)
      Server.tick(pub, 350)
      drain()

      state = Server.state(pub)
      subscription = state.subscriptions["sub_1"]

      # 350 lands inside the fourth interval, so the next deadline is 400 —
      # still on the original grid.
      assert subscription.due_at == 400
    end

    test "catching up does not fire a burst of missed intervals", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 100)
      Server.tick(pub, 0)
      drain()

      Static.put(source, "axes.j1.position", 1.0)
      Server.tick(pub, 5_000)

      # One frame, not five hundred.
      assert length(drain()) == 1
    end

    test "subscriptions at different rates fire independently", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "fast", ["axes.j1.position"], 100)
      Server.add(pub, "slow", ["axes.j2.position"], 1)
      Server.tick(pub, 0)
      drain()

      Static.put(source, "axes.j1.position", 1.0)
      Static.put(source, "axes.j2.position", 2.0)

      # 10ms: fast is due, slow is not.
      Server.tick(pub, 10)
      assert [only] = drain()
      assert only["params"]["subscriptionId"] == "fast"

      Server.tick(pub, 1000)
      ids = drain() |> Enum.map(& &1["params"]["subscriptionId"])
      assert "slow" in ids
    end
  end

  # ── lifecycle ─────────────────────────────────────────────────────────────

  describe "lifecycle" do
    test "removing a subscription stops its delivery", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)
      drain()

      Server.remove(pub, "sub_1")
      Static.put(source, "axes.j1.position", 1.0)
      Server.tick(pub, 1000)

      assert [] = drain()
    end

    test "removing an unknown subscription is fine", %{source: source} do
      pub = publisher(source)
      assert :ok = Server.remove(pub, "never_existed")
    end

    test "an empty publisher reports itself empty", %{source: source} do
      pub = publisher(source)
      assert Publisher.empty?(Server.state(pub))

      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      refute Publisher.empty?(Server.state(pub))
    end

    test "an unknown clock is rejected", %{source: source} do
      Process.flag(:trap_exit, true)

      # GenServer wraps an init raise with a stacktrace; gen_statem does not.
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Server.start_link(source: {Static, source}, clock: :wall)

      assert message =~ ":clock must be"
    end
  end

  # ── unreadable nodes ──────────────────────────────────────────────────────

  describe "nodes that go unreadable" do
    test "report the error once rather than every tick", %{source: source} do
      # Silence would be indistinguishable from unchanged; repeating it every
      # tick would flood a client that already knows.
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.missing"], 10)

      Server.tick(pub, 0)
      assert [first] = drain()
      assert [%{"error" => %{"code" => -32_003}}] = values(first)

      Server.tick(pub, 100)
      assert [] = drain()
    end

    test "recovering reports the value", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.later"], 10)
      Server.tick(pub, 0)
      drain()

      Static.put(source, "axes.later", 7.0)
      Server.tick(pub, 100)

      assert [notification] = drain()
      assert [%{"value" => 7.0}] = values(notification)
    end
  end

  # ── shape ─────────────────────────────────────────────────────────────────

  describe "the notification" do
    test "is a valid JSON-RPC notification with no id", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)

      assert [notification] = drain()
      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/nodes/changed"
      # A notification with an id is a request, and a client would wait for a
      # response to it that is never coming.
      refute Map.has_key?(notification, "id")
    end

    test "batches a whole tick into one frame", %{source: source} do
      # Six axes updating should be one message, not six.
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position", "axes.j2.position"], 10)
      Server.tick(pub, 0)
      drain()

      Static.put(source, "axes.j1.position", 1.0)
      Static.put(source, "axes.j2.position", 2.0)
      Server.tick(pub, 100)

      assert [one] = drain()
      assert length(values(one)) == 2
    end

    test "carries a timestamp", %{source: source} do
      pub = publisher(source)
      Server.add(pub, "sub_1", ["axes.j1.position"], 10)
      Server.tick(pub, 0)

      assert [notification] = drain()
      assert {:ok, _dt, _} = DateTime.from_iso8601(notification["params"]["timestamp"])
    end
  end
end
