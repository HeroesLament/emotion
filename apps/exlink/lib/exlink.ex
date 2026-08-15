defmodule ExLink do
  @moduledoc """
  A client for an E-Motion controller: TLS with fingerprint pinning, login,
  JSON-RPC, subscriptions.

  Shipped beside the server rather than written separately, because a protocol
  with one implementation on each side and no shared code is a protocol whose
  two halves drift. The transport tests, `mix exmo.rpc` and E-Motion Studio all
  come through here, so anything that breaks a client breaks the suite.

  ## Its own application, depending on nothing

  This lives outside `exproto` so a client can be had without a controller.
  `exproto` needs `exhmi` for the node table and the protocol document, and
  `exhmi` brings the OPC UA server, and `exauth` brings SQLite and Argon2 — an
  entirely reasonable dependency graph for something that drives a robot and an
  absurd one for something that draws it.

  The only thing given up is that the protocol version is declared here rather
  than read from the generated document. A test in `exproto` asserts the two
  agree, so drift is a build failure rather than a handshake failure in a
  workshop.

  ## Pings are answered only while something is reading

  The controller pings to keep an otherwise silent link open, and the pong sent
  back is what actually resets its idle timer. That pong is sent from
  `stream/2`, which means a client that stops reading stops answering, and a
  client that sleeps through the timeout is dropped exactly as if the
  keepalive did not exist.

  This is not a quirk of this client — no WebSocket client can answer a frame
  it has not read — but it does mean the owning process must be in a receive
  loop or a GenServer. `EMotion.Link` is a GenServer, so it answers on every
  message; a script that wants to idle must call `recv/2` rather than
  `Process.sleep/1`.

  ## Trust on first use, enforced

  The controller mints a self-signed certificate, so certificate-authority
  verification is meaningless — there is no authority. What is meaningful is
  whether it is the *same* controller as last time.

  So the first connection records the certificate's SHA-256 fingerprint against
  the host and port, and every connection after that compares. A changed
  fingerprint stops the client, because the two explanations are "the
  certificate was deliberately rotated" and "this is not the machine you think
  it is", and only one of those should be resolved by carrying on.

  This is the same trust model SSH has used for thirty years. It is weaker than
  PKI: the first connection is unauthenticated and can be intercepted. It is
  much stronger than not looking.
  """

  require Logger

  alias ExLink.KnownHosts

  # The revision this client speaks. Declared rather than read from the
  # generated OpenRPC document, because reading it would mean depending on the
  # application that generates it. ExProto's suite asserts they match.
  @protocol_version "2026-08-15"

  @doc "The protocol revision this client speaks."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @type conn :: %{conn: term(), ref: term(), websocket: term(), id: pos_integer()}

  # ── Trust store ───────────────────────────────────────────────────────────

  @doc "Where pinned fingerprints live by default."
  defdelegate known_hosts_path(), to: KnownHosts, as: :default_path

  @doc "Colon-separated uppercase SHA-256, as openssl prints it."
  defdelegate fingerprint(der), to: KnownHosts

  # ── HTTPS ─────────────────────────────────────────────────────────────────

  @doc """
  Logs in and returns a bearer token.
  """
  def login(host, port, username, password, opts \\ []) do
    body =
      %{
        "username" => username,
        "password" => password,
        "label" => Keyword.get(opts, :label, "exmo.rpc CLI")
      }
      |> :json.encode()
      |> IO.iodata_to_binary()

    case post(host, port, "/login", body, opts) do
      {:ok, 200, decoded} -> {:ok, decoded}
      {:ok, status, decoded} -> {:error, {status, decoded}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(host, port, path, body, opts) do
    with {:ok, conn} <- http_connect(host, port),
         {:ok, _pin} <- check(conn, host, port, opts),
         {:ok, conn, ref} <-
           Mint.HTTP.request(conn, "POST", path, [{"content-type", "application/json"}], body) do
      case collect(conn, ref, nil, []) do
        {status, raw} -> {:ok, status, decode(raw)}
      end
    end
  end

  defp http_connect(host, port) do
    Mint.HTTP.connect(:https, host, port,
      # Verification is by pinned fingerprint, not by chain — see the moduledoc.
      transport_opts: [verify: :verify_none],
      protocols: [:http1]
    )
  end

  defp check(conn, host, port, opts) do
    if Keyword.get(opts, :insecure, false) do
      {:ok, :skipped}
    else
      case KnownHosts.verify(Mint.HTTP.get_socket(conn), host, port, opts) do
        {:ok, :learned, print} ->
          Logger.warning("""
          First connection to #{host}:#{port}. Pinning its certificate:

              #{print}

          Verify this out of band against what the controller printed at boot.
          Every later connection is checked against it.
          """)

          {:ok, :learned}

        {:ok, :pinned, _print} ->
          {:ok, :pinned}

        {:error, {:fingerprint_changed, expected, got}} ->
          {:error,
           """
           The controller at #{host}:#{port} presented a DIFFERENT certificate.

               pinned    #{expected}
               presented #{got}

           Either its certificate was deliberately rotated, or this is not the
           machine you pinned. Refusing to continue. If the rotation was
           intended, run ExLink.KnownHosts.forget/2 for this host.
           """}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp collect(conn, ref, status, acc) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            status =
              Enum.find_value(responses, status, fn
                {:status, ^ref, s} -> s
                _ -> nil
              end)

            acc =
              acc ++
                Enum.flat_map(responses, fn
                  {:data, ^ref, d} -> [d]
                  _ -> []
                end)

            if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
              {status, IO.iodata_to_binary(acc)}
            else
              collect(conn, ref, status, acc)
            end

          {:error, _conn, _reason, _responses} ->
            {status, IO.iodata_to_binary(acc)}
        end
    after
      10_000 -> {status, IO.iodata_to_binary(acc)}
    end
  end

  defp decode(""), do: %{}

  defp decode(raw) do
    :json.decode(raw)
  rescue
    _ -> %{"raw" => raw}
  end

  # ── WebSocket ─────────────────────────────────────────────────────────────

  @doc """
  Opens an authenticated session and completes `initialize`.
  """
  def connect(host, port, token, opts \\ []) do
    with {:ok, conn} <- http_connect(host, port),
         {:ok, _pin} <- check(conn, host, port, opts),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(:wss, conn, "/rpc", [{"authorization", "Bearer " <> token}]),
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      session = %{conn: conn, ref: ref, websocket: websocket, id: 1}

      case request(session, "initialize", %{
             "protocolVersion" => @protocol_version,
             "clientInfo" => Keyword.get(opts, :client_info, %{"name" => "exlink", "version" => "0.1.0"})
           }) do
        {:ok, session, %{"result" => result}} -> {:ok, session, result}
        {:ok, _session, %{"error" => error}} -> {:error, error}
        other -> other
      end
    end
  end

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

        case Enum.find(responses, &match?({:status, ^ref, _}, &1)) do
          nil ->
            await_upgrade(conn, ref)

          {:status, ^ref, status} ->
            headers =
              Enum.find_value(responses, [], fn
                {:headers, ^ref, h} -> h
                _ -> false
              end)

            case Mint.WebSocket.new(conn, ref, status, headers) do
              {:ok, conn, websocket} -> {:ok, conn, websocket}
              {:error, _conn, reason} -> {:error, {:upgrade_refused, status, reason}}
            end
        end
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end

  @doc """
  Sends a request without waiting, returning the id to match a reply against.

  What a GenServer uses: it cannot block in a `receive` without stalling every
  other message it is responsible for.
  """
  @spec send_request(map(), String.t(), map()) :: {:ok, map(), pos_integer()} | {:error, term()}
  def send_request(session, method, params) do
    id = session.id

    payload =
      %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}
      |> :json.encode()
      |> IO.iodata_to_binary()

    with {:ok, session} <- send_text(session, payload) do
      {:ok, %{session | id: id + 1}, id}
    end
  end

  @doc """
  Decodes one already-received message into frames.

  The counterpart to `send_request/3`: hand it whatever arrived in
  `handle_info/2` and it returns any complete JSON-RPC frames, or `:unknown` if
  the message was not ours — which is the answer a GenServer needs, because it
  has its own messages and must be able to tell them apart.
  """
  @spec stream(map(), term()) :: {:ok, map(), [map()]} | :unknown | {:error, term()}
  def stream(session, message) do
    case Mint.WebSocket.stream(session.conn, message) do
      {:ok, conn, responses} ->
        data =
          responses
          |> Enum.flat_map(fn
            {:data, ref, d} when ref == session.ref -> [d]
            _ -> []
          end)
          |> IO.iodata_to_binary()

        {:ok, websocket, decoded} = Mint.WebSocket.decode(session.websocket, data)
        control(%{session | conn: conn, websocket: websocket}, decoded)

      {:error, _conn, reason, _responses} ->
        {:error, reason}

      :unknown ->
        :unknown
    end
  end

  # Control frames, which this used to drop on the floor.
  #
  # Mint does not answer a ping for you. The controller pings every 20 seconds
  # to keep the link open, and its idle timer is reset by data it *receives* —
  # so the pong sent from here is the thing that actually keeps the connection
  # alive. Ignoring pings meant a client watching a stationary machine was
  # disconnected after a minute, which is how this was found.
  defp control(session, decoded) do
    case Enum.find(decoded, &match?({:close, _, _}, &1)) do
      {:close, code, reason} ->
        {:error, {:closed, code, reason}}

      nil ->
        session =
          Enum.reduce(decoded, session, fn
            {:ping, payload}, session -> pong(session, payload)
            _frame, session -> session
          end)

        {:ok, session, for({:text, text} <- decoded, do: :json.decode(text))}
    end
  end

  defp pong(session, payload) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(session.websocket, {:pong, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(session.conn, session.ref, data) do
      %{session | conn: conn, websocket: websocket}
    else
      # A pong we could not send is not worth failing a read over: the next
      # ping will try again, and if the link really is gone the read that
      # follows will say so.
      _ -> session
    end
  end

  @doc """
  Sends one request and waits for the response with the matching id.

  Notifications that arrive while waiting are skipped rather than mistaken for
  the reply — with a subscription open they will, and a client that returned
  the first frame it saw would attribute a value update to whatever it happened
  to have asked.
  """
  def request(session, method, params) do
    id = session.id

    payload =
      %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}
      |> :json.encode()
      |> IO.iodata_to_binary()

    with {:ok, session} <- send_text(session, payload),
         {:ok, session, response} <- await_id(session, id) do
      {:ok, %{session | id: id + 1}, response}
    end
  end

  defp send_text(session, payload) do
    {:ok, websocket, data} = Mint.WebSocket.encode(session.websocket, {:text, payload})

    case Mint.WebSocket.stream_request_body(session.conn, session.ref, data) do
      {:ok, conn} -> {:ok, %{session | conn: conn, websocket: websocket}}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp await_id(session, id) do
    case recv(session, 10_000) do
      {:ok, session, frames} ->
        case Enum.find(frames, &(Map.get(&1, "id") == id)) do
          nil -> await_id(session, id)
          response -> {:ok, session, response}
        end

      other ->
        other
    end
  end

  @doc """
  Receives whatever frames are ready, decoded.

  Returns `{:ok, session, [map]}` or `{:error, :timeout}`.
  """
  def recv(session, timeout \\ 5_000), do: do_recv(session, timeout, [])

  defp do_recv(session, timeout, deferred) do
    receive do
      message ->
        case stream(session, message) do
          {:ok, session, []} ->
            do_recv(session, timeout, deferred)

          {:ok, session, frames} ->
            requeue(deferred)
            {:ok, session, frames}

          :unknown ->
            # Not ours. Hold it and put it back afterwards rather than dropping
            # it — this blocking path runs inside whatever process called it,
            # and silently eating that process's mail is not ours to do.
            do_recv(session, timeout, [message | deferred])

          {:error, reason} ->
            requeue(deferred)
            {:error, reason}
        end
    after
      timeout ->
        requeue(deferred)
        {:error, :timeout}
    end
  end

  # Oldest first, so deferred messages keep their order relative to each other.
  # They do move behind anything that arrived while we were waiting; a caller
  # that cannot tolerate that should use stream/2 and own its own loop.
  defp requeue(deferred), do: Enum.each(Enum.reverse(deferred), &send(self(), &1))
end
