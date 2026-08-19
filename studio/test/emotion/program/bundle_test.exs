defmodule EMotion.Program.BundleTest do
  @moduledoc """
  The standalone program file: what it carries, what identifies it, and what it
  refuses.
  """
  use ExUnit.Case, async: true

  alias EMotion.Program.{Bundle, Printer}

  defp statement(seq, kind, args, refs \\ []) do
    %{"seq" => seq, "kind" => kind, "args" => args, "refs" => refs}
  end

  defp point(name, x) do
    %{
      "name" => name,
      "frame" => "base",
      "tool" => "welder",
      "base_x" => x,
      "base_y" => 0.0,
      "base_z" => 0.2,
      "base_rx" => 0.0,
      "base_ry" => 0.0,
      "base_rz" => 0.0
    }
  end

  defp bundle do
    %Bundle{
      name: "pick",
      statements: [
        statement(0, "move_joint", [%{"name" => "point", "value" => "home"}], [
          %{"arg" => "point", "kind" => "point", "name" => "home"}
        ]),
        statement(1, "wait", [%{"name" => "seconds", "value" => "0.3"}]),
        statement(2, "move_joint", [%{"name" => "point", "value" => "away"}], [
          %{"arg" => "point", "kind" => "point", "name" => "away"}
        ])
      ],
      points: [point("away", 0.4), point("home", 0.1)],
      frames: [%{"name" => "base"}],
      tools: [%{"name" => "welder"}]
    }
  end

  describe "printing" do
    test "renders the body and the data it depends on" do
      text = Printer.print(bundle())

      assert text =~ "program pick"
      assert text =~ "move_joint   point: home"
      assert text =~ "wait         seconds: 0.3"
      assert text =~ "points"
      assert text =~ "home  in base tool=welder"
    end

    test "is deterministic regardless of the order rows arrive in" do
      # A database is under no obligation to hand rows back in the same order
      # twice, and a fingerprint that depends on that is not a fingerprint.
      shuffled = %{bundle() | points: Enum.reverse(bundle().points),
                              statements: Enum.reverse(bundle().statements)}

      assert Printer.print(bundle()) == Printer.print(shuffled)
    end

    test "an empty program still prints" do
      # Total, per PROGRAMS.md: printing cannot fail. An empty body is a
      # program someone just created, not an error.
      text = Printer.print(%Bundle{name: "new", statements: []})
      assert text =~ "program new"
      assert text =~ "(empty)"
    end
  end

  describe "identity" do
    test "the same program hashes the same" do
      assert Bundle.hash(bundle()) == Bundle.hash(bundle())
    end

    test "two programs with the same name and different bodies differ" do
      # A name is a label. This is the identity.
      other = %{bundle() | statements: Enum.take(bundle().statements, 2)}
      assert Bundle.hash(bundle()) != Bundle.hash(other)
    end

    test "moving a point changes the program's hash" do
      # The property the whole bundle exists for. A program whose weld_start
      # shifted four millimetres is a different program in the only sense
      # anyone cares about: what the arm will do.
      moved = %{bundle() | points: [point("away", 0.4), point("home", 0.104)]}

      assert Bundle.hash(bundle()) != Bundle.hash(moved),
             "a hash over the body alone would call these identical"
    end

    test "a four-millimetre move is visible, not rounded away" do
      a = %{bundle() | points: [point("home", 0.100)]}
      b = %{bundle() | points: [point("home", 0.104)]}
      assert Bundle.hash(a) != Bundle.hash(b)
    end

    test "the short hash is the front of the long one" do
      b = bundle()
      assert String.starts_with?(Bundle.hash(b), Bundle.short_hash(b))
      assert String.length(Bundle.short_hash(b)) == 12
    end
  end

  describe "the file" do
    test "round-trips losslessly" do
      {:ok, back} = bundle() |> Bundle.to_json() |> Bundle.from_json()

      assert back.name == bundle().name
      assert back.statements == bundle().statements
      assert back.points == bundle().points
      assert Bundle.hash(back) == Bundle.hash(bundle())
    end

    test "a float surviving JSON does not move the hash" do
      # 0.1 does not have an exact double, and encoders disagree about how to
      # print it. The printer's fixed precision is what makes this hold.
      {:ok, back} = bundle() |> Bundle.to_json() |> Bundle.from_json()
      assert Bundle.hash(back) == Bundle.hash(bundle())
    end

    test "saving an unchanged bundle produces an unchanged file" do
      # What makes `git diff` mean something.
      assert Bundle.to_json(bundle()) == Bundle.to_json(bundle())
    end

    test "carries its own hash" do
      assert %{"hash" => hash} = Jason.decode!(Bundle.to_json(bundle()))
      assert hash == Bundle.hash(bundle())
    end

    test "a file edited by something that did not understand it is refused" do
      # Quietly accepting a stale hash would make the fingerprint worthless
      # exactly when it matters.
      tampered =
        bundle()
        |> Bundle.to_json()
        |> Jason.decode!()
        |> Map.put("name", "something_else")
        |> Jason.encode!()

      assert {:error, {:hash_mismatch, _stored, _actual}} = Bundle.from_json(tampered)
    end

    test "a file with no hash is accepted — hand-written is allowed" do
      raw =
        bundle() |> Bundle.to_json() |> Jason.decode!() |> Map.delete("hash") |> Jason.encode!()

      assert {:ok, back} = Bundle.from_json(raw)
      assert back.name == "pick"
    end

    test "some other JSON file is refused by name" do
      assert {:error, :not_a_program_file} = Bundle.from_json(~s({"hello": "world"}))
    end

    test "a file from a newer Studio is refused rather than half-read" do
      raw =
        bundle()
        |> Bundle.to_json()
        |> Jason.decode!()
        |> Map.put("formatVersion", 99)
        |> Jason.encode!()

      assert {:error, {:format_too_new, 99}} = Bundle.from_json(raw)
    end

    test "invalid JSON fails as JSON, not as a crash" do
      assert {:error, %Jason.DecodeError{}} = Bundle.from_json("{not json")
    end

    test "save and load through the filesystem" do
      path = Path.join(System.tmp_dir!(), "bundle_test_#{System.unique_integer([:positive])}.emp")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Bundle.save(bundle(), path)
      assert {:ok, back} = Bundle.load(path)
      assert Bundle.hash(back) == Bundle.hash(bundle())
    end

    test "suggests a filename that is safe to write" do
      assert Bundle.filename(bundle()) == "pick.emp"
      assert Bundle.filename(%Bundle{name: "weld/../etc"}) == "weld_.._etc.emp"
    end
  end

  describe "references" do
    test "groups what the statements name, by kind" do
      assert %{"point" => points} = Bundle.referenced(bundle().statements)
      assert MapSet.equal?(points, MapSet.new(["home", "away"]))
    end

    test "a pulled bundle is complete" do
      assert Bundle.dangling(bundle()) == []
    end

    test "a bundle missing a point it names says which one" do
      broken = %{bundle() | points: [point("home", 0.1)]}
      assert Bundle.dangling(broken) == [{"point", "away"}]
    end
  end
end
