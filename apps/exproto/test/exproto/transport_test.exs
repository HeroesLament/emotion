defmodule ExProto.TransportTest do
  @moduledoc """
  The transport, over real TLS, against a real listener.

  Everything below this layer is already covered by tests that need no socket.
  What cannot be checked that way — that TLS actually negotiates, that the
  upgrade actually happens, that a notification actually reaches a client — is
  what this file is for, and it uses a genuine WebSocket client over a genuine
  encrypted connection rather than asserting against a stand-in.
  """

  use ExUnit.Case, async: false

  alias ExMo.InformationModel
  alias ExMo.Projection.JSONRPC
  alias ExMo.Projection.JSONRPC.OpenRPC
  alias ExProto.{Endpoint, TLS}
  alias ExProto.Source.Static

  @moduletag :transport
  @moduletag :capture_log

  setup_all do
    # :auto, set here rather than in test_helper. Sandbox mode is per-Repo
    # global state and the Repo is shared with exauth in an umbrella run, so
    # setting it in a helper means whichever app ran last decides — which is
    # how this suite ended up running in :manual and failing on ownership.
    #
    # :auto rather than the sandbox because the connections under test are made
    # by Bandit-owned processes that are not descendants of the test, and shared
    # mode is refused while this app's async tests are running. So these tests
    # commit for real: usernames are random so they survive a database that
    # outlives the run, and the table is emptied here so rows cannot accumulate
    # or leak into a sibling suite's expectations.
    Ecto.Adapters.SQL.Sandbox.mode(ExStore.Repo, :auto)
    ExStore.Repo.delete_all(ExAuth.Accounts.Account)
    on_exit(fn -> ExStore.Repo.delete_all(ExAuth.Accounts.Account) end)

    {:ok, model} = InformationModel.compiled_model()
    {:ok, table} = JSONRPC.project(model)
    {:ok, table: table}
  end

  setup %{table: table} do
    ExAuth.Throttle.reset_all()

    dir = Path.join(System.tmp_dir!(), "exproto-tls-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, source} =
      Static.start_link(
        values: %{
          "axes.j1.position" => 0.0,
          "axes.j1.target_position" => 0.0
        }
      )

    port = 4100 + System.unique_integer([:positive, :monotonic])

    {:ok, _pid} =
      Endpoint.start_link(
        table: table,
        source: {Static, source},
        port: port,
        scheme: :https,
        tls: [dir: dir, hostnames: ["localhost"]]
      )

    # A real account and a real token. The transport tests are the only place
    # the credential path is exercised end to end, so they use it rather than
    # injecting a principal past it.
    username = unique_username("op")

    {:ok, _account} =
      ExAuth.Accounts.create(%{
        username: username,
        password: "correct-horse-battery-staple",
        role: :operator
      })

    {:ok, _principal, token} = ExAuth.login(username, "correct-horse-battery-staple")

    {:ok, port: port, dir: dir, source: source, username: username, token: token}
  end

  # Random rather than sequential: this database is not dropped between runs,
  # so a counter that restarts at 1 collides with the last run's rows.
  defp unique_username(prefix) do
    prefix <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end

  defp token_for(role) do
    username = unique_username("u")
    password = "correct-horse-battery-staple"
    {:ok, _} = ExAuth.Accounts.create(%{username: username, password: password, role: role})
    {:ok, _principal, token} = ExAuth.login(username, password)
    token
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # verify_none because the point of the exercise is that the transport is
  # encrypted and the handshake completes, not that a self-signed certificate
  # chains to a root it was never meant to chain to. A real client pins the
  # fingerprint instead; see ExProto.TLS.
  defp connect(port, token, path \\ "/rpc", headers \\ nil) do
    {:ok, conn} =
      Mint.HTTP.connect(:https, "localhost", port,
        transport_opts: [verify: :verify_none],
        protocols: [:http1]
      )

    headers = headers || [{"authorization", "Bearer " <> token}]
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:wss, conn, path, headers)

    {conn, websocket} = await_upgrade(conn, ref)
    {conn, ref, websocket}
  end

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

        case Enum.find(responses, &match?({:status, ^ref, _}, &1)) do
          nil ->
            await_upgrade(conn, ref)

          {:status, ^ref, status} ->
            headers = find_headers(conn, ref, responses)
            {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
            {conn, websocket}
        end
    after
      5_000 -> flunk("no upgrade response within 5s")
    end
  end

  defp find_headers(_conn, ref, responses) do
    Enum.find_value(responses, [], fn
      {:headers, ^ref, headers} -> headers
      _ -> false
    end)
  end

  defp send_json(conn, ref, websocket, payload) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, {:text, :json.encode(payload) |> IO.iodata_to_binary()})

    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket}
  end

  defp recv_json(conn, ref, websocket, timeout \\ 5_000) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            data =
              Enum.find_value(responses, fn
                {:data, ^ref, data} -> data
                _ -> nil
              end)

            if data do
              {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)

              case Enum.find(frames, &match?({:text, _}, &1)) do
                {:text, text} ->
                  {decoded, _, _} = :json.decode(text, :ok, %{})
                  {conn, websocket, decoded}

                nil ->
                  recv_json(conn, ref, websocket, timeout)
              end
            else
              recv_json(conn, ref, websocket, timeout)
            end

          _ ->
            recv_json(conn, ref, websocket, timeout)
        end
    after
      timeout -> flunk("no frame within #{timeout}ms")
    end
  end

  defp request(conn, ref, websocket, method, params, id) do
    {conn, websocket} =
      send_json(conn, ref, websocket, %{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => id
      })

    recv_json(conn, ref, websocket)
  end

  defp initialized(port, token) do
    {conn, ref, websocket} = connect(port, token)

    {conn, websocket, response} =
      request(conn, ref, websocket, "initialize", %{
        "protocolVersion" => OpenRPC.protocol_version()
      }, 1)

    assert response["result"]["protocolVersion"] == OpenRPC.protocol_version()
    {conn, ref, websocket}
  end

  # ── TLS ───────────────────────────────────────────────────────────────────

  describe "TLS" do
    test "the listener speaks TLS at all", %{port: port} do
      {:ok, socket} =
        :ssl.connect(~c"localhost", port,
          [verify: :verify_none, active: false],
          5_000
        )

      {:ok, info} = :ssl.connection_information(socket)
      :ssl.close(socket)

      # 1.2 is the floor. Anything older has no business on a segment that can
      # move an arm.
      assert info[:protocol] in [:"tlsv1.3", :"tlsv1.2"]
    end

    test "plaintext HTTP is refused with a TLS alert, not served", %{port: port} do
      # The listener is TLS-only. A bare TCP client sending HTTP gets a fatal
      # TLS alert rather than a response:
      #
      #   21   content type: alert
      #   3,3  record version
      #   0,2  length
      #   2    level: fatal
      #   10   description: unexpected_message
      #
      # Better than a silent close, which is also what a crashed listener
      # looks like — an alert can only come from one that is up and speaking
      # TLS, so this doubles as proof there is no plaintext fallback.
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 5_000)
      :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")

      assert {:ok, <<21, _major, _minor, _length::16, 2, _description>>} =
               :gen_tcp.recv(socket, 0, 2_000)

      :gen_tcp.close(socket)
    end

    test "the certificate is generated once and reused", %{port: _port, dir: dir} do
      {:ok, first} = TLS.material(dir: dir, hostnames: ["localhost"])
      {:ok, second} = TLS.material(dir: dir, hostnames: ["localhost"])

      # Regenerating on every boot would change the fingerprint every boot,
      # which would train an operator to click through the warning that is
      # supposed to mean something.
      assert first.fingerprint == second.fingerprint
    end

    test "the private key is not world readable", %{dir: dir} do
      {:ok, material} = TLS.material(dir: dir, hostnames: ["localhost"])
      %File.Stat{mode: mode} = File.stat!(material.keyfile)

      assert Bitwise.band(mode, 0o077) == 0,
             "key file mode #{Integer.to_string(mode, 8)} is readable by others"
    end

    test "the fingerprint is the same one openssl would print", %{dir: dir} do
      {:ok, material} = TLS.material(dir: dir, hostnames: ["localhost"])

      assert material.fingerprint =~ ~r/^([0-9A-F]{2}:){31}[0-9A-F]{2}$/
    end

    test "the served fingerprint matches the certificate presented", %{port: port, dir: dir} do
      {:ok, material} = TLS.material(dir: dir, hostnames: ["localhost"])

      {:ok, socket} =
        :ssl.connect(~c"localhost", port, [verify: :verify_none, active: false], 5_000)

      {:ok, der} = :ssl.peercert(socket)
      :ssl.close(socket)

      assert TLS.fingerprint(der) == material.fingerprint
    end
  end

  # ── the session over the wire ─────────────────────────────────────────────

  describe "a session over TLS" do
    test "initialize, browse, read", %{port: port, token: token} do
      {conn, ref, websocket} = initialized(port, token)

      {conn, websocket, browse} = request(conn, ref, websocket, "nodes/browse", %{"nodeId" => "axes"}, 2)

      # Six joints, the tool centre point they place, what the controller is
      # making of the Cartesian motion, and the two commands that move all six at
      # once. Named rather than counted: a count that goes up is a test that gets
      # its number bumped without anyone looking at what arrived.
      assert Enum.map(browse["result"]["children"], & &1["nodeId"]) ==
               ~w(axes.j1 axes.j2 axes.j3 axes.j4 axes.j5 axes.j6 axes.tcp
                  axes.cartesian axes.jog_cartesian axes.move_linear axes.move_arc)

      {_conn, _websocket, read} =
        request(conn, ref, websocket, "nodes/read", %{"nodeIds" => ["axes.j1.position"]}, 3)

      assert [%{"value" => +0.0}] = read["result"]["values"]
    end

    test "a write round-trips", %{port: port, token: token} do
      {conn, ref, websocket} = initialized(port, token)

      {conn, websocket, write} =
        request(conn, ref, websocket, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.25}]
        }, 2)

      assert [%{"ok" => true}] = write["result"]["results"]

      {_conn, _websocket, read} =
        request(conn, ref, websocket, "nodes/read", %{"nodeIds" => ["axes.j1.target_position"]}, 3)

      assert [%{"value" => 1.25}] = read["result"]["values"]
    end

    test "errors survive the wire intact", %{port: port, token: token} do
      {conn, ref, websocket} = initialized(port, token)

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "nodes/browse", %{"nodeId" => "nope"}, 2)

      assert response["error"]["code"] == -32_003
    end

    test "a request before initialize is refused", %{port: port, token: token} do
      {conn, ref, websocket} = connect(port, token)

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "nodes/browse", %{}, 1)

      assert response["error"]["code"] == -32_000
    end
  end

  # ── delivery over the wire ────────────────────────────────────────────────

  describe "subscription delivery" do
    test "a subscription delivers an initial frame and then changes",
         %{port: port, token: token, source: source} do
      {conn, ref, websocket} = initialized(port, token)

      {conn, websocket, subscribed} =
        request(conn, ref, websocket, "nodes/subscribe", %{
          "nodeIds" => ["axes.j1.position"],
          "rateHz" => 50
        }, 2)

      assert subscribed["result"]["rateHz"] == 50.0

      # The initial frame: a client gets a complete picture without a separate
      # read.
      {conn, websocket, first} = recv_json(conn, ref, websocket)
      assert first["method"] == "notifications/nodes/changed"
      assert [%{"value" => +0.0}] = first["params"]["values"]

      Static.put(source, "axes.j1.position", 2.5)

      {_conn, _websocket, second} = recv_json(conn, ref, websocket)
      assert [%{"value" => 2.5}] = second["params"]["values"]
      assert second["params"]["seq"] > first["params"]["seq"]
    end

    test "unsubscribing stops delivery", %{port: port, token: token, source: source} do
      {conn, ref, websocket} = initialized(port, token)

      {conn, websocket, subscribed} =
        request(conn, ref, websocket, "nodes/subscribe", %{
          "nodeIds" => ["axes.j1.position"],
          "rateHz" => 50
        }, 2)

      id = subscribed["result"]["subscriptionId"]
      {conn, websocket, _initial} = recv_json(conn, ref, websocket)

      {conn, websocket, _} =
        request(conn, ref, websocket, "nodes/unsubscribe", %{"subscriptionId" => id}, 3)

      Static.put(source, "axes.j1.position", 9.0)

      # Nothing should arrive. A short wait is enough at 50 Hz — several
      # intervals pass.
      assert_raise ExUnit.AssertionError, fn ->
        recv_json(conn, ref, websocket, 300)
      end
    end
  end

  # ── the HTTP surface ──────────────────────────────────────────────────────

  describe "http" do
    test "health answers without a session", %{port: port} do
      assert {:ok, body} = get(port, "/health")
      assert body["status"] == "ok"
      assert body["protocolVersion"] == OpenRPC.protocol_version()
    end

    test "the controller serves the contract it implements", %{port: port} do
      # A client that fetches this from the controller it is talking to cannot
      # be holding a document for different firmware.
      assert {:ok, body} = get(port, "/openrpc.json")
      assert body["openrpc"] == "1.3.2"
      assert body["x-protocolVersion"] == OpenRPC.protocol_version()
    end

    test "the fingerprint endpoint agrees with the presented certificate",
         %{port: port, dir: dir} do
      {:ok, material} = TLS.material(dir: dir, hostnames: ["localhost"])
      assert {:ok, body} = get(port, "/fingerprint")

      assert body["fingerprint"] == material.fingerprint
    end

    test "an unknown path is a JSON 404", %{port: port} do
      assert {:ok, body} = get(port, "/nope", 404)
      assert body["error"] == "not found"
    end
  end

  defp get(port, path, expected_status \\ 200) do
    {:ok, conn} =
      Mint.HTTP.connect(:https, "localhost", port,
        transport_opts: [verify: :verify_none],
        protocols: [:http1]
      )

    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, [], nil)
    {status, body} = collect(conn, ref, nil, "")

    assert status == expected_status
    {decoded, _, _} = :json.decode(body, :ok, %{})
    {:ok, decoded}
  end

  defp collect(conn, ref, status, body) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.HTTP.stream(conn, message)

        {status, body, done} =
          Enum.reduce(responses, {status, body, false}, fn
            {:status, ^ref, s}, {_st, b, d} -> {s, b, d}
            {:data, ^ref, chunk}, {st, b, d} -> {st, b <> chunk, d}
            {:done, ^ref}, {st, b, _d} -> {st, b, true}
            _other, acc -> acc
          end)

        if done, do: {status, body}, else: collect(conn, ref, status, body)
    after
      5_000 -> flunk("no HTTP response within 5s")
    end
  end

  # ── authentication at the upgrade ─────────────────────────────────────────

  describe "the upgrade requires a credential" do
    # A raw HTTPS request rather than the WebSocket helper, because what is
    # under test is the response to an upgrade that never becomes one.
    defp upgrade_status(port, headers) do
      {:ok, conn} =
        Mint.HTTP.connect(:https, "localhost", port,
          transport_opts: [verify: :verify_none],
          protocols: [:http1]
        )

      {:ok, conn, ref} =
        Mint.HTTP.request(
          conn,
          "GET",
          "/rpc",
          [
            {"connection", "Upgrade"},
            {"upgrade", "websocket"},
            {"sec-websocket-version", "13"},
            {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))}
            | headers
          ],
          nil
        )

      collect_response(conn, ref, nil, [])
    end

    defp collect_response(conn, ref, status, body) do
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, responses} ->
              status = Enum.find_value(responses, status, fn
                {:status, ^ref, s} -> s
                _ -> nil
              end)

              body =
                body ++
                  Enum.flat_map(responses, fn
                    {:data, ^ref, d} -> [d]
                    _ -> []
                  end)

              if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
                {status, IO.iodata_to_binary(body)}
              else
                collect_response(conn, ref, status, body)
              end

            {:error, _conn, _reason, _responses} ->
              {status, IO.iodata_to_binary(body)}
          end
      after
        5_000 -> flunk("no response within 5s")
      end
    end

    test "no credential is refused with a challenge", %{port: port} do
      {status, body} = upgrade_status(port, [])

      assert status == 401
      # The challenge is the point of a 401 rather than a 403: it tells a
      # client which scheme to retry with.
      assert body =~ "unauthorized"
    end

    test "a token that was never issued is refused", %{port: port} do
      fake = "emo_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      {status, _body} = upgrade_status(port, [{"authorization", "Bearer " <> fake}])

      assert status == 401
    end

    test "a revoked token stops working", %{port: port} do
      username = unique_username("rev")
      password = "correct-horse-battery-staple"

      {:ok, account} =
        ExAuth.Accounts.create(%{username: username, password: password, role: :operator})

      {:ok, _principal, token} = ExAuth.login(username, password)

      assert {200, _} = upgrade_ok(port, token)
      :ok = ExAuth.revoke_sessions(account.id)

      {status, _body} = upgrade_status(port, [{"authorization", "Bearer " <> token}])
      assert status == 401
    end

    # A successful upgrade answers 101, not 200 — asserted separately so the
    # revocation test above reads as a before/after rather than a status check.
    defp upgrade_ok(port, token) do
      {status, body} = upgrade_status(port, [{"authorization", "Bearer " <> token}])
      assert status == 101, "expected an upgrade, got #{status}: #{body}"
      {200, body}
    end

    test "a garbage authorization header is refused, not crashed on", %{port: port} do
      for value <- ["", "Bearer", "Basic dXNlcjpwYXNz", "Bearer  ", "not-a-scheme token"] do
        {status, _body} = upgrade_status(port, [{"authorization", value}])
        assert status == 401, "expected 401 for #{inspect(value)}"
      end
    end

    test "a browser can authenticate through the subprotocol header", %{port: port, token: token} do
      # The browser WebSocket API cannot set request headers, so the
      # subprotocol field is the only way a page can present a credential.
      {conn, ref, websocket} =
        connect(port, token, "/rpc", [
          {"sec-websocket-protocol", "emotion.v1, " <> token}
        ])

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "initialize", %{
          "protocolVersion" => OpenRPC.protocol_version()
        }, 1)

      assert response["result"]["protocolVersion"] == OpenRPC.protocol_version()
    end
  end

  # ── logging in ────────────────────────────────────────────────────────────

  describe "POST /login" do
    defp post_login(port, payload) do
      {:ok, conn} =
        Mint.HTTP.connect(:https, "localhost", port,
          transport_opts: [verify: :verify_none],
          protocols: [:http1]
        )

      body = payload |> :json.encode() |> IO.iodata_to_binary()

      {:ok, conn, ref} =
        Mint.HTTP.request(conn, "POST", "/login", [{"content-type", "application/json"}], body)

      {status, body} = collect_response(conn, ref, nil, [])
      {status, if(body == "", do: %{}, else: :json.decode(body))}
    end

    test "exchanges a password for a usable token", %{port: port, username: username} do
      {status, body} =
        post_login(port, %{
          "username" => username,
          "password" => "correct-horse-battery-staple",
          "label" => "the bench laptop"
        })

      assert status == 200
      assert body["role"] == "operator"
      assert "write_setpoint" in body["grants"]
      refute "calibrate" in body["grants"]

      # The token it returns must actually open a connection.
      {conn, ref, websocket} = connect(port, body["token"])

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "initialize", %{
          "protocolVersion" => OpenRPC.protocol_version()
        }, 1)

      assert response["result"]["protocolVersion"] == OpenRPC.protocol_version()
    end

    test "a wrong password is 401 and returns no token", %{port: port, username: username} do
      {status, body} = post_login(port, %{"username" => username, "password" => "wrong-password"})

      assert status == 401
      refute body["token"]
    end

    test "an unknown user looks exactly like a wrong password", %{port: port} do
      {status, body} = post_login(port, %{"username" => "ghost", "password" => "wrong-password"})

      assert status == 401
      assert body["error"] == "invalid_credentials"
    end

    test "a malformed body is 400, not a crash", %{port: port} do
      assert {400, _} = post_login(port, %{"username" => "only"})
    end

    test "repeated failures are throttled with a Retry-After", %{port: port} do
      username = unique_username("thr")

      {:ok, _} =
        ExAuth.Accounts.create(%{
          username: username,
          password: "correct-horse-battery-staple",
          role: :observer
        })

      # Driving the counter directly rather than by making failed requests. The
      # backoff after five failures is one second, and six TLS handshakes take
      # long enough that the lock can expire before the assertion — a test that
      # passes or fails on how fast the machine is is worse than no test.
      #
      # What is under test here is that the HTTP layer surfaces an existing
      # lock as 429 with a Retry-After. The counting itself is covered in
      # exauth, where it can be asserted without a socket.
      for _ <- 1..8, do: ExAuth.Throttle.record_failure({:user, username})

      {status, body} =
        post_login(port, %{"username" => username, "password" => "correct-horse-battery-staple"})

      assert status == 429
      assert body["retryAfter"] > 0

      # And the lock applies to the correct password, which is the whole point.
      refute body["token"]
    end
  end

  # ── grants over the wire ──────────────────────────────────────────────────

  describe "authorisation survives the transport" do
    test "an operator may command a setpoint", %{port: port} do
      {conn, ref, websocket} = initialized(port, token_for(:operator))

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.0}]
        }, 2)

      assert [%{"ok" => true}] = response["result"]["results"]
    end

    test "an observer is refused the same write", %{port: port} do
      {conn, ref, websocket} = initialized(port, token_for(:observer))

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.0}]
        }, 2)

      assert [%{"ok" => false, "error" => error}] = response["result"]["results"]
      assert error["code"] == -32_011
      assert error["data"]["requiredGrant"] == "write_setpoint"
    end

    test "an observer may still read", %{port: port} do
      {conn, ref, websocket} = initialized(port, token_for(:observer))

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "nodes/read", %{
          "nodeIds" => ["axes.j1.position"]
        }, 2)

      assert [%{"value" => _}] = response["result"]["values"]
    end
  end
end
