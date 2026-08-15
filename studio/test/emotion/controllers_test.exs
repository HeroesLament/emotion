defmodule EMotion.ControllersTest do
  @moduledoc """
  The Controllers tab, with no window open.

  Everything the tab decides — which buttons are live, what a dialog is asked
  to collect, what happens to a profile list — is a pure function here, which
  is the point of keeping it out of the shell.
  """

  use ExUnit.Case, async: false

  alias EMotion.Controllers
  alias EMotion.Controller.Profile

  setup do
    tmp = Path.join(System.tmp_dir!(), "ctl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("XDG_CONFIG_HOME", tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    profiles = [
      %Profile{name: "cell-a", host: "10.0.0.1"},
      %Profile{name: "cell-b", host: "10.0.0.2", port: 4002}
    ]

    {:ok, state: Controllers.new(profiles: profiles), profiles: profiles}
  end

  describe "the list" do
    test "selects the first controller so the buttons have something to act on", %{state: s} do
      assert s.selected == "cell-a"
      assert Controllers.selected(s).host == "10.0.0.1"
    end

    test "labels carry the address, because two cells are often named alike", %{state: s} do
      assert [a, b] = Controllers.labels(s)
      assert a =~ "cell-a"
      assert a =~ "10.0.0.1:4001"
      assert b =~ "10.0.0.2:4002"
    end

    test "marks the connected one", %{state: s} do
      s = Controllers.connected(s, "cell-b", info())
      assert [a, b] = Controllers.labels(s)
      refute a =~ "●"
      assert b =~ "●"
    end

    test "selecting out of range changes nothing", %{state: s} do
      assert Controllers.select(s, 99).selected == "cell-a"
    end
  end

  describe "which buttons are live" do
    test "disconnected: everything but Disconnect", %{state: s} do
      e = Controllers.enabled(s)
      assert e.add and e.edit and e.remove and e.properties and e.connect
      refute e.disconnect
    end

    test "connected: no Connect, no Edit, and Disconnect appears", %{state: s} do
      e = s |> Controllers.connected("cell-a", info()) |> Controllers.enabled()

      assert e.disconnect
      # Connecting elsewhere while live is not offered: a button that silently
      # drops a link to a moving machine is not a button.
      refute e.connect
      refute e.edit
    end

    test "the connected controller cannot be removed out from under the link", %{state: s} do
      s = Controllers.connected(s, "cell-a", info())
      refute Controllers.enabled(s).remove

      assert Controllers.enabled(Controllers.select(s, 1)).remove
    end

    test "with no controllers at all, only Add is live" do
      e = Controllers.new(profiles: []) |> Controllers.enabled()
      assert e.add
      refute e.edit or e.remove or e.properties or e.connect or e.disconnect
    end
  end

  describe "add and edit" do
    test "Add asks for an empty form", %{state: s} do
      assert {_s, [{:dialog, :controller_add, opts}]} = Controllers.action(s, :add)
      assert {:name, :text, name_opts} = List.keyfind(opts[:fields], :name, 0)
      assert name_opts[:value] == ""
    end

    test "Edit prefills from the selection", %{state: s} do
      assert {_s, [{:dialog, :controller_edit, opts}]} = Controllers.action(s, :edit)
      assert {:host, :text, host_opts} = List.keyfind(opts[:fields], :host, 0)
      assert host_opts[:value] == "10.0.0.1"
    end

    test "a submitted Add appends and asks for a save", %{state: s} do
      values = %{"name" => "cell-c", "host" => "10.0.0.3", "port" => 4001, "username" => "operator", "rate" => 20}

      assert {s, [{:save, profiles}]} = Controllers.dialog(s, :controller_add, {:ok, values})
      assert length(profiles) == 3
      assert s.selected == "cell-c"
    end

    test "renaming through Edit replaces rather than duplicating", %{state: s} do
      values = %{"name" => "cell-a-renamed", "host" => "10.0.0.1", "port" => 4001, "username" => "operator", "rate" => 20}

      assert {s, [{:save, profiles}]} = Controllers.dialog(s, :controller_edit, {:ok, values})
      names = Enum.map(profiles, & &1.name)

      assert "cell-a-renamed" in names
      refute "cell-a" in names
      assert length(profiles) == 2
      assert s.selected == "cell-a-renamed"
    end

    test "a nameless or hostless controller is refused with a reason", %{state: s} do
      assert {s, []} = Controllers.dialog(s, :controller_add, {:ok, %{"name" => "  ", "host" => "h"}})
      assert s.status =~ "needs a name"

      assert {s, []} = Controllers.dialog(s, :controller_add, {:ok, %{"name" => "x", "host" => ""}})
      assert s.status =~ "needs a host"
    end

    test "cancelling does nothing at all", %{state: s} do
      assert {^s, []} = Controllers.dialog(s, :controller_add, :cancel)
    end
  end

  describe "connecting" do
    test "with no stored token it asks for a password, and does not echo it", %{state: s} do
      assert {_s, [{:dialog, :controller_password, opts}]} = Controllers.action(s, :connect)

      assert {:password, :password, _} = List.keyfind(opts[:fields], :password, 0)
      # :password rather than :text — a plant floor is not a private place.
      refute match?({:password, :text, _}, List.keyfind(opts[:fields], :password, 0))
    end

    test "with a stored token it connects without asking", %{state: s} do
      Profile.put_token("cell-a", "emo_pretend")

      assert {s, [{:connect, profile, opts}]} = Controllers.action(s, :connect)
      assert profile.name == "cell-a"
      refute Keyword.has_key?(opts, :password)
      assert s.connection == :connecting
    end

    test "submitting the password produces a connect carrying it", %{state: s} do
      assert {_s, [{:connect, profile, opts}]} =
               Controllers.dialog(s, :controller_password, {:ok, %{"password" => "hunter2"}})

      assert profile.name == "cell-a"
      assert opts[:password] == "hunter2"
    end

    test "a failure is reported, not swallowed", %{state: s} do
      s = Controllers.failed(s, :no_credential)
      assert s.connection == :disconnected
      assert s.status =~ "no stored token"
    end

    test "a dropped link clears the connection", %{state: s} do
      s = s |> Controllers.connected("cell-a", info()) |> Controllers.disconnected(:closed)

      refute Controllers.connected?(s)
      assert s.connected_to == nil
    end
  end

  describe "removing" do
    test "drops the profile and its token together", %{state: s} do
      Profile.put_token("cell-a", "emo_pretend")
      assert Profile.token("cell-a") == {:ok, "emo_pretend"}

      assert {s, [{:save, profiles}]} = Controllers.action(s, :remove)

      assert Enum.map(profiles, & &1.name) == ["cell-b"]
      # A token left behind would silently log a future controller of the same
      # name straight in.
      assert Profile.token("cell-a") == :error
      assert s.selected == "cell-b"
    end
  end

  describe "properties" do
    test "shows the pinned fingerprint and whether a token is held", %{state: s} do
      assert {_s, [{:dialog, :controller_properties, opts}]} = Controllers.action(s, :properties)
      fields = opts[:fields]

      assert {:fingerprint, :static, fp} = List.keyfind(fields, :fingerprint, 0)
      assert fp[:value] =~ "not pinned"

      assert {:token, :static, tok} = List.keyfind(fields, :token, 0)
      assert tok[:value] =~ "will ask for a password"
    end

    test "clearing the token from the modal actually clears it", %{state: s} do
      Profile.put_token("cell-a", "emo_pretend")

      assert {s, []} =
               Controllers.dialog(s, :controller_properties, {:ok, %{"trust" => "Clear stored token"}})

      assert Profile.token("cell-a") == :error
      assert s.status =~ "Cleared the stored token"
    end

    test "leaving it alone changes nothing", %{state: s} do
      Profile.put_token("cell-a", "emo_pretend")

      assert {_s, []} =
               Controllers.dialog(s, :controller_properties, {:ok, %{"trust" => "Leave alone"}})

      assert Profile.token("cell-a") == {:ok, "emo_pretend"}
    end
  end

  defp info, do: %{"capabilities" => %{"nodes" => %{"count" => 73}}}
end
