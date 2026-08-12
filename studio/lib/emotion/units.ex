defmodule EMotion.Units do
  @moduledoc """
  The boundary between what the machine computes in and what a person reads.

  Everything inside this application — every number in a model, every value
  handed to `ExMove`, every coordinate reaching a shader — is in **canonical
  SI**: metres, radians, seconds, newtons, newton-metres. There are no
  millimetres in the model and no degrees, ever.

  Display units live at exactly two edges: parsing text a user typed, and
  formatting a value a user reads. This module owns both, and nothing else in
  the studio should be converting anything.

  ## Why this is a module and not a convention

  Mixing units is the most expensive routine bug in motion software, and it is
  expensive precisely because it does not fail. A joint commanded to 90 when it
  wanted 1.5708 does not crash; it drives the arm into a fixture. A tool offset
  entered in millimetres and stored as metres does not raise; it produces parts
  that are wrong by a factor of a thousand, days later, in a batch nobody
  re-measured.

  A bare float carries no evidence of which it is, so the discipline has to
  come from somewhere. Here it comes from making the *conversion* named and the
  *storage* uniform: a number is canonical unless it is being handed to or
  taken from a human, and that transition is always a call into this module.

  ## Using it

      iex> EMotion.Units.mm(250)
      0.25

      iex> EMotion.Units.to_mm(0.25)
      250.0

      iex> EMotion.Units.deg(90)
      1.5707963267948966

      iex> EMotion.Units.format(0.25, :length, :mm)
      "250.000 mm"

  Parsing accepts a bare number in the caller's expected unit, or an explicit
  suffix that overrides it — because a user who types `12in` into a field
  labelled mm means inches, and silently treating it as millimetres is the
  same class of failure this module exists to prevent.

      iex> EMotion.Units.parse("250", :length, :mm)
      {:ok, 0.25}

      iex> EMotion.Units.parse("1 in", :length, :mm)
      {:ok, 0.0254}

      iex> EMotion.Units.parse("banana", :length, :mm)
      {:error, :not_a_number}

  ## What this deliberately does not do

  It does not wrap values in a struct carrying their unit. That is the more
  rigorous design and it is the wrong trade here: these numbers pass through
  forward kinematics at frame rate and into binaries destined for the GPU, and
  a boxed quantity per joint per frame buys type safety at a cost paid in the
  hot path. The bargain instead is that canonical is the *only* representation
  in flight, which is a rule a reader can check locally.

  Frames are a separate problem and get a separate module: a number can be in
  metres and still be measured from the wrong origin.
  """

  @typedoc "A physical dimension this module can convert and format."
  @type dimension ::
          :length
          | :angle
          | :time
          | :linear_velocity
          | :angular_velocity
          | :linear_acceleration
          | :angular_acceleration
          | :force
          | :torque

  @typedoc "A unit a human reads or types."
  @type unit ::
          :m
          | :cm
          | :mm
          | :um
          | :in
          | :ft
          | :rad
          | :deg
          | :rev
          | :s
          | :ms
          | :min
          | :m_s
          | :mm_s
          | :in_s
          | :rad_s
          | :deg_s
          | :rpm
          | :m_s2
          | :mm_s2
          | :rad_s2
          | :deg_s2
          | :n
          | :kgf
          | :lbf
          | :nm

  # Each unit maps to {dimension, how many canonical units one of it is}.
  #
  # Conversion is therefore one multiply in each direction and there is exactly
  # one table to be wrong in, rather than a function per pair.
  @units %{
    # length -> metres
    m: {:length, 1.0},
    cm: {:length, 0.01},
    mm: {:length, 0.001},
    um: {:length, 1.0e-6},
    in: {:length, 0.0254},
    ft: {:length, 0.3048},

    # angle -> radians
    rad: {:angle, 1.0},
    deg: {:angle, :math.pi() / 180.0},
    rev: {:angle, 2.0 * :math.pi()},

    # time -> seconds
    s: {:time, 1.0},
    ms: {:time, 0.001},
    min: {:time, 60.0},

    # linear velocity -> m/s
    m_s: {:linear_velocity, 1.0},
    mm_s: {:linear_velocity, 0.001},
    in_s: {:linear_velocity, 0.0254},

    # angular velocity -> rad/s
    rad_s: {:angular_velocity, 1.0},
    deg_s: {:angular_velocity, :math.pi() / 180.0},
    rpm: {:angular_velocity, 2.0 * :math.pi() / 60.0},

    # acceleration
    m_s2: {:linear_acceleration, 1.0},
    mm_s2: {:linear_acceleration, 0.001},
    rad_s2: {:angular_acceleration, 1.0},
    deg_s2: {:angular_acceleration, :math.pi() / 180.0},

    # force -> newtons
    n: {:force, 1.0},
    kgf: {:force, 9.80665},
    lbf: {:force, 4.4482216152605},

    # torque -> newton-metres
    nm: {:torque, 1.0}
  }

  # Suffixes a user might type, mapped to the unit they mean. Longest first
  # when matching, so "mm/s2" does not match as "mm" with junk after it.
  @suffixes %{
    "mm/s2" => :mm_s2,
    "mm/s^2" => :mm_s2,
    "m/s2" => :m_s2,
    "m/s^2" => :m_s2,
    "deg/s2" => :deg_s2,
    "rad/s2" => :rad_s2,
    "mm/s" => :mm_s,
    "in/s" => :in_s,
    "m/s" => :m_s,
    "deg/s" => :deg_s,
    "°/s" => :deg_s,
    "rad/s" => :rad_s,
    "rpm" => :rpm,
    "mm" => :mm,
    "cm" => :cm,
    "um" => :um,
    "µm" => :um,
    "in" => :in,
    "\"" => :in,
    "ft" => :ft,
    "'" => :ft,
    "deg" => :deg,
    "°" => :deg,
    "rad" => :rad,
    "rev" => :rev,
    "ms" => :ms,
    "min" => :min,
    "kgf" => :kgf,
    "lbf" => :lbf,
    "nm" => :nm,
    "n" => :n,
    "m" => :m,
    "s" => :s
  }

  @doc "Every unit this module knows, as `{unit, dimension}`."
  @spec known() :: [{unit(), dimension()}]
  def known do
    @units |> Enum.map(fn {unit, {dimension, _}} -> {unit, dimension} end) |> Enum.sort()
  end

  @doc "The dimension a unit belongs to, or `:error`."
  @spec dimension(unit()) :: {:ok, dimension()} | :error
  def dimension(unit) do
    case Map.fetch(@units, unit) do
      {:ok, {dimension, _scale}} -> {:ok, dimension}
      :error -> :error
    end
  end

  # ==========================================================================
  # Into canonical
  # ==========================================================================

  @doc """
  Converts a value in `unit` to canonical units.

      iex> EMotion.Units.to_canonical(250, :mm)
      0.25

      iex> EMotion.Units.to_canonical(90, :deg)
      1.5707963267948966
  """
  @spec to_canonical(number(), unit()) :: float()
  def to_canonical(value, unit) when is_number(value) do
    value * scale!(unit)
  end

  @doc "Millimetres to metres."
  @spec mm(number()) :: float()
  def mm(value), do: to_canonical(value, :mm)

  @doc "Centimetres to metres."
  @spec cm(number()) :: float()
  def cm(value), do: to_canonical(value, :cm)

  @doc "Metres to metres. Present so a call site can say which it means."
  @spec m(number()) :: float()
  def m(value), do: value * 1.0

  @doc "Inches to metres."
  @spec inch(number()) :: float()
  def inch(value), do: to_canonical(value, :in)

  @doc "Degrees to radians."
  @spec deg(number()) :: float()
  def deg(value), do: to_canonical(value, :deg)

  @doc "Radians to radians. Present so a call site can say which it means."
  @spec rad(number()) :: float()
  def rad(value), do: value * 1.0

  @doc "Revolutions per minute to radians per second."
  @spec rpm(number()) :: float()
  def rpm(value), do: to_canonical(value, :rpm)

  @doc "Millimetres per second to metres per second."
  @spec mm_s(number()) :: float()
  def mm_s(value), do: to_canonical(value, :mm_s)

  @doc "Degrees per second to radians per second."
  @spec deg_s(number()) :: float()
  def deg_s(value), do: to_canonical(value, :deg_s)

  # ==========================================================================
  # Out of canonical
  # ==========================================================================

  @doc """
  Converts a canonical value into `unit`.

      iex> EMotion.Units.from_canonical(0.25, :mm)
      250.0
  """
  @spec from_canonical(number(), unit()) :: float()
  def from_canonical(value, unit) when is_number(value) do
    value / scale!(unit)
  end

  @doc "Metres to millimetres."
  @spec to_mm(number()) :: float()
  def to_mm(value), do: from_canonical(value, :mm)

  @doc "Metres to inches."
  @spec to_inch(number()) :: float()
  def to_inch(value), do: from_canonical(value, :in)

  @doc "Radians to degrees."
  @spec to_deg(number()) :: float()
  def to_deg(value), do: from_canonical(value, :deg)

  @doc "Radians per second to revolutions per minute."
  @spec to_rpm(number()) :: float()
  def to_rpm(value), do: from_canonical(value, :rpm)

  # ==========================================================================
  # Parsing
  # ==========================================================================

  @doc """
  Parses user text into a canonical value.

  `default` is the unit to assume when the text carries no suffix — normally
  whatever the field is labelled with. An explicit suffix always wins, and a
  suffix from the wrong dimension is an error rather than a silent conversion,
  because "50 deg" typed into a length field is a mistake worth surfacing.

      iex> EMotion.Units.parse("250", :length, :mm)
      {:ok, 0.25}

      iex> EMotion.Units.parse("0.25 m", :length, :mm)
      {:ok, 0.25}

      iex> EMotion.Units.parse("-90°", :angle, :deg)
      {:ok, -1.5707963267948966}

      iex> EMotion.Units.parse("50 deg", :length, :mm)
      {:error, {:wrong_dimension, :angle, :length}}

      iex> EMotion.Units.parse("", :length, :mm)
      {:error, :empty}
  """
  @spec parse(String.t(), dimension(), unit()) ::
          {:ok, float()}
          | {:error, :empty | :not_a_number | {:wrong_dimension, dimension(), dimension()}}
  def parse(text, dimension, default) when is_binary(text) do
    trimmed = text |> String.trim() |> String.replace(",", "")

    if trimmed == "" do
      {:error, :empty}
    else
      {number_text, unit} = split_suffix(trimmed, default)

      with {:ok, value} <- to_number(number_text),
           {:ok, ^dimension} <- check_dimension(unit, dimension) do
        {:ok, to_canonical(value, unit)}
      end
    end
  end

  @doc """
  `parse/3` or the given fallback.

  For a text field that should keep its last good value rather than reject a
  half-typed number on every keystroke.
  """
  @spec parse_or(String.t(), dimension(), unit(), float()) :: float()
  def parse_or(text, dimension, default_unit, fallback) do
    case parse(text, dimension, default_unit) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end

  # ==========================================================================
  # Formatting
  # ==========================================================================

  @doc """
  Renders a canonical value in `unit`, with its suffix.

  ## Options

    * `:decimals` - default 3 for length, 2 otherwise
    * `:suffix` - include the unit, default `true`

      iex> EMotion.Units.format(0.25, :length, :mm)
      "250.000 mm"

      iex> EMotion.Units.format(1.5707963267948966, :angle, :deg, decimals: 1)
      "90.0°"

      iex> EMotion.Units.format(0.25, :length, :mm, suffix: false)
      "250.000"
  """
  @spec format(number(), dimension(), unit(), keyword()) :: String.t()
  def format(value, dimension, unit, opts \\ []) do
    {:ok, ^dimension} = check_dimension(unit, dimension)

    decimals = Keyword.get(opts, :decimals, default_decimals(dimension))
    shown = value |> from_canonical(unit) |> :erlang.float_to_binary(decimals: decimals)

    if Keyword.get(opts, :suffix, true) do
      shown <> suffix(unit)
    else
      shown
    end
  end

  @doc """
  The suffix for a unit, including the space that should precede it.

  Degrees are the exception: `90°` rather than `90 °`, because that is how
  every drawing and every teach pendant in the world writes it.
  """
  @spec suffix(unit()) :: String.t()
  def suffix(:deg), do: "°"
  def suffix(:deg_s), do: "°/s"
  def suffix(:deg_s2), do: "°/s²"
  def suffix(:m_s), do: " m/s"
  def suffix(:mm_s), do: " mm/s"
  def suffix(:in_s), do: " in/s"
  def suffix(:rad_s), do: " rad/s"
  def suffix(:m_s2), do: " m/s²"
  def suffix(:mm_s2), do: " mm/s²"
  def suffix(:rad_s2), do: " rad/s²"
  def suffix(:um), do: " µm"
  def suffix(:nm), do: " N·m"
  def suffix(:n), do: " N"
  def suffix(unit), do: " " <> Atom.to_string(unit)

  # ==========================================================================
  # Display preferences
  # ==========================================================================

  defmodule Display do
    @moduledoc """
    Which units this operator reads.

    A preference, so it belongs in the model and never in a stored value. Two
    people can have the same cell open in millimetres and inches, and the file
    on disk is identical.
    """

    @type t :: %__MODULE__{
            length: EMotion.Units.unit(),
            angle: EMotion.Units.unit(),
            linear_velocity: EMotion.Units.unit(),
            angular_velocity: EMotion.Units.unit()
          }

    defstruct length: :mm,
              angle: :deg,
              linear_velocity: :mm_s,
              angular_velocity: :deg_s
  end

  @doc "The display unit a preference set uses for a dimension."
  @spec unit_for(Display.t(), dimension()) :: unit()
  def unit_for(%Display{} = display, :length), do: display.length
  def unit_for(%Display{} = display, :angle), do: display.angle
  def unit_for(%Display{} = display, :linear_velocity), do: display.linear_velocity
  def unit_for(%Display{} = display, :angular_velocity), do: display.angular_velocity

  @doc """
  Formats a canonical value in whichever unit the operator prefers.

      iex> EMotion.Units.show(0.25, :length, %EMotion.Units.Display{})
      "250.000 mm"

      iex> EMotion.Units.show(0.25, :length, %EMotion.Units.Display{length: :in})
      "9.843 in"
  """
  @spec show(number(), dimension(), Display.t(), keyword()) :: String.t()
  def show(value, dimension, %Display{} = display, opts \\ []) do
    format(value, dimension, unit_for(display, dimension), opts)
  end

  # ==========================================================================

  defp scale!(unit) do
    case Map.fetch(@units, unit) do
      {:ok, {_dimension, scale}} ->
        scale

      :error ->
        raise ArgumentError,
              "unknown unit #{inspect(unit)}; known: #{inspect(Enum.map(known(), &elem(&1, 0)))}"
    end
  end

  defp check_dimension(unit, expected) do
    case dimension(unit) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, actual} -> {:error, {:wrong_dimension, actual, expected}}
      :error -> {:error, :not_a_number}
    end
  end

  # Longest suffix first, so "mm/s" is not read as "m" with a stray tail.
  defp split_suffix(text, default) do
    lowered = String.downcase(text)

    match =
      @suffixes
      |> Map.keys()
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.find(fn suffix -> String.ends_with?(lowered, suffix) end)

    case match do
      nil ->
        {text, default}

      suffix ->
        {String.slice(text, 0, String.length(text) - String.length(suffix)),
         Map.fetch!(@suffixes, suffix)}
    end
  end

  defp to_number(text) do
    trimmed = String.trim(text)

    case Float.parse(trimmed) do
      {value, ""} ->
        {:ok, value}

      _ ->
        case Integer.parse(trimmed) do
          {value, ""} -> {:ok, value * 1.0}
          _ -> {:error, :not_a_number}
        end
    end
  end

  defp default_decimals(:length), do: 3
  defp default_decimals(_other), do: 2
end
