defmodule ExProto.Client do
  @moduledoc """
  A client for an E-Motion controller: TLS with fingerprint pinning, login,
  JSON-RPC, subscriptions.

  Shipped beside the server rather than written separately, because a protocol
  with one implementation on each side and no shared code is a protocol whose
  two halves drift. The transport tests and `mix exmo.rpc` both come through
  here, so anything that breaks a client breaks the suite.

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

  @type conn :: %{conn: term(), ref: term(), websocket: term(), id: pos_integer()}

  # ── Trust store ───────────────────────────────────────────────────────────

  @doc """
  Where pinned fingerprints live.

  Overridable per call via the `:known_hosts` option, so a test does not write
  into the working tree and so an embedding application — Studio — can keep its
  trust store somewhere it owns rather than wherever it happened to be started
  from.
  """
  def known_hosts_path(opts \\ []) do
    Keyword.get(opts, :known_hosts, Path.join([File.cwd!(), ".emotion", "known_hosts"]))
  end

  @doc """
  Checks a live connection's certificate against what was pinned before.

  Returns `{:ok, :pinned}` when it matches, `{:ok, :learned}` on first sight,
  or `{:error, {:fingerprint_changed, expected, got}}`.
  """
  def verify_pin(socket, host, port, opts \\ []) do
    with {:ok, der} <- :ssl.peercert(socket) do
      got = fingerprint(der)
      key = "#{host}:#{port}"

      case Map.get(load_known_hosts(opts), key) do
        nil ->
          if Keyword.get(opts, :learn, true), do: remember(key, got, opts)
          {:ok, :learned, got}

        ^got ->
          {:ok, :pinned, got}

        expected ->
          {:error, {:fingerprint_changed, expected, got}}
      end
    end
  end

  @doc "Colon-separated uppercase SHA-256, the form `openssl x509 -fingerprint` prints."
  def fingerprint(der) do
    :crypto.hash(:sha256, der)
    |> Base.encode16()
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &to_string/1)
  end

  defp load_known_hosts(opts) do
    case File.read(known_hosts_path(opts)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Map.new(fn line ->
          [host, print] = String.split(line, " ", parts: 2)
          {host, String.trim(print)}
        end)

      {:error, _} ->
        %{}
    end
  end

  defp remember(key, print, opts) do
    path = known_hosts_path(opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{key} #{print}\n", [:append])
  end

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
      case verify_pin(Mint.HTTP.get_socket(conn), host, port, opts) do
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
           intended, remove the line from #{known_hosts_path(opts)}.
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
             "protocolVersion" => ExMo.Projection.JSONRPC.OpenRPC.protocol_version(),
             "clientInfo" => %{"name" => "exmo-client", "version" => "0.1.0"}
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
  def recv(session, timeout \\ 5_000) do
    receive do
      message ->
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

            frames =
              for {:text, text} <- decoded do
                :json.decode(text)
              end

            session = %{session | conn: conn, websocket: websocket}
            if frames == [], do: recv(session, timeout), else: {:ok, session, frames}

          {:error, _conn, reason, _responses} ->
            {:error, reason}
        end
    after
      timeout -> {:error, :timeout}
    end
  end
end
