defmodule EMotion.Program.Kinds do
  @moduledoc """
  The vocabulary a program is written in.

  Four kinds, deliberately. There is no `set` because there is no I/O, and
  saying so is more useful than shipping a statement that cannot do anything —
  the first program a controller runs is a motion sequence, and that is the
  thing worth proving runs with nobody watching.

  ## Motion and barriers

  `motion?` is not decoration. It is what the executor reads to decide whether a
  statement may be queued ahead of the arm or has to wait for it: motion
  statements look ahead so blending works, and everything else is a barrier.
  `PROGRAMS.md` §5 argues why, and the short version is that `wait 2 seconds`
  must mean the arm stands still for two seconds rather than two seconds
  beginning somewhere earlier.
  """

  alias EMotion.Program.Kind

  @kinds [
    %Kind{
      name: "move_joint",
      label: "Move Joint",
      motion?: true,
      description:
        "Replay the joint solution this point was taught in. The one motion " <>
          "that cannot arrive on a different configuration from the one taught, " <>
          "because it does not solve anything — it commands the six angles that " <>
          "were recorded.",
      params: [
        %{name: "point", type: :point, required: true, description: "Where to go"}
      ]
    },
    %Kind{
      name: "move_linear",
      label: "Move Linear",
      motion?: true,
      description:
        "Travel in a straight line to a point. Under every limit in " <>
          "CARTESIAN.md: the rate ceiling, the joint-limit stop, the tool speed " <>
          "cap and the singularity refusal.",
      params: [
        %{name: "point", type: :point, required: true, description: "Where to go"},
        %{
          name: "feedrate",
          type: :velocity,
          required: false,
          default: 0.125,
          description: "Tool speed along the path, m/s"
        },
        %{
          name: "blend",
          type: :length,
          required: false,
          description:
            "Radius within which this move gives way to the next. Omitted, the " <>
              "move stops on its point — FINE against CNT."
        }
      ]
    },
    %Kind{
      name: "move_arc",
      label: "Move Arc",
      motion?: true,
      description:
        "Travel along the circle through where the arm is, a via point, and an " <>
          "end point. Three points that do not define a circle are refused " <>
          "rather than approximated.",
      params: [
        %{name: "via", type: :point, required: true, description: "A point the arc passes through"},
        %{name: "point", type: :point, required: true, description: "Where the arc ends"},
        %{name: "feedrate", type: :velocity, required: false, default: 0.125},
        %{name: "blend", type: :length, required: false}
      ]
    },
    %Kind{
      name: "wait",
      label: "Wait",
      motion?: false,
      description:
        "Stand still for a fixed time. A barrier: the arm has arrived and the " <>
          "queue is empty before the clock starts, which is the only reading of " <>
          "this statement that is not a surprise.",
      params: [
        %{
          name: "seconds",
          type: :duration,
          required: true,
          description: "How long to wait, seconds"
        }
      ]
    }
  ]

  @by_name Map.new(@kinds, &{&1.name, &1})

  @doc "Every registered kind."
  def all, do: @kinds

  @doc "A kind by name, or nil. `nil` is how an unloaded extension shows up."
  def get(name) when is_binary(name), do: Map.get(@by_name, name)

  def known?(name) when is_binary(name), do: Map.has_key?(@by_name, name)

  @doc "Whether this kind may be queued ahead of the arm."
  def motion?(name) when is_binary(name) do
    case get(name) do
      nil -> false
      kind -> kind.motion?
    end
  end
end
