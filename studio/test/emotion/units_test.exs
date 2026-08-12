defmodule EMotion.UnitsTest do
  @moduledoc """
  The unit boundary, tested hard, because nothing downstream of it will fail
  loudly when it is wrong.
  """

  use ExUnit.Case, async: true

  alias EMotion.Units
  alias EMotion.Units.Display

  doctest EMotion.Units

  defp close?(a, b, tolerance \\ 1.0e-9), do: abs(a - b) <= tolerance

  describe "conversion" do
    test "round trips through every known unit" do
      # The property that matters: a value out and back is the value. A wrong
      # scale factor in the table survives every individual conversion test
      # that uses the same factor in both directions - but not this one, as
      # long as the canonical value is chosen and not derived.
      for {unit, _dimension} <- Units.known() do
        canonical = 0.37

        assert close?(Units.to_canonical(Units.from_canonical(canonical, unit), unit), canonical),
               "#{unit} does not round trip"
      end
    end

    test "length anchors on values people know" do
      assert close?(Units.mm(1000), 1.0)
      assert close?(Units.inch(1), 0.0254)
      assert close?(Units.to_inch(0.0254), 1.0)

      # A foot is exactly twelve inches by definition - and the two
      # conversions still differ in the last bits, because 12 * 0.0254 is not
      # exactly representable in binary floating point even though both
      # operands are. Worth knowing before someone writes an equality check
      # against a nominal dimension and watches it fail on one machine.
      assert close?(Units.to_canonical(12, :in), Units.to_canonical(1, :ft))
      refute Units.to_canonical(12, :in) == Units.to_canonical(1, :ft)
    end

    test "angle anchors on values people know" do
      assert close?(Units.deg(180), :math.pi())
      assert close?(Units.to_deg(:math.pi() / 2), 90.0)
      assert close?(Units.to_canonical(1, :rev), 2 * :math.pi())
    end

    test "rpm is the one everyone gets wrong" do
      # 60 rpm is one revolution per second is 2π rad/s. Off by 2π or by 60 is
      # the classic, and both are a factor that looks plausible on a plot.
      assert close?(Units.rpm(60), 2 * :math.pi())
      assert close?(Units.to_rpm(2 * :math.pi()), 60.0)
    end

    test "an unknown unit says what it knows" do
      assert_raise ArgumentError, ~r/unknown unit :furlong/, fn ->
        Units.to_canonical(1, :furlong)
      end
    end

    test "every unit belongs to exactly one dimension" do
      for {unit, dimension} <- Units.known() do
        assert {:ok, ^dimension} = Units.dimension(unit)
      end
    end
  end

  describe "parse/3" do
    test "a bare number takes the field's unit" do
      assert {:ok, value} = Units.parse("250", :length, :mm)
      assert close?(value, 0.25)
    end

    test "an explicit suffix overrides the field's unit" do
      # The case this exists for: a field labelled mm, a user who thinks in
      # inches. Treating "12in" as 12mm is the failure mode.
      assert {:ok, value} = Units.parse("12 in", :length, :mm)
      assert close?(value, 0.3048)
    end

    test "the suffix may be jammed against the number" do
      assert {:ok, a} = Units.parse("250mm", :length, :mm)
      assert {:ok, b} = Units.parse("250 mm", :length, :mm)
      assert a == b
    end

    test "handles the symbols people actually type" do
      assert {:ok, deg} = Units.parse("90°", :angle, :rad)
      assert close?(deg, :math.pi() / 2)

      assert {:ok, inches} = Units.parse("2\"", :length, :mm)
      assert close?(inches, 0.0508)
    end

    test "is case insensitive about suffixes" do
      assert Units.parse("100 MM", :length, :mm) == Units.parse("100 mm", :length, :mm)

      assert Units.parse("50 RPM", :angular_velocity, :rpm) ==
               Units.parse("50 rpm", :angular_velocity, :rpm)
    end

    test "the longest suffix wins" do
      # "mm/s" must not be read as "m" with a stray tail, which would be off
      # by a thousand and still parse.
      assert {:ok, value} = Units.parse("500 mm/s", :linear_velocity, :m_s)
      assert close?(value, 0.5)
    end

    test "negatives and decimals survive" do
      assert {:ok, value} = Units.parse("-12.5 mm", :length, :mm)
      assert close?(value, -0.0125)
    end

    test "thousands separators are tolerated" do
      assert {:ok, value} = Units.parse("1,250 mm", :length, :mm)
      assert close?(value, 1.25)
    end

    test "a suffix from the wrong dimension is refused, not converted" do
      # Silently accepting this is how a tool offset becomes an angle.
      assert {:error, {:wrong_dimension, :angle, :length}} =
               Units.parse("50 deg", :length, :mm)
    end

    test "nonsense is an error rather than zero" do
      assert {:error, :not_a_number} = Units.parse("banana", :length, :mm)
      assert {:error, :not_a_number} = Units.parse("12 34", :length, :mm)
      assert {:error, :empty} = Units.parse("   ", :length, :mm)
    end

    test "parse_or keeps a last good value" do
      assert Units.parse_or("nonsense", :length, :mm, 0.5) == 0.5
      assert close?(Units.parse_or("250", :length, :mm, 0.5), 0.25)
    end

    test "parsing then formatting is stable" do
      {:ok, canonical} = Units.parse("123.456 mm", :length, :mm)

      assert Units.format(canonical, :length, :mm) == "123.456 mm"
    end
  end

  describe "format/4" do
    test "renders in the requested unit with a suffix" do
      assert Units.format(0.25, :length, :mm) == "250.000 mm"
      assert Units.format(:math.pi(), :angle, :deg, decimals: 1) == "180.0°"
    end

    test "the suffix can be suppressed for a text field" do
      assert Units.format(0.25, :length, :mm, suffix: false) == "250.000"
    end

    test "degrees hug their symbol, everything else takes a space" do
      assert Units.format(0.0, :angle, :deg) == "0.00°"
      assert Units.format(0.0, :length, :mm) =~ " mm"
    end

    test "formatting in a unit of the wrong dimension is a bug, not a coercion" do
      assert_raise MatchError, fn -> Units.format(0.25, :length, :deg) end
    end
  end

  describe "Display" do
    test "defaults are what a shop floor expects" do
      display = %Display{}

      assert display.length == :mm
      assert display.angle == :deg
    end

    test "show/4 renders in the operator's units" do
      assert Units.show(0.25, :length, %Display{}) == "250.000 mm"
      assert Units.show(0.25, :length, %Display{length: :in}) == "9.843 in"
    end

    test "a preference changes only the rendering" do
      # The point of keeping display units out of stored values: two operators
      # with different preferences are looking at the same number.
      metric = Units.show(0.3048, :length, %Display{length: :mm})
      imperial = Units.show(0.3048, :length, %Display{length: :in})

      assert metric == "304.800 mm"
      assert imperial == "12.000 in"
    end
  end

  describe "the ExMove boundary" do
    test "canonical units are what ExMove already speaks" do
      # ExMove.Frame documents metres and radians, and ExMove.Joint documents
      # radians, m/s and rad/s². This module's canonical set is chosen to match
      # exactly, so crossing that boundary is never a conversion.
      frame = %ExMove.Frame{x: Units.mm(250), rz: Units.deg(90)}

      assert close?(frame.x, 0.25)
      assert close?(frame.rz, :math.pi() / 2)
    end
  end
end
