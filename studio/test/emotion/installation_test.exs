defmodule EMotion.InstallationTest do
  @moduledoc """
  The `.emi` backup: what it carries, what identifies it, and the one question
  a dated backup exists to answer.
  """
  use ExUnit.Case, async: true

  alias EMotion.Installation

  defp mastering(axis, offset, state \\ "referenced") do
    %{"axis" => axis, "state" => state, "offset" => offset, "drift" => 0.0}
  end

  defp installation do
    %Installation{
      robot: %{"name" => "arctos", "urdf" => "<robot name=\"arctos\"/>"},
      joints: [
        %{"joint" => "joint1", "axis" => "j1", "max_vel" => 1.57, "max_acc" => 5.0,
          "soft_lower" => -3.05, "soft_upper" => 3.05, "home" => 0.0},
        %{"joint" => "joint2", "axis" => "j2", "max_vel" => 1.05, "max_acc" => 4.0,
          "soft_lower" => -3.05, "soft_upper" => 3.05, "home" => 0.0}
      ],
      frames: [
        %{"name" => "fixture", "parent" => "", "x" => 0.3, "y" => 0.0, "z" => 0.0,
          "rx" => 0.0, "ry" => 0.0, "rz" => 1.5707963},
        %{"name" => "bench", "parent" => "", "x" => 0.55, "y" => 0.0, "z" => 0.0,
          "rx" => 0.0, "ry" => 0.0, "rz" => 0.0}
      ],
      tools: [%{"name" => "welder", "fitted" => true, "x" => 0.0, "y" => 0.0, "z" => 0.35,
                "rx" => 0.0, "ry" => 0.0, "rz" => 0.0}],
      mastering: [mastering("j1", 0.0), mastering("j2", 0.125)],
      taken_at: "2026-03-01T09:00:00Z"
    }
  end

  describe "printing" do
    test "sections by the three categories the document defines" do
      text = Installation.print(installation())

      assert text =~ "installation arctos"
      assert text =~ "\nrobot\n"
      assert text =~ "\njoints\n"
      assert text =~ "\nframes\n"
      assert text =~ "\ntools\n"
      assert text =~ "\nmastering\n"
    end

    test "joints keep chain order, base to tip" do
      # Alphabetical would put joint10 between joint1 and joint2 and make a
      # six-axis arm read as a list of strings.
      text = Installation.print(installation())
      assert :binary.match(text, "joint1") < :binary.match(text, "joint2")
    end

    test "frames are sorted by name, because they have no natural order" do
      text = Installation.print(installation())
      assert :binary.match(text, "bench") < :binary.match(text, "fixture")
    end

    test "mastering leads with the state, not the number" do
      # An offset on an unmastered axis is not a small offset; it is not an
      # offset. The word decides whether the number means anything.
      text = Installation.print(installation())
      assert text =~ ~r/j2\s+referenced\s+offset=0\.125000000/
    end

    test "the urdf is hashed rather than printed" do
      text = Installation.print(installation())
      refute text =~ "<robot"
      assert text =~ ~r/urdf=[0-9a-f]{12} \(\d+ bytes\)/
    end

    test "a controller nobody commissioned still prints" do
      text = Installation.print(%Installation{})
      assert text =~ "installation uncommissioned"
    end
  end

  describe "identity" do
    test "the same machine hashes the same" do
      assert Installation.hash(installation()) == Installation.hash(installation())
    end

    test "when the backup was taken is not part of the machine" do
      # The property that makes "did anything change since March" answerable:
      # two backups of an unchanged machine must agree however far apart.
      later = %{installation() | taken_at: "2026-06-01T17:30:00Z"}
      assert Installation.hash(later) == Installation.hash(installation())
    end

    test "a moved frame changes it" do
      moved = %{installation() | frames: [%{"name" => "fixture", "parent" => "", "x" => 0.304,
                                            "y" => 0.0, "z" => 0.0, "rx" => 0.0, "ry" => 0.0,
                                            "rz" => 1.5707963}]}
      assert Installation.hash(moved) != Installation.hash(installation())
    end

    test "a re-mastered axis changes it" do
      remastered = %{installation() | mastering: [mastering("j1", 0.0), mastering("j2", 0.130)]}
      assert Installation.hash(remastered) != Installation.hash(installation())
    end

    test "a different urdf changes it even though the text is not printed" do
      # Otherwise a re-commissioned arm backs up identically to the one it
      # replaced, which is the failure the digest exists to prevent.
      other = %{installation() | robot: %{"name" => "arctos", "urdf" => "<robot name=\"other\"/>"}}
      assert Installation.hash(other) != Installation.hash(installation())
    end
  end

  describe "the file" do
    test "round-trips and keeps its hash" do
      {:ok, back} = installation() |> Installation.to_json() |> Installation.from_json()
      assert Installation.hash(back) == Installation.hash(installation())
      assert back.taken_at == "2026-03-01T09:00:00Z"
    end

    test "carries its own hash and is checked on load" do
      tampered =
        installation()
        |> Installation.to_json()
        |> Jason.decode!()
        |> put_in(["mastering", Access.at(0), "offset"], 0.4)
        |> Jason.encode!()

      assert {:error, {:hash_mismatch, _, _}} = Installation.from_json(tampered)
    end

    test "a program file is not an installation file" do
      raw = Jason.encode!(%{"format" => "emotion.program", "formatVersion" => 1})
      assert {:error, :not_an_installation_file} = Installation.from_json(raw)
    end

    test "a newer format is refused rather than half-read" do
      raw =
        installation() |> Installation.to_json() |> Jason.decode!()
        |> Map.put("formatVersion", 99) |> Jason.encode!()

      assert {:error, {:format_too_new, 99}} = Installation.from_json(raw)
    end

    test "save and load through the filesystem" do
      path = Path.join(System.tmp_dir!(), "inst_#{System.unique_integer([:positive])}.emi")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Installation.save(installation(), path)
      assert {:ok, back} = Installation.load(path)
      assert Installation.hash(back) == Installation.hash(installation())
    end

    test "names the file after the robot" do
      assert Installation.filename(installation()) == "arctos.emi"
      assert Installation.filename(%Installation{}) == "uncommissioned.emi"
    end
  end

  describe "comparing two backups" do
    test "an axis that was re-mastered in between" do
      # The reason a dated backup is worth keeping: answerable off the machine,
      # in a diff, without the controller.
      june = %{installation() | mastering: [mastering("j1", 0.0), mastering("j2", 0.130)]}
      assert [{:changed, "j2", 0.125, 0.13}] = Installation.compare_mastering(installation(), june)
    end

    test "an axis that has gone" do
      june = %{installation() | mastering: [mastering("j1", 0.0)]}
      assert [{:lost, "j2", 0.125}] = Installation.compare_mastering(installation(), june)
    end

    test "an axis that has appeared" do
      june = %{installation() | mastering: installation().mastering ++ [mastering("j3", 0.2)]}
      assert [{:new, "j3", 0.2}] = Installation.compare_mastering(installation(), june)
    end

    test "an unchanged machine reports nothing" do
      assert Installation.compare_mastering(installation(), installation()) == []
    end

    test "a state change alone is a change" do
      # An axis that still reports the same number but is no longer referenced
      # has changed in the way that matters.
      june = %{installation() | mastering: [mastering("j1", 0.0),
                                            mastering("j2", 0.125, "unreferenced")]}
      assert [{:changed, "j2", 0.125, 0.125}] = Installation.compare_mastering(installation(), june)
    end

    test "a difference too small to change the hash is not reported" do
      # Compared through the same rounding the hash uses, so this cannot report
      # a difference nothing else in the system can see.
      june = %{installation() | mastering: [mastering("j1", 0.0), mastering("j2", 0.125 + 1.0e-12)]}
      assert Installation.compare_mastering(installation(), june) == []
      assert Installation.hash(june) == Installation.hash(installation())
    end
  end
end
