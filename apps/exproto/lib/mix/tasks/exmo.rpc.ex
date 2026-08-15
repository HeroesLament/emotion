defmodule Mix.Tasks.Exmo.Rpc do
  @moduledoc """
  Talks to a running controller over the JSON-RPC API.

      mix exmo.rpc login --user operator
      mix exmo.rpc info
      mix exmo.rpc browse [nodeId]
      mix exmo.rpc read <nodeId> [nodeId...]
      mix exmo.rpc write <nodeId> <value>
      mix exmo.rpc watch <nodeId> [nodeId...] [--rate 5] [--for 10]

  Options: `--host` (localhost), `--port` (4001), `--user`, `--insecure`.

  `login` stores the returned token in `.emotion/token`; every other command
  reads it. The token is what the controller checks, so this is the same path a
  pendant takes — the password is used once and then not again.

  The controller's certificate is pinned on first connection and checked on
  every one after. A changed fingerprint stops the command.

  ## Runs alongside a live controller

  Starts no applications, so it does not contend for ports the controller
  already holds. It is a network client and nothing more.
  """

  @shortdoc "Browse, read, write and watch a running controller"

  use Mix.Task

  alias ExLink, as: Client

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:mint_web_socket)

    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [host: :string, port: :integer, user: :string, rate: :float, for: :integer, insecure: :boolean]
      )

    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 4001)
    conn_opts = [insecure: Keyword.get(opts, :insecure, false)]

    case args do
      ["login"] -> login(host, port, Keyword.get(opts, :user, "operator"), conn_opts)
      ["info"] -> with_session(host, port, conn_opts, &info/2)
      ["browse"] -> with_session(host, port, conn_opts, &browse(&1, &2, nil))
      ["browse", node] -> with_session(host, port, conn_opts, &browse(&1, &2, node))
      ["read" | ids] when ids != [] -> with_session(host, port, conn_opts, &read(&1, &2, ids))
      ["write", node, value] -> with_session(host, port, conn_opts, &write(&1, &2, node, value))
      ["watch" | ids] when ids != [] -> with_session(host, port, conn_opts, &watch(&1, &2, ids, opts))
      _ -> Mix.shell().info(@moduledoc)
    end
  end

  # ── login ─────────────────────────────────────────────────────────────────

  defp login(host, port, username, conn_opts) do
    password = String.trim(Mix.shell().prompt("password for #{username}: ") || "")

    case Client.login(host, port, username, password, conn_opts) do
      {:ok, %{"token" => token} = result} ->
        File.mkdir_p!(Path.dirname(token_path()))
        File.write!(token_path(), token)
        File.chmod!(token_path(), 0o600)

        Mix.shell().info("""

        logged in as #{result["username"]} (#{result["role"]})
        grants: #{Enum.join(result["grants"], ", ")}

        token saved to #{token_path()} (mode 0600)
        """)

      {:error, {429, body}} ->
        Mix.shell().error("throttled — retry in #{body["retryAfter"]}s")

      {:error, {status, body}} ->
        Mix.shell().error("login failed (HTTP #{status}): #{inspect(body)}")

      {:error, reason} ->
        Mix.shell().error(format(reason))
    end
  end

  defp token_path, do: Path.join([File.cwd!(), ".emotion", "token"])

  defp with_session(host, port, conn_opts, fun) do
    with {:ok, token} <- token(),
         {:ok, session, result} <- Client.connect(host, port, token, conn_opts) do
      fun.(session, result)
    else
      {:error, :no_token} ->
        Mix.shell().error("not logged in — run: mix exmo.rpc login --user operator")

      {:error, %{"message" => message}} ->
        Mix.shell().error("controller refused: #{message}")

      {:error, {:upgrade_refused, 401, _}} ->
        Mix.shell().error("the controller rejected this token. Log in again.")

      {:error, reason} ->
        Mix.shell().error(format(reason))
    end
  end

  defp token do
    case File.read(token_path()) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, _} -> {:error, :no_token}
    end
  end

  # ── commands ──────────────────────────────────────────────────────────────

  defp info(_session, result) do
    nodes = result["capabilities"]["nodes"]

    Mix.shell().info("""

      server     #{result["serverInfo"]["name"]} #{result["serverInfo"]["version"]}
      protocol   #{result["protocolVersion"]}
      nodes      #{nodes["count"]}
      max rate   #{nodes["maxRateHz"]} Hz
      max subs   #{nodes["maxSubscriptions"]}
      time base  #{result["capabilities"]["timeBase"]}
    """)
  end

  defp browse(session, _result, node_id) do
    # nodeId omitted rather than guessed. The controller defaults a browse with
    # no nodeId to its own root, which is the only way a client that has just
    # connected can start — it has no node id yet and should not have to know
    # what the root of someone else's model is called.
    params = if node_id, do: %{"nodeId" => node_id}, else: %{}

    case Client.request(session, "nodes/browse", params) do
      {:ok, _session, %{"result" => result}} ->
        Mix.shell().info("\n  #{result["node"]["nodeId"]}")

        for child <- result["children"] do
          Mix.shell().info(describe(child))
        end

        Mix.shell().info("")

      {:ok, _session, %{"error" => error}} ->
        Mix.shell().error("#{error["message"]} (#{error["code"]})")
    end
  end

  defp describe(%{"class" => "property"} = node) do
    access =
      cond do
        node["writable"] -> "rw"
        node["readable"] -> "r-"
        true -> "--"
      end

    unit = if node["unit"], do: " #{node["unit"]}", else: ""
    "  #{access} #{String.pad_trailing(node["nodeId"], 32)}#{unit}"
  end

  defp describe(node) do
    "  #{String.pad_trailing(node["class"], 3)} #{String.pad_trailing(node["nodeId"], 32)} #{node["description"] || node["name"]}"
  end

  defp read(session, _result, ids) do
    case Client.request(session, "nodes/read", %{"nodeIds" => ids}) do
      {:ok, _session, %{"result" => result}} ->
        Mix.shell().info("")

        for value <- result["values"] do
          case value do
            %{"error" => error} ->
              Mix.shell().info("  #{String.pad_trailing(value["nodeId"], 32)} ! #{error["message"]}")

            %{"value" => v} ->
              Mix.shell().info("  #{String.pad_trailing(value["nodeId"], 32)} #{inspect(v)}")
          end
        end

        Mix.shell().info("")

      {:ok, _session, %{"error" => error}} ->
        Mix.shell().error("#{error["message"]} (#{error["code"]})")
    end
  end

  defp write(session, _result, node_id, raw) do
    value = coerce(raw)

    case Client.request(session, "nodes/write", %{
           "writes" => [%{"nodeId" => node_id, "value" => value}]
         }) do
      {:ok, _session, %{"result" => %{"results" => [%{"ok" => true, "value" => applied}]}}} ->
        # The applied value, which is not always the requested one.
        Mix.shell().info("  #{node_id} = #{inspect(applied)}")

      {:ok, _session, %{"result" => %{"results" => [%{"error" => error}]}}} ->
        Mix.shell().error("  refused: #{error["message"]}")

        if grant = get_in(error, ["data", "requiredGrant"]) do
          Mix.shell().error("  this account does not hold the #{grant} grant")
        end

      {:ok, _session, %{"error" => error}} ->
        Mix.shell().error("#{error["message"]} (#{error["code"]})")
    end
  end

  # A CLI argument is a string; the node's schema is not. Integers stay
  # integers because a node typed uint16 rejects 3.0.
  defp coerce(raw) do
    cond do
      raw in ["true", "false"] -> raw == "true"
      match?({_, ""}, Integer.parse(raw)) -> raw |> Integer.parse() |> elem(0)
      match?({_, ""}, Float.parse(raw)) -> raw |> Float.parse() |> elem(0)
      true -> raw
    end
  end

  defp watch(session, _result, ids, opts) do
    rate = Keyword.get(opts, :rate, 5.0)
    seconds = Keyword.get(opts, :for, 10)

    case Client.request(session, "nodes/subscribe", %{"nodeIds" => ids, "rateHz" => rate}) do
      {:ok, session, %{"result" => result}} ->
        Mix.shell().info("\n  subscription #{result["subscriptionId"]} at #{result["rateHz"]} Hz, #{seconds}s\n")
        Mix.shell().info("  Only CHANGED values are sent, so a quiet axis produces no lines.\n")
        stream(session, System.monotonic_time(:millisecond) + seconds * 1000)
        Mix.shell().info("")

      {:ok, _session, %{"error" => error}} ->
        Mix.shell().error("#{error["message"]} (#{error["code"]})")

        if grant = get_in(error, ["data", "requiredGrant"]) do
          Mix.shell().error("  this account does not hold the #{grant} grant")
        end
    end
  end

  defp stream(session, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case Client.recv(session, remaining) do
        {:ok, session, frames} ->
          for frame <- frames, frame["method"] == ExProto.Publisher.method() do
            params = frame["params"]

            values =
              Enum.map_join(params["values"], "   ", fn v ->
                "#{v["nodeId"]}=#{inspect(v["value"])}"
              end)

            Mix.shell().info("  seq #{String.pad_leading(to_string(params["seq"]), 3)}  #{values}")
          end

          stream(session, deadline)

        {:error, :timeout} ->
          :ok

        {:error, reason} ->
          Mix.shell().error(format(reason))
      end
    end
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(%{reason: reason}), do: inspect(reason)
  defp format(reason), do: inspect(reason)
end
