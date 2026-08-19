defmodule ExProto.FrameArgumentTest do
  use ExUnit.Case, async: false

  alias ExMove.CartesianStream
  alias ExProto.Source.Exdrive, as: Source
  alias ExStore.Frames

  @moduledoc """
  What the `frame` argument now accepts, and what it still refuses.

  The arithmetic — composing a pose with the frame it was given in — is tested
  in `EMotion.CellTest` and `ExMove.FrameAlgebraTest`, where it can be asserted
  against hand-computed answers. What is tested here is the plumbing: that a
  stored name reaches the resolver, that an unknown one is refused rather than
  quietly treated as base, and that `tool` is accepted for a velocity and
  refused for a destination.

  That last one is the only rule in this file that is a design decision rather
  than a mechanism. A twist along the tool's axis is meaningful; a *destination*
  named in the tool frame is either where the arm already is or a request for
  relative motion, and relative motion should be its own method rather than a
  surprising reading of this one.
  """

  setup_all do
    # The arm's own axes, because these calls go through the real chain rather
    # than a per-test one. Started once and left running: Exdrive's supervisor
    # has no stop, and a drive standing still with nothing commanded is what
    # every other test in this app already assumes when it finds one.
    chain = EMotion.Schema.Registry.arm_chain()

    for axis_id <- chain.axis_ids do
      case Exdrive.start_axis(axis_id) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      Exdrive.enable(axis_id)
    end

    # Bent, not the zero pose — the zero pose of this chain is straight up at
    # full extension, which is a singularity, and a move accepted or refused
    # there says nothing about the frame argument.
    for {axis_id, q} <- Enum.zip(chain.axis_ids, [0.0, 0.6, -1.2, 0.0, 0.7, 0.0]) do
      Exdrive.Drive.set_mode(axis_id, :profile_position)
      Exdrive.Drive.set_target_position(axis_id, q)
    end

    Process.sleep(500)
    :ok
  end

  setup do
    start_supervised!({ExProto.Jog, name: FrameArgJog})
    start_supervised!({ExProto.Mode, name: FrameArgMode, jog: FrameArgJog})
    :ok = ExProto.Mode.select(:manual, FrameArgMode)

    name = "fixture_#{System.unique_integer([:positive])}"
    {:ok, frame} = Frames.create(%{name: name, x: 0.4, y: -0.1, rz: :math.pi() / 2})

    on_exit(fn ->
      CartesianStream.release(EMotion.Schema.Registry.arm_chain().name)
      Frames.delete(frame)
    end)

    %{arg: [mode: FrameArgMode], frame: name}
  end

  describe "a jog" do
    test "takes a stored frame", %{arg: arg, frame: frame} do
      assert :ok =
               Source.call(
                 "axes.jog_cartesian",
                 %{"velocity" => 0.02, "axis" => "x", "frame" => frame},
                 arg
               )
    end

    test "still takes base and tool", %{arg: arg} do
      for frame <- ~w(base tool) do
        assert :ok =
                 Source.call(
                   "axes.jog_cartesian",
                   %{"velocity" => 0.02, "axis" => "x", "frame" => frame},
                   arg
                 )
      end
    end

    test "refuses a frame that is not stored", %{arg: arg} do
      assert {:error, :rejected} =
               Source.call(
                 "axes.jog_cartesian",
                 %{"velocity" => 0.02, "axis" => "x", "frame" => "the_one_from_last_year"},
                 arg
               )
    end
  end

  describe "a move" do
    test "takes a stored frame", %{arg: arg, frame: frame} do
      assert :ok =
               Source.call(
                 "axes.move_linear",
                 %{"x" => 0.1, "y" => 0.0, "z" => 0.1, "frame" => frame},
                 arg
               )
    end

    test "refuses the tool frame as a destination", %{arg: arg} do
      assert {:error, :rejected} =
               Source.call(
                 "axes.move_linear",
                 %{"x" => 0.1, "y" => 0.0, "z" => 0.1, "frame" => "tool"},
                 arg
               )
    end

    test "refuses a frame that is not stored", %{arg: arg} do
      assert {:error, :rejected} =
               Source.call(
                 "axes.move_linear",
                 %{"x" => 0.1, "y" => 0.0, "z" => 0.1, "frame" => "nowhere"},
                 arg
               )
    end

    test "an arc takes a frame too, and its via point moves with it", %{arg: arg, frame: frame} do
      assert :ok =
               Source.call(
                 "axes.move_arc",
                 %{
                   "x" => 0.1,
                   "y" => 0.0,
                   "z" => 0.1,
                   "via_x" => 0.05,
                   "via_y" => 0.05,
                   "via_z" => 0.1,
                   "frame" => frame
                 },
                 arg
               )
    end
  end
end
