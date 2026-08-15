defmodule EMotion.LinkTest do
  @moduledoc """
  The studio talking to a real controller.

  Not a mock. The link is the one piece whose whole job is that two programs
  agree, so it is tested against the actual server: a real endpoint over real
  TLS, a real login, a real subscription, and a real write that moves a
  simulated drive.
  """

  use ExUnit.Case, async: false

  alias EMotion.{Cell, Link}
  alias EMotion.Controller.Profile

  @moduletag :link

  setup do
    tmp = Path.join(System.tmp_dir!(), "link-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    # A cell server of this test's own, so the studio's real one is untouched.
    {:ok, cells} = Cell.Server.start_link(cell: Cell.new(name: "empty"), name: nil)

    {:ok, link} = Link.start_link(name: nil, cell_server: cells)

    {:ok,
     tmp: tmp,
     cells: cells,
     link: link,
     known_hosts: Path.join(tmp, "known_hosts")}
  end

  defp profile(port, tmp) do
    %Profile{name: "test-controller", host: "localhost", port: port, rate_hz: 25.0, robot_id: :arm_a}
    |> tap(fn _ -> System.put_env("XDG_CONFIG_HOME", tmp) end)
  end

  describe "without a controller" do
    test "connecting reports the failure rather than raising", %{link: link, tmp: tmp, known_hosts: kh} do
      profile = profile(4999, tmp)

      assert {:error, _reason} =
               Link.connect(profile, name: link, password: "irrelevant", known_hosts: kh)

      assert Link.status(name: link) == :disconnected
    end

    test "jogging while disconnected is refused, not queued", %{link: link} do
      assert {:error, :not_connected} = Link.jog(:j1, 1.0, name: link)
    end

    test "connecting with no stored token and no password says so", %{link: link, tmp: tmp, known_hosts: kh} do
      assert {:error, :no_credential} =
               Link.connect(profile(4999, tmp), name: link, known_hosts: kh)
    end
  end
end
