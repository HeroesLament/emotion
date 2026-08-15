defmodule EMotion.Pendant do
  @moduledoc """
  The jog panel: what it holds, and what it draws.

  A pure module, like `EMotion.Controllers`. It decides what the pane shows and
  which controls are live; `EMotion.Jog` does the holding and `EMotion.Link`
  does the talking. Nothing here has a clock or a socket, which is what makes
  the whole panel testable without either.

  ## What it borrows from real pendants, and what it refuses to

  A teach pendant is a physical object with physical buttons, and the parts of
  that worth copying are the parts that are about the machine rather than about
  the plastic. Six axes in a fixed order, each with a minus and a plus, because
  an operator learns where J4 is and should never have to look. A speed
  override that applies to everything and is always visible, because "how fast
  will this move when I press it" must never be a question. A readout beside
  each axis, because a jog with no feedback is an open loop with a person in it.

  What it refuses is the pretence of safety. There is no enabling-device
  simulation here, no three-position switch drawn on a screen. A mouse button
  is not a hold-to-run device and calling it one would be worse than not having
  one, because it invites somebody to treat this panel as a protective measure.
  It is a convenience that stops when you let go. The E-stop is a hardware
  circuit and is not in this window.

  ## Presence is the capability

  The axis list comes from the cell that is loaded, not from a constant here,
  and eventually should come from browsing the connected controller — which
  publishes exactly the axes it has and exactly the commands each one accepts.
  A pendant that draws six joints because six is a common number will be wrong
  in front of the first five-axis machine it meets.
  """

  alias EMotion.Units

  @default_axes ~w(j1 j2 j3 j4 j5 j6)

  @typedoc """
  `held` is the axis currently being jogged, or nil. It is what the controller
  is being told, not what the button looks like: the button follows it.
  """
  @type t :: %__MODULE__{}

  defstruct axes: @default_axes,
            held: nil,
            direction: nil,
            speed: 0.25,
            positions: %{},
            status: "Not connected"

  @speeds [0.05, 0.10, 0.25, 0.50, 1.00]

  @doc "A pendant for the axes this cell actually has."
  @spec new(term()) :: t()
  def new(cell \\ nil), do: %__MODULE__{axes: axes(cell)}

  @doc """
  The axes to draw, from the loaded cell.

  Falls back to six joints only when there is no cell at all — a Studio that
  has not opened anything yet still draws a pendant, and drawing an empty one
  looks broken rather than honest.
  """
  @spec axes(term()) :: [String.t()]
  def axes(%{robots: robots}) when map_size(robots) > 0 do
    robots
    |> Map.values()
    |> List.first()
    |> case do
      %{joints: joints} when joints != [] ->
        for i <- 1..length(joints), do: "j#{i}"

      _ ->
        @default_axes
    end
  end

  def axes(_cell), do: @default_axes

  @doc "The speed steps the override cycles through, as fractions."
  @spec speeds() :: [float()]
  def speeds, do: @speeds

  @doc "The override one step slower, or the slowest."
  @spec slower(t()) :: t()
  def slower(pendant), do: %{pendant | speed: step(pendant.speed, -1)}

  @doc "The override one step faster, or the fastest."
  @spec faster(t()) :: t()
  def faster(pendant), do: %{pendant | speed: step(pendant.speed, 1)}

  defp step(speed, by) do
    index = Enum.find_index(@speeds, &(&1 >= speed)) || 0
    Enum.at(@speeds, (index + by) |> max(0) |> min(length(@speeds) - 1))
  end

  @doc "Records that an axis is being held."
  @spec hold(t(), String.t(), -1 | 1) :: t()
  def hold(pendant, axis, direction) do
    %{pendant | held: axis, direction: direction}
  end

  @doc "Records that nothing is being held."
  @spec release(t()) :: t()
  def release(pendant), do: %{pendant | held: nil, direction: nil}

  @doc "Records fresh positions, keyed by axis."
  @spec positions(t(), %{String.t() => float()}) :: t()
  def positions(pendant, positions), do: %{pendant | positions: positions}

  @doc """
  How each axis reads, for display.

  Degrees, because a pendant is for a person and nobody jogs in radians. The
  wire stays SI — see `ExMo.Schema.FromAxis` on why that is not negotiable —
  and this is the one place allowed to convert.
  """
  @spec readout(t(), String.t()) :: String.t()
  def readout(pendant, axis) do
    case Map.get(pendant.positions, axis) do
      nil -> "—"
      radians -> :erlang.float_to_binary(Units.to_deg(radians), decimals: 1) <> "°"
    end
  end

  @doc "The override, as a percentage for display."
  @spec speed_label(t()) :: String.t()
  def speed_label(pendant), do: "#{round(pendant.speed * 100)}%"

  @doc """
  Whether the jog controls should be live.

  Connection only. Not "is anything already held" — a second button going down
  while one is held is handled by releasing the first, and greying out the
  other eleven buttons the instant a jog starts would make the panel flicker
  every time somebody used it.
  """
  @spec enabled?(t(), boolean()) :: boolean()
  def enabled?(_pendant, connected?), do: connected?
end
