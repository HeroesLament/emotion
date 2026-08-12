defmodule EMotion.JobTest do
  @moduledoc """
  The anti-freeze primitive.

  Async by nature, so these tests are written to prove the properties that
  matter under contention — supersession, cancellation races, isolation of
  failure — rather than just that a function eventually returns something.
  """

  use ExUnit.Case, async: false

  alias EMotion.Job

  defp await(key, timeout \\ 500) do
    receive do
      {:job, ^key, ref, result} -> {ref, result}
    after
      timeout -> flunk("no result for #{inspect(key)} within #{timeout}ms")
    end
  end

  defp refute_result(key, wait \\ 120) do
    receive do
      {:job, ^key, _ref, result} ->
        flunk("unexpected result for #{inspect(key)}: #{inspect(result)}")
    after
      wait -> :ok
    end
  end

  describe "run/3" do
    test "delivers a result to the caller" do
      ref = Job.run(:add, fn -> 1 + 1 end)

      assert {^ref, {:ok, 2}} = await(:add)
    end

    test "does not block the caller" do
      # The entire point. If this were synchronous the assertion below would
      # be reached only after the sleep, and the UI would have been frozen for
      # exactly as long.
      Job.run(:slow, fn -> Process.sleep(300) end)

      assert Process.alive?(self())
      refute_received {:job, :slow, _, _}
    end

    test "several keys run concurrently" do
      Job.run(:a, fn ->
        Process.sleep(120)
        :a
      end)

      Job.run(:b, fn ->
        Process.sleep(120)
        :b
      end)

      # Serial execution would need 240ms; both land well inside that.
      assert {_, {:ok, :a}} = await(:a, 400)
      assert {_, {:ok, :b}} = await(:b, 400)
    end
  end

  describe "supersession" do
    test "a second job under the same key cancels the first" do
      # Dragging a jog target: two hundred IK solves should not queue, only
      # the one for where the mouse is now should survive.
      Job.run(:ik, fn ->
        Process.sleep(300)
        :stale
      end)

      Process.sleep(30)
      fresh = Job.run(:ik, fn -> :fresh end)

      assert {^fresh, {:ok, :fresh}} = await(:ik)
      refute_result(:ik)
    end

    test "the surviving result carries the ref run/3 returned" do
      # The receiver's defence against the cancellation race: a task can send
      # in the instant between finishing and being killed.
      _first =
        Job.run(:ik, fn ->
          Process.sleep(200)
          :stale
        end)

      second = Job.run(:ik, fn -> :fresh end)

      {ref, _result} = await(:ik)

      assert ref == second
      assert Job.current?(second, ref)
      refute Job.current?(second, make_ref())
    end

    test "a job under a different key is untouched" do
      Job.run(:keep, fn ->
        Process.sleep(80)
        :kept
      end)

      Job.run(:other, fn -> :other end)
      Job.run(:other, fn -> :other_again end)

      assert {_, {:ok, :kept}} = await(:keep, 500)
    end
  end

  describe "cancel/2" do
    test "stops an in-flight job" do
      Job.run(:planning, fn ->
        Process.sleep(300)
        :done
      end)

      Process.sleep(30)
      Job.cancel(:planning)

      refute_result(:planning, 400)
    end

    test "cancelling nothing is not an error" do
      assert Job.cancel(:never_started) == :ok
      refute_result(:never_started, 50)
    end

    test "running? reports what is in flight" do
      Job.run(:probe, fn -> Process.sleep(200) end)
      Process.sleep(30)

      assert Job.running?(:probe)

      Job.cancel(:probe)
      Process.sleep(30)

      refute Job.running?(:probe)
    end
  end

  describe "failure" do
    test "an exception becomes a result, not a crash" do
      # A malformed STL is a normal condition in a tool that opens files
      # people gave it. The window should say so, not disappear.
      Job.run(:parse, fn -> raise ArgumentError, "bad header" end)

      assert {_, {:error, {:exception, message}}} = await(:parse)
      assert message =~ "bad header"
    end

    test "an exit becomes a result" do
      # What a GenServer.call to a dead drive looks like from in here.
      Job.run(:drive, fn -> exit(:noproc) end)

      assert {_, {:error, {:exit, :noproc}}} = await(:drive)
    end

    test "a throw becomes a result" do
      Job.run(:thrown, fn -> throw(:nope) end)

      assert {_, {:error, {:throw, :nope}}} = await(:thrown)
    end

    test "a failing job leaves the caller alive" do
      Job.run(:boom, fn -> raise "boom" end)
      await(:boom)

      assert Process.alive?(self())
    end

    test "the job runner survives a failing job" do
      runner = Process.whereis(EMotion.Job)

      Job.run(:boom, fn -> raise "boom" end)
      await(:boom)

      assert Process.alive?(runner)
      assert Process.whereis(EMotion.Job) == runner
    end
  end

  describe "timeouts" do
    test "a hung job is killed and reported" do
      # Anything touching hardware sets one of these. A job that silently
      # never answers is worse than one that fails: the UI waits forever for
      # a reply that is not coming.
      Job.run(:fieldbus, fn -> Process.sleep(:infinity) end, timeout: 80)

      assert {_, {:error, :timeout}} = await(:fieldbus, 500)
    end

    test "a job that finishes in time is unaffected" do
      Job.run(:quick, fn -> :done end, timeout: 500)

      assert {_, {:ok, :done}} = await(:quick)
      refute_result(:quick)
    end

    test "a timeout does not fire after a supersession" do
      Job.run(:ik, fn -> Process.sleep(:infinity) end, timeout: 100)
      Process.sleep(20)
      fresh = Job.run(:ik, fn -> :fresh end, timeout: 1000)

      assert {^fresh, {:ok, :fresh}} = await(:ik)
      refute_result(:ik, 200)
    end
  end

  describe "owner" do
    test "results can be addressed elsewhere" do
      test_pid = self()
      collector = spawn(fn -> receive do: (msg -> send(test_pid, {:collected, msg})) end)

      Job.run(:elsewhere, fn -> :value end, owner: collector)

      assert_receive {:collected, {:job, :elsewhere, _ref, {:ok, :value}}}, 500
      refute_received {:job, :elsewhere, _, _}
    end
  end
end
