defmodule ExAuth.RoleTest do
  use ExUnit.Case, async: true

  alias ExAuth.{Grant, Role}

  describe "the grant vocabulary" do
    test "every role references only grants that exist" do
      for role <- Role.all() do
        unknown = role |> Role.grants() |> Enum.reject(&Grant.known?/1)
        assert unknown == [], "#{role} references unknown grants: #{inspect(unknown)}"
      end
    end

    test "every grant is described, so an admin UI never shows a bare atom" do
      for grant <- Grant.all() do
        assert is_binary(Grant.describe(grant))
      end
    end

    test "parsing from the wire does not invent atoms" do
      assert Grant.parse("calibrate") == {:ok, :calibrate}
      assert Grant.parse("definitely_not_a_grant") == :error
      assert Role.parse("operator") == {:ok, :operator}
      assert Role.parse("root") == :error
    end
  end

  describe "the safety rule" do
    test "no role bundles safety configuration with motion" do
      for role <- Role.all() do
        grants = Role.grants(role)

        if Grant.safety_grant() in grants do
          motion = Enum.filter(Grant.motion_grants(), &(&1 in grants))

          assert motion == [],
                 "#{role} can configure safety AND #{inspect(motion)}"
        end
      end
    end

    test "administrator specifically cannot configure safety" do
      # ABB's FullAccess excludes Safety Controller configuration for the same
      # reason. If someone 'fixes' this by adding the grant, this test is the
      # conversation about why they should not.
      refute Grant.safety_grant() in Role.grants(:administrator)
    end

    test "safety_officer cannot move the arm" do
      grants = Role.grants(:safety_officer)
      assert Grant.safety_grant() in grants

      for motion <- Grant.motion_grants() do
        refute motion in grants, "safety_officer should not hold #{motion}"
      end
    end
  end

  describe "the ladder" do
    test "each rung contains the one below it" do
      pairs = [
        {:observer, :operator},
        {:operator, :programmer},
        {:programmer, :maintainer},
        {:maintainer, :administrator}
      ]

      for {lower, higher} <- pairs do
        assert MapSet.subset?(Role.grants(lower), Role.grants(higher)),
               "#{higher} should contain everything #{lower} has"
      end
    end

    test "observer cannot write anything" do
      grants = Role.grants(:observer)

      for grant <- [:write_setpoint, :jog, :enable_drives, :calibrate, :write_configuration] do
        refute grant in grants
      end
    end

    test "an unknown role grants nothing rather than everything" do
      assert Role.grants(:wheelbarrow) == MapSet.new()
    end
  end
end
