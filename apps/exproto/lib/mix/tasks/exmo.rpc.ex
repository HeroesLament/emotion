defmodule Mix.Tasks.Exmo.Rpc do
  @moduledoc """
  Talks to a running controller over the JSON-RPC API.

      mix exmo.rpc login --user operator
      mix exmo.rpc info
      mix exmo.rpc browse [nodeId]
      mix exmo.rpc read <nodeId> [nodeId...]
      mix exmo.rpc write <nodeId> <value>
      mix exmo.rpc call <nodeId> [key=value ...]
      mix exmo.rpc jog <nodeId> <velocity> [--for 3] [--axis z] [--frame tool]
      mix exmo.rpc watch <nodeId> [nodeId...] [--rate 5] [--for 10]

  Options: `--host` (localhost), `--port` (4001), `--user`, `--insecure`.

  `login` stores the returned token in `.emotion/token`; every other command
  reads it. The token is what the controller checks, so this is the same path a
  pendant takes — the password is used once and then not again.

  The controller's certificate is pinned on first connection and checked on
  every one after. A changed fingerprint stops the command.

  ## Jogging from a terminal

  `jog` is the one command that is *held* rather than sent. It asserts at 10 Hz
  for `--for` seconds and then simply stops, which is what a pendant does when
  the operator lets go — and, more to the point, what a pendant does when it
  crashes. What follows the last assertion is the controller's doing, not this
  task's: it prints the axis settling to prove nothing here sent a stop.

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

    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          host: :string,
          port: :integer,
          user: :string,
          rate: :float,
          for: :integer,
          axis: :string,
          frame: :string,
          insecure: :boolean
        ]
      )

    # Strict parsing collects unknown switches rather than failing, and ignoring
    # that collection is how `--frame tool` spent an afternoon being silently
    # dropped while the arm jogged in base and looked entirely correct doing it.
    # An option the tool does not understand is a question it cannot answer.
    unless invalid == [] do
      Mix.raise(
        "unknown option#{if length(invalid) > 1, do: "s"}: " <>
          Enum.map_join(invalid, ", ", fn {switch, _value} -> switch end)
      )
    end

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
      ["call", node | args] -> with_session(host, port, conn_opts, &invoke(&1, &2, node, args))
      ["jog", node, velocity] -> with_session(host, port, conn_opts, &jog(&1, &2, node, velocity, opts))
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

  defp invoke(session, _result, node_id, args) do
    params =
      case arguments(args) do
        arguments when map_size(arguments) == 0 -> %{"nodeId" => node_id}
        arguments -> %{"nodeId" => node_id, "arguments" => arguments}
      end

    case Client.request(session, "nodes/call", params) do
      {:ok, _session, %{"result" => result}} ->
        # Accepted, not finished. Saying so here rather than printing something
        # that reads like completion, because the difference matters on a
        # machine that takes time to obey.
        Mix.shell().info("  #{result["nodeId"]} accepted")

        if result["async"] do
          Mix.shell().info("  watch the axis state for the outcome: mix exmo.rpc watch <axis>.state")
        end

      {:ok, _session, %{"error" => error}} ->
        Mix.shell().error("  #{error["message"]} (#{error["code"]})")

        if grant = get_in(error, ["data", "requiredGrant"]) do
          Mix.shell().error("  this account does not hold the #{grant} grant")
        end
    end
  end

  # ── jog ───────────────────────────────────────────────────────────────────

  defp jog(session, _result, node_id, raw, opts) do
    velocity = raw |> coerce() |> as_float()
    seconds = Keyword.get(opts, :for, 3)
    until = System.monotonic_time(:millisecond) + seconds * 1000

    Mix.shell().info("\n  holding #{node_id} at #{velocity} for #{seconds}s, asserting at 10 Hz")

    case hold(session, node_id, velocity, until, nil, opts) do
      {:ok, session, granted} ->
        Mix.shell().info("""

          let go. Nothing below is sent by this task — the last assertion was
          #{granted}ms of authority and the controller is on its own now.
        """)

        settle(session, watched(node_id), 6)

      {:error, message} ->
        Mix.shell().error("  #{message}")
    end
  end

  # `key=value` pairs, so any method with arguments can be called from here
  # rather than only the ones that happen to have a dedicated switch. Numbers are
  # parsed as numbers because the model's schemas are typed and a string where a
  # double belongs is refused — correctly, and confusingly if the client is what
  # turned it into a string.
  defp arguments(args) do
    Map.new(args, fn arg ->
      case String.split(arg, "=", parts: 2) do
        [key, value] -> {key, coerce(value)}
        [_no_equals] -> Mix.raise("arguments are key=value, got #{inspect(arg)}")
      end
    end)
  end

  defp put_if(arguments, key, name, opts) do
    case Keyword.get(opts, key) do
      nil -> arguments
      value -> Map.put(arguments, name, value)
    end
  end

  defp hold(session, node_id, velocity, until, granted, opts) do
    if System.monotonic_time(:millisecond) >= until do
      {:ok, session, granted}
    else
      # `--axis` and `--frame` are what a Cartesian jog needs and a joint jog has
      # no use for: `axes.j1.jog` is already the axis and has only one frame,
      # while `axes.jog_cartesian` has six directions and a choice of frame.
      # Omitted rather than defaulted, so a joint jog does not start carrying
      # arguments that mean nothing to it.
      arguments =
        %{"velocity" => velocity}
        |> put_if(:axis, "axis", opts)
        |> put_if(:frame, "frame", opts)

      params = %{"nodeId" => node_id, "arguments" => arguments}

      case Client.request(session, "nodes/call", params) do
        {:ok, session, %{"result" => result}} ->
          Process.sleep(100)
          hold(session, node_id, velocity, until, result["deadlineMs"], opts)

        {:ok, _session, %{"error" => error}} ->
          {:error, "#{error["message"]} (#{error["code"]})"}
      end
    end
  end

  # Reads the axis every 150ms after the assertions stop. A jog that had to be
  # stopped by the client would show a velocity that never changes.
  # What to watch after letting go. A joint jog settles on its own velocity and
  # state; a Cartesian jog has neither — six joints do, and what the operator
  # was actually commanding was the tool, so that is what should be seen coming
  # to rest.
  defp watched(node_id) do
    if String.ends_with?(node_id, ".jog_cartesian") do
      {:tcp, parent(node_id)}
    else
      {:axis, parent(node_id)}
    end
  end

  defp settle(_session, _watched, 0), do: Mix.shell().info("")

  defp settle(session, watched, remaining) do
    ids =
      case watched do
        {:tcp, prefix} -> ["#{prefix}.tcp.x", "#{prefix}.tcp.y", "#{prefix}.tcp.z"]
        {:axis, axis} -> ["#{axis}.velocity", "#{axis}.state"]
      end

    case Client.request(session, "nodes/read", %{"nodeIds" => ids}) do
      {:ok, session, %{"result" => result}} ->
        line =
          Enum.map_join(result["values"], "   ", fn v ->
            "#{v["nodeId"]}=#{inspect(v["value"] || v["error"]["message"])}"
          end)

        Mix.shell().info("  #{line}")
        Process.sleep(150)
        settle(session, watched, remaining - 1)

      {:ok, _session, %{"error" => error}} ->
        Mix.shell().error("  #{error["message"]}")
    end
  end

  defp parent(node_id) do
    node_id |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")
  end

  # The model says double, and a controller typed double rejects an integer for
  # the same reason a uint16 rejects 3.0.
  defp as_float(value) when is_integer(value), do: value * 1.0
  defp as_float(value), do: value

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
