defmodule ExStore.FramesTest do
  use ExStore.DataCase

  alias ExStore.Frames

  describe "creating" do
    test "a frame is six numbers and a name" do
      {:ok, frame} = Frames.create(%{name: "fixture_a", x: 0.4, y: -0.1, z: 0.2, rz: 1.57})

      assert frame.name == "fixture_a"
      assert frame.x == 0.4
      assert frame.rz == 1.57
      # Not stated is not unknown. A frame with no rx is a frame with rx of zero.
      assert frame.rx == 0.0
      refute frame.mutable
    end

    test "names are unique, because two frames that print the same are one bug" do
      frame_fixture(%{name: "cell"})
      assert {:error, changeset} = Frames.create(%{name: "cell"})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "the names the controller already means something by are refused" do
      for reserved <- ~w(base tool world flange) do
        assert {:error, changeset} = Frames.create(%{name: reserved})
        assert changeset.errors[:name], "expected #{reserved} to be refused"
      end
    end

    test "a name that is not a name is refused" do
      for bad <- ["Fixture", "two words", "1st", "", "has-dash"] do
        assert {:error, _} = Frames.create(%{name: bad}), "expected #{inspect(bad)} to be refused"
      end
    end

    test "a value that is not finite is refused" do
      # This one is worth its line. A NaN reaching the Jacobian produces a NaN
      # joint command, and a NaN compares false against every limit in
      # CARTESIAN.md — so it passes all of them.
      assert {:error, changeset} = Frames.create(%{name: "bad", x: :infinity})
      assert changeset.errors[:x]
    end
  end

  describe "re-teaching" do
    test "moves the frame and nothing else" do
      moved = frame_fixture(%{name: "bumped", x: 0.1})
      other = frame_fixture(%{name: "untouched", x: 0.1})

      {:ok, moved} = Frames.teach(moved, %{x: 0.5})

      assert moved.x == 0.5
      assert Frames.by_name("untouched").x == other.x
    end
  end

  describe "parents" do
    test "lineage is base-first, because that is the order they compose in" do
      table = frame_fixture(%{name: "table"})
      fixture = frame_fixture(%{name: "jig", parent_id: table.id})
      hole = frame_fixture(%{name: "hole", parent_id: fixture.id})

      assert [%{name: "table"}, %{name: "jig"}, %{name: "hole"}] = Frames.lineage(hole)
    end

    test "a frame cannot be its own parent" do
      frame = frame_fixture()
      assert {:error, changeset} = Frames.teach(frame, %{parent_id: frame.id})
      assert changeset.errors[:parent_id]
    end

    test "a cycle is refused when it is written, not survived when it is read" do
      a = frame_fixture()
      b = frame_fixture(%{parent_id: a.id})

      assert {:error, changeset} = Frames.teach(a, %{parent_id: b.id})
      assert {"would make a cycle", _} = changeset.errors[:parent_id]
    end

    test "nesting deeper than the cap is refused" do
      deepest =
        Enum.reduce(1..ExStore.Frames.max_depth(), nil, fn i, parent ->
          frame_fixture(%{name: "deep#{i}", parent_id: parent && parent.id})
        end)

      assert {:error, changeset} = Frames.create(%{name: "one_too_far", parent_id: deepest.id})
      assert changeset.errors[:parent_id]
    end

    test "deleting a parent is refused rather than orphaning a child" do
      parent = frame_fixture()
      _child = frame_fixture(%{parent_id: parent.id})

      assert {:error, _} = Frames.delete(parent)
      assert Frames.get(parent.id)
    end
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
