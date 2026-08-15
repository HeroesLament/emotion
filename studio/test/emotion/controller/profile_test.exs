defmodule EMotion.Controller.ProfileTest do
  use ExUnit.Case, async: true

  alias EMotion.Controller.Profile

  setup do
    dir = Path.join(System.tmp_dir!(), "profiles-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, json: Path.join(dir, "controllers.json")}
  end

  test "round-trips through the file", %{json: file} do
    profiles = [
      %Profile{name: "bench", host: "10.0.0.5", port: 4001, username: "operator"},
      %Profile{name: "cell-2", host: "cell2.local", rate_hz: 10.0, description: "welding cell"}
    ]

    :ok = Profile.save(profiles, file)
    loaded = Profile.load(file)

    assert length(loaded) == 2
    assert {:ok, bench} = Profile.fetch(loaded, "bench")
    assert bench.host == "10.0.0.5"
    assert bench.port == 4001
    assert {:ok, cell2} = Profile.fetch(loaded, "cell-2")
    assert cell2.rate_hz == 10.0
    assert cell2.description == "welding cell"
  end

  test "a missing file is no controllers, not an error", %{json: file} do
    assert Profile.load(file) == []
  end

  test "a corrupt file is no controllers, not a crash", %{json: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "this is not json{{{")
    assert Profile.load(file) == []
  end

  test "entries missing a host are dropped rather than half-built", %{json: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, ~s([{"name":"ok","host":"h"},{"name":"broken"}]))

    assert [only] = Profile.load(file)
    assert only.name == "ok"
  end

  test "a robotId from the file cannot invent an atom", %{json: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, ~s([{"name":"x","host":"h","robotId":"definitely_not_an_existing_atom_9f2"}]))

    # Falls back rather than allocating. A file the studio did not write must
    # not be able to grow the atom table.
    assert [profile] = Profile.load(file)
    assert profile.robot_id == :arm_a
  end

  test "an absent description is absent, not the string \"nil\"", %{json: file} do
    :ok = Profile.save([%Profile{name: "bench", host: "h"}], file)

    # Erlang's JSON encoder writes the atom nil as "nil", so this round-tripped
    # as a profile whose description was the four characters n-i-l.
    refute File.read!(file) =~ "nil"
    assert [loaded] = Profile.load(file)
    assert loaded.description == nil
  end

  test "no password is ever written", %{json: file} do
    :ok = Profile.save([%Profile{name: "bench", host: "h"}], file)
    refute File.read!(file) =~ "password"
  end

  describe "tokens" do
    setup do
      dir = Path.join(System.tmp_dir!(), "tok-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "are stored apart from profiles and not world readable", %{dir: dir} do
      path = Path.join(dir, "bench")
      File.write!(path, "emo_secret")
      File.chmod!(path, 0o600)

      %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o077) == 0
    end
  end
end
