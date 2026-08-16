defmodule ExProto.CartesianStatusTest do
  use ExUnit.Case, async: true

  alias ExProto.Source.Exdrive, as: Source

  @moduledoc """
  Every status the stream can be in projects onto every node that reports it.

  This exists because one shape was missing. `{:done, :reached}` arrived in
  `ExMove.CartesianStream` with `move_linear` and was never taught to the
  projection, and the way it announced itself was a `CaseClauseError` raised
  inside a read — which closed the client's connection with a 1011. A client
  asking a perfectly reasonable question had its session dropped, which is a far
  worse failure than being told the wrong number.

  The lesson generalises past this one bug: a projection that pattern-matches on
  a shape owned by another application is a coupling with nothing holding it
  together. This is what holds it together.
  """

  # Every status ExMove.CartesianStream can hold, taken from its own docstring
  # rather than from the projection — the point is to catch the case where the
  # two have drifted, so the list must come from the side that defines them.
  @statuses [
    :idle,
    :tracking,
    {:limited, :rate, 0.5},
    {:limited, :tool_speed, 0.25},
    {:limited, {:joint_limit, :j5}, 0.1},
    {:refused, :singular},
    {:refused, {:joint_limit, :j5}},
    {:refused, :unreadable},
    {:refused, :unknown_frame},
    {:done, :reached}
  ]

  @nodes ~w(axes.cartesian.state axes.cartesian.speed_fraction axes.cartesian.reason
            axes.cartesian.joint)

  for status <- @statuses, node <- @nodes do
    test "#{node} answers for #{inspect(status)}" do
      assert {:ok, value} = Source.cartesian_value(unquote(node), unquote(Macro.escape(status)))
      refute is_nil(value)
    end
  end

  describe "the vocabulary the model publishes" do
    test "state is one of the words the model's description lists" do
      words = ~w(idle tracking limited refused done)

      for status <- @statuses do
        assert {:ok, word} = Source.cartesian_value("axes.cartesian.state", status)

        assert word in words,
               "#{inspect(status)} projects to #{inspect(word)}, which the model does not declare"
      end
    end

    test "speed_fraction is always a fraction" do
      for status <- @statuses do
        assert {:ok, fraction} = Source.cartesian_value("axes.cartesian.speed_fraction", status)
        assert is_float(fraction)
        assert fraction >= 0.0 and fraction <= 1.0
      end
    end

    test "a stopped arm never reports speed" do
      for status <- [{:refused, :singular}, {:done, :reached}] do
        assert Source.cartesian_value("axes.cartesian.speed_fraction", status) == {:ok, 0.0}
      end
    end
  end
end
