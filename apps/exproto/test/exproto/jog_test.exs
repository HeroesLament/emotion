defmodule ExProto.JogTest do
  @moduledoc """
  The held-command watchdog, on its own.

  `ExProto.DispatchTest` exercises it through the protocol, which is where the
  grants and the error codes live. This is about the thing underneath: who is
  allowed to hold what, and what happens to a hold that is superseded from
  somewhere else in the node tree.
  """

  use ExUnit.Case, async: true

  alias ExProto.{EchoSource, Jog}

  setup do
    name = :"jog_#{System.unique_integer([:positive])}"
    start_supervised!({Jog, name: name})
    {:ok, jog: name, source: {EchoSource, self()}}
  end

  defp assert_held(ctx, key, node_id, owner \\ nil) do
    owner = owner || self()
    assert {:ok, _deadline} = Jog.assert(key, node_id, %{"velocity" => 0.1}, ctx.source, owner, ctx.jog)
  end

  # A second connection, which is what a second session is. The hold belongs to
  # the process, so two calls from one process are the same holder however many
  # sessions they claim to be.
  defp as_other_session(fun) do
    Task.async(fun) |> Task.await()
  end

  describe "one holder per node" do
    test "the same node is refused to anyone else", ctx do
      assert_held(ctx, "arm.axes.j1", "arm.axes.j1.jog")

      assert as_other_session(fn ->
               Jog.assert("arm.axes.j1", "arm.axes.j1.jog", %{"velocity" => 0.1}, ctx.source, self(), ctx.jog)
             end) == {:error, :held}
    end

    test "siblings are independent", ctx do
      # Two operators jogging different joints is not a conflict, and treating
      # it as one would make a six-axis arm a one-person machine.
      assert_held(ctx, "arm.axes.j1", "arm.axes.j1.jog")

      assert {:ok, _} =
               as_other_session(fn ->
                 Jog.assert("arm.axes.j2", "arm.axes.j2.jog", %{"velocity" => 0.1}, ctx.source, self(), ctx.jog)
               end)
    end
  end

  describe "a hold covers the tree beneath it" do
    test "holding the arm refuses one of its joints", ctx do
      # The case this exists for: a Cartesian jog is one hold on the arm that
      # moves six joints, and a second session must not be able to take j4 out
      # from under it by naming the joint instead.
      assert_held(ctx, "arm", "arm.jog_cartesian")

      assert as_other_session(fn ->
               Jog.assert("arm.axes.j4", "arm.axes.j4.jog", %{"velocity" => 0.1}, ctx.source, self(), ctx.jog)
             end) == {:error, :held}
    end

    test "holding a joint refuses the whole arm", ctx do
      assert_held(ctx, "arm.axes.j4", "arm.axes.j4.jog")

      assert as_other_session(fn ->
               Jog.assert("arm", "arm.jog_cartesian", %{"velocity" => 0.1}, ctx.source, self(), ctx.jog)
             end) == {:error, :held}
    end

    test "a prefix that is not a path segment is not containment", ctx do
      # "arm.axes.j1" is not an ancestor of "arm.axes.j10", however much the
      # strings look like it.
      assert_held(ctx, "arm.axes.j1", "arm.axes.j1.jog")

      assert {:ok, _} =
               as_other_session(fn ->
                 Jog.assert("arm.axes.j10", "arm.axes.j10.jog", %{"velocity" => 0.1}, ctx.source, self(), ctx.jog)
               end)
    end
  end

  describe "the holder moving around its own tree" do
    test "taking the arm gives up the joint, and zeroes it", ctx do
      assert_held(ctx, "arm.axes.j1", "arm.axes.j1.jog")
      assert_receive {:commanded, "arm.axes.j1.jog", %{"velocity" => 0.1}}

      assert_held(ctx, "arm", "arm.jog_cartesian")

      # The joint is stopped rather than abandoned: nothing is asserting
      # against it any more, and waiting out its deadline would be a joint that
      # keeps turning for a third of a second after the operator moved on.
      assert_receive {:commanded, "arm.axes.j1.jog", %{"velocity" => +0.0}}
      assert_receive {:commanded, "arm.jog_cartesian", %{"velocity" => 0.1}}
    end
  end

  describe "release" do
    test "the same node is dropped, not zeroed", ctx do
      # Whoever sent the command that caused this gets to say what the node does
      # next. A zero racing their stop in is a second opinion nobody asked for.
      assert_held(ctx, "arm.axes.j1", "arm.axes.j1.jog")
      assert_receive {:commanded, "arm.axes.j1.jog", %{"velocity" => 0.1}}

      Jog.release("arm.axes.j1", ctx.jog)

      refute_receive {:commanded, "arm.axes.j1.jog", _}, 100
      assert Jog.holder("arm.axes.j1", ctx.jog) == :none
    end

    test "a hold reaching further than the command is zeroed", ctx do
      # `stop` on one joint stops that joint. It says nothing about the other
      # five a Cartesian hold is still moving, so the hold above it cannot just
      # be forgotten.
      assert_held(ctx, "arm", "arm.jog_cartesian")
      assert_receive {:commanded, "arm.jog_cartesian", %{"velocity" => 0.1}}

      Jog.release("arm.axes.j1", ctx.jog)

      assert_receive {:commanded, "arm.jog_cartesian", %{"velocity" => +0.0}}
      assert Jog.holder("arm", ctx.jog) == :none
    end
  end
end
