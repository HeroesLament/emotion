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
    {:ok, model} = InformationModel.compiled_model()
    {:ok, table} = JSONRPC.project(model)
    {:ok, table: table}
  end

  setup %{table: table} do
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

    {:ok, port: port, dir: dir, source: source}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # verify_none because the point of the exercise is that the transport is
  # encrypted and the handshake completes, not that a self-signed certificate
  # chains to a root it was never meant to chain to. A real client pins the
  # fingerprint instead; see ExProto.TLS.
  defp connect(port, path \\ "/rpc") do
    {:ok, conn} =
      Mint.HTTP.connect(:https, "localhost", port,
        transport_opts: [verify: :verify_none],
        protocols: [:http1]
      )

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:wss, conn, path, [])

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

  defp initialized(port) do
    {conn, ref, websocket} = connect(port)

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
    test "initialize, browse, read", %{port: port} do
      {conn, ref, websocket} = initialized(port)

      {conn, websocket, browse} = request(conn, ref, websocket, "nodes/browse", %{"nodeId" => "axes"}, 2)
      assert length(browse["result"]["children"]) == 6

      {_conn, _websocket, read} =
        request(conn, ref, websocket, "nodes/read", %{"nodeIds" => ["axes.j1.position"]}, 3)

      assert [%{"value" => +0.0}] = read["result"]["values"]
    end

    test "a write round-trips", %{port: port} do
      {conn, ref, websocket} = initialized(port)

      {conn, websocket, write} =
        request(conn, ref, websocket, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.25}]
        }, 2)

      assert [%{"ok" => true}] = write["result"]["results"]

      {_conn, _websocket, read} =
        request(conn, ref, websocket, "nodes/read", %{"nodeIds" => ["axes.j1.target_position"]}, 3)

      assert [%{"value" => 1.25}] = read["result"]["values"]
    end

    test "errors survive the wire intact", %{port: port} do
      {conn, ref, websocket} = initialized(port)

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "nodes/browse", %{"nodeId" => "nope"}, 2)

      assert response["error"]["code"] == -32_003
    end

    test "a request before initialize is refused", %{port: port} do
      {conn, ref, websocket} = connect(port)

      {_conn, _websocket, response} =
        request(conn, ref, websocket, "nodes/browse", %{}, 1)

      assert response["error"]["code"] == -32_000
    end
  end

  # ── delivery over the wire ────────────────────────────────────────────────

  describe "subscription delivery" do
    test "a subscription delivers an initial frame and then changes",
         %{port: port, source: source} do
      {conn, ref, websocket} = initialized(port)

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

    test "unsubscribing stops delivery", %{port: port, source: source} do
      {conn, ref, websocket} = initialized(port)

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
end
