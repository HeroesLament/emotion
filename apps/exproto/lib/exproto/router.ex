defmodule ExProto.Router do
  @moduledoc """
  The HTTP surface: the WebSocket upgrade, and the few things a client wants
  before it has a session.

  Bulk transfer — program source, logs, motion traces — belongs here too when
  it exists, deliberately off the live link so that downloading a log cannot
  compete with telemetry for the same connection.
  """

  # copy_opts_to_assign rather than builder_opts/0, which is deprecated. The
  # endpoint's options — node table, value source, fingerprint — reach each
  # route through conn.assigns.opts instead of a bare variable.
  use Plug.Router, copy_opts_to_assign: :opts

  alias ExMo.Projection.JSONRPC.OpenRPC
  alias ExProto.{AuthPlug, Socket}

  @max_login_body 4_096

  plug(:match)
  plug(:dispatch)

  # The live link.
  #
  # Authentication happens HERE, before the upgrade, so an unauthenticated peer
  # never reaches ExProto.Dispatch and Dispatch stays a pure function of a
  # request and a session. It also means a rejected client costs one HTTP
  # response rather than a socket process, a publisher and a session struct.
  get "/rpc" do
    case AuthPlug.authenticate(conn) do
      {:ok, principal} ->
        conn
        |> echo_subprotocol()
        |> WebSockAdapter.upgrade(
          Socket,
          %{
            table: conn.assigns.opts.table,
            source: conn.assigns.opts.source,
            principal: principal
          },
          timeout: 60_000
        )
        |> halt()

      {:error, reason} ->
        # 401 with a challenge, not 403: the client has no credential we
        # accepted, and telling it which scheme to use is the entire purpose of
        # the header.
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="e-motion controller"))
        |> send_json(401, %{"error" => "unauthorized", "reason" => to_string(reason)})
        |> halt()
    end
  end

  # Exchange a username and password for a bearer token.
  #
  # Separate from the live link because it is the expensive one: Argon2 by
  # design, and throttled. Doing it once per session and carrying a token
  # afterwards is what keeps the connection path cheap.
  post "/login" do
    with {:ok, body, conn} <- read_body(conn, length: @max_login_body),
         {:ok, %{"username" => username, "password" => password} = params} <- decode(body) do
      login_opts = [
        label: Map.get(params, "label", "unnamed client"),
        peer: peer_address(conn)
      ]

      login_opts =
        case Map.get(params, "expiresIn") do
          seconds when is_integer(seconds) and seconds > 0 ->
            [{:expires_in, seconds} | login_opts]

          _ ->
            login_opts
        end

      case ExAuth.login(username, password, login_opts) do
        {:ok, principal, token} ->
          send_json(conn, 200, %{
            "token" => token,
            "username" => principal.username,
            "role" => Atom.to_string(principal.role),
            "grants" => principal.grants |> Enum.map(&Atom.to_string/1) |> Enum.sort()
          })

        {:error, {:throttled, seconds}} ->
          # 429 with Retry-After, so a well-behaved client backs off instead of
          # hammering and extending its own lockout.
          conn
          |> put_resp_header("retry-after", Integer.to_string(seconds))
          |> send_json(429, %{"error" => "too_many_attempts", "retryAfter" => seconds})

        {:error, _reason} ->
          send_json(conn, 401, %{"error" => "invalid_credentials"})
      end
    else
      _ -> send_json(conn, 400, %{"error" => "expected a JSON body with username and password"})
    end
  end

  # Unauthenticated on purpose: it exists so a supervisor, a load balancer, or
  # an operator with curl can tell whether the controller is up without holding
  # a credential, and it says nothing a port scan could not already infer.
  get "/health" do
    send_json(conn, 200, %{
      "status" => "ok",
      "protocolVersion" => OpenRPC.protocol_version()
    })
  end

  # The contract, served by the thing it describes. A client that fetches this
  # from the controller it is talking to cannot be reading a document for
  # different firmware, which is exactly the failure mode of shipping the file
  # separately from the device.
  get "/openrpc.json" do
    case document() do
      {:ok, json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, json)

      {:error, reason} ->
        send_json(conn, 500, %{"error" => inspect(reason)})
    end
  end

  # The certificate fingerprint, so an operator can compare what a client is
  # about to pin against what the controller believes it is presenting.
  #
  # Served over the very connection whose identity is in question, which proves
  # nothing by itself — that is what verifying out of band is for — but it makes
  # the comparison possible at all without shell access to the device.
  get "/fingerprint" do
    case conn.assigns.opts.fingerprint do
      nil -> send_json(conn, 404, %{"error" => "not serving TLS"})
      print -> send_json(conn, 200, %{"fingerprint" => print})
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  # Bandit hands us the subprotocol list; a browser that authenticated through
  # it needs the negotiated value echoed or it closes the connection. Echo the
  # protocol name only — echoing the whole header would put the token back on
  # the wire in the response.
  defp echo_subprotocol(conn) do
    offered =
      conn
      |> get_req_header("sec-websocket-protocol")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)

    if AuthPlug.subprotocol() in offered do
      put_resp_header(conn, "sec-websocket-protocol", AuthPlug.subprotocol())
    else
      conn
    end
  end

  defp decode(body) do
    case :json.decode(body) do
      %{} = params -> {:ok, params}
      _other -> :error
    end
  rescue
    _ -> :error
  end

  defp peer_address(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: address} -> address
      _ -> nil
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body |> :json.encode() |> IO.iodata_to_binary())
  end

  defp document do
    with {:ok, model} <- ExMo.InformationModel.compiled_model(),
         {:ok, doc} <- OpenRPC.document(model) do
      {:ok, OpenRPC.encode(doc)}
    end
  end
end
