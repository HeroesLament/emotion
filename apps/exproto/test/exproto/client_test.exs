defmodule ExProto.ClientTest do
  @moduledoc """
  The shipped client, against a real listener.

  ExProto.Client is not test scaffolding — `mix exmo.rpc` uses it and Studio
  will. So it gets exercised the same way the server does: over TLS, against a
  listener that is actually running.
  """

  use ExUnit.Case, async: false

  alias ExMo.InformationModel
  alias ExMo.Projection.JSONRPC
  alias ExProto.{Client, Endpoint}
  alias ExProto.Source.Static

  @moduletag :transport
  @moduletag :capture_log

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(ExAuth.Repo, :auto)
    ExAuth.Repo.delete_all(ExAuth.Accounts.Account)
    on_exit(fn -> ExAuth.Repo.delete_all(ExAuth.Accounts.Account) end)

    {:ok, model} = InformationModel.compiled_model()
    {:ok, table} = JSONRPC.project(model)
    {:ok, table: table}
  end

  setup %{table: table} do
    ExAuth.Throttle.reset_all()

    dir = Path.join(System.tmp_dir!(), "client-tls-#{System.unique_integer([:positive])}")
    hosts = Path.join(System.tmp_dir!(), "known-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) && File.rm_rf(hosts) end)

    {:ok, source} =
      Static.start_link(values: %{"axes.j1.position" => 0.25, "axes.j1.target_position" => 0.0})

    port = 4200 + System.unique_integer([:positive, :monotonic])

    {:ok, _pid} =
      Endpoint.start_link(
        table: table,
        source: {Static, source},
        port: port,
        scheme: :https,
        tls: [dir: dir, hostnames: ["localhost"]]
      )

    username = "c" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
    password = "correct-horse-battery-staple"
    {:ok, _} = ExAuth.Accounts.create(%{username: username, password: password, role: :operator})

    {:ok, port: port, dir: dir, hosts: hosts, username: username, password: password}
  end

  defp opts(hosts), do: [known_hosts: hosts]

  describe "login/5" do
    test "returns a token and the account's grants", ctx do
      assert {:ok, result} =
               Client.login("localhost", ctx.port, ctx.username, ctx.password, opts(ctx.hosts))

      assert String.starts_with?(result["token"], "emo_")
      assert result["role"] == "operator"
      assert "write_setpoint" in result["grants"]
    end

    test "a wrong password is an error, not a token", ctx do
      assert {:error, {401, _body}} =
               Client.login("localhost", ctx.port, ctx.username, "wrong-password", opts(ctx.hosts))
    end
  end

  describe "connect/4" do
    setup ctx do
      {:ok, %{"token" => token}} =
        Client.login("localhost", ctx.port, ctx.username, ctx.password, opts(ctx.hosts))

      {:ok, token: token}
    end

    test "completes initialize and reports capabilities", ctx do
      assert {:ok, _session, result} =
               Client.connect("localhost", ctx.port, ctx.token, opts(ctx.hosts))

      assert result["serverInfo"]["name"] == "E-Motion Controller"
      assert result["capabilities"]["nodes"]["count"] > 0
    end

    test "a token the controller never issued is refused at the upgrade", ctx do
      fake = "emo_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error, {:upgrade_refused, 401, _}} =
               Client.connect("localhost", ctx.port, fake, opts(ctx.hosts))
    end

    test "browse and read round-trip", ctx do
      {:ok, session, _} = Client.connect("localhost", ctx.port, ctx.token, opts(ctx.hosts))

      {:ok, session, response} = Client.request(session, "nodes/browse", %{})
      assert response["result"]["node"]["nodeId"]

      {:ok, _session, response} =
        Client.request(session, "nodes/read", %{"nodeIds" => ["axes.j1.position"]})

      assert [%{"value" => 0.25}] = response["result"]["values"]
    end

    test "responses are matched by id, not by arrival order", ctx do
      # With a subscription open, notifications interleave with replies. A
      # client that returned the first frame it saw would hand a value update
      # back as the answer to whatever it had just asked.
      {:ok, session, _} = Client.connect("localhost", ctx.port, ctx.token, opts(ctx.hosts))

      {:ok, session, _} =
        Client.request(session, "nodes/subscribe", %{
          "nodeIds" => ["axes.j1.position"],
          "rateHz" => 50
        })

      for _ <- 1..5 do
        {:ok, _s, response} =
          Client.request(session, "nodes/read", %{"nodeIds" => ["axes.j1.position"]})

        assert response["result"]["values"], "got a notification where a reply belonged"
      end
    end
  end

  describe "certificate pinning" do
    test "learns the fingerprint on first connection and reuses it", ctx do
      refute File.exists?(ctx.hosts)

      {:ok, _} = Client.login("localhost", ctx.port, ctx.username, ctx.password, opts(ctx.hosts))

      assert File.exists?(ctx.hosts)
      contents = File.read!(ctx.hosts)
      assert contents =~ "localhost:#{ctx.port}"

      # Second connection must not append a duplicate: it should match.
      {:ok, _} = Client.login("localhost", ctx.port, ctx.username, ctx.password, opts(ctx.hosts))
      assert File.read!(ctx.hosts) == contents
    end

    test "the pinned fingerprint is the certificate the controller actually has", ctx do
      {:ok, _} = Client.login("localhost", ctx.port, ctx.username, ctx.password, opts(ctx.hosts))

      [line] = ctx.hosts |> File.read!() |> String.split("\n", trim: true)
      [_host, pinned] = String.split(line, " ", parts: 2)

      # Compare against the certificate on the controller's disk, not against a
      # regex. A well-formed fingerprint of the wrong certificate would pass a
      # shape check and defeat the entire point of pinning.
      der =
        Path.join(ctx.dir, "controller.pem")
        |> File.read!()
        |> :public_key.pem_decode()
        |> hd()
        |> elem(1)

      assert pinned == Client.fingerprint(der)

      # And it is the form `openssl x509 -fingerprint -sha256` prints, so an
      # operator can compare the two by eye.
      assert pinned =~ ~r/\A([0-9A-F]{2}:){31}[0-9A-F]{2}\z/
    end

    test "a changed fingerprint stops the client", ctx do
      # Pin something else for this host, as though the controller had been
      # replaced. Continuing anyway is what pinning exists to prevent.
      File.mkdir_p!(Path.dirname(ctx.hosts))
      File.write!(ctx.hosts, "localhost:#{ctx.port} AA:BB:CC:DD\n")

      assert {:error, message} =
               Client.login("localhost", ctx.port, ctx.username, ctx.password, opts(ctx.hosts))

      assert message =~ "DIFFERENT certificate"
      assert message =~ "AA:BB:CC:DD"
    end

    test "--insecure skips the check entirely", ctx do
      File.write!(ctx.hosts, "localhost:#{ctx.port} AA:BB:CC:DD\n")

      assert {:ok, _result} =
               Client.login("localhost", ctx.port, ctx.username, ctx.password,
                 known_hosts: ctx.hosts,
                 insecure: true
               )
    end
  end
end
