defmodule ExProto.Nodes do
  @moduledoc """
  The node surface: initialize, browse, batched read and write, subscribe.

  Every method here returns `{result, session}` where result is `{:ok, value}`
  or `{:error, code, message}` using the codes in the generated OpenRPC
  document. The codes are not invented here — they are the ones
  `ExMo.Projection.JSONRPC.OpenRPC` publishes, and the test suite checks they
  have not drifted apart.

  ## Batches fail per entry, not per call

  Reads and writes take arrays and return arrays of the same length, in the
  same order, where any entry may carry an error. One unreadable node among
  twenty is a partial answer and not a failed call — a pendant rendering an
  axis should show five live values and one greyed-out cell, rather than
  nothing at all because one register is unavailable.

  Writes are explicitly not atomic. A batch that half succeeds reports exactly
  which halves, because rolling back a value that has already reached a drive
  is not something this layer can honestly offer.
  """

  alias ExProto.{Session, Source, Validate}

  # Mirrors components/errors in the generated document.
  @not_initialized -32_000
  @already_initialized -32_001
  @unsupported_version -32_002
  @unknown_node -32_003
  @not_readable -32_004
  @not_writable -32_005
  @not_observable -32_006
  @invalid_value -32_007
  @too_many_subscriptions -32_008
  @write_rejected -32_010

  @invalid_params -32_602

  @default_rate_hz 30
  @max_rate_hz 1000

  @doc false
  def error_codes do
    %{
      not_initialized: @not_initialized,
      already_initialized: @already_initialized,
      unsupported_version: @unsupported_version,
      unknown_node: @unknown_node,
      not_readable: @not_readable,
      not_writable: @not_writable,
      not_observable: @not_observable,
      invalid_value: @invalid_value,
      too_many_subscriptions: @too_many_subscriptions,
      write_rejected: @write_rejected
    }
  end

  # ── initialize ────────────────────────────────────────────────────────────

  @doc """
  Negotiates the protocol version and reports capabilities.

  A version mismatch is refused rather than guessed at. The controller reports
  what it does speak in the error's data, so a client can tell an operator
  something actionable instead of "connection failed".
  """
  def initialize(params, %Session{initialized?: true} = session) do
    _ = params
    {{:error, @already_initialized, "Session already initialized"}, session}
  end

  def initialize(params, session) do
    ours = Session.protocol_version()

    case params["protocolVersion"] do
      ^ours ->
        session =
          Session.initialize(
            session,
            ours,
            params["clientInfo"],
            params["capabilities"]
          )

        {{:ok, initialize_result(session, ours)}, session}

      nil ->
        {{:error, @invalid_params, "Invalid params: protocolVersion is required"}, session}

      other ->
        {{:error, @unsupported_version, "No mutually supported protocol version",
          %{"requested" => other, "supported" => [ours]}}, session}
    end
  end

  defp initialize_result(session, version) do
    nodes = session.table.nodes

    %{
      "protocolVersion" => version,
      "serverInfo" => %{"name" => "E-Motion Controller", "version" => "0.1.0"},
      "capabilities" => %{
        "nodes" => %{
          "count" => map_size(nodes),
          "maxRateHz" => @max_rate_hz,
          "maxSubscriptions" => Session.max_subscriptions()
        },
        # Local until a PTP-disciplined time base exists. Saying so lets a
        # client know not to overlay these timestamps with another
        # controller's, which it would otherwise have no way to discover.
        "timeBase" => "local"
      }
    }
  end

  # ── browse ────────────────────────────────────────────────────────────────

  @doc """
  Lists a node and its direct children.

  Direct children rather than a subtree: a pendant renders one level at a time,
  and a whole-model dump is the thing you least want from a controller with a
  hundred axes.
  """
  def browse(params, session) do
    with :ok <- require_initialized(session) do
      node_id = params["nodeId"] || session.table.root

      case Session.fetch_node(session, node_id) do
        {:ok, node} ->
          children =
            node.children
            |> Enum.map(&Map.fetch!(session.table.nodes, &1))
            |> Enum.map(&descriptor/1)

          {{:ok, %{"node" => descriptor(node), "children" => children}}, session}

        :error ->
          {{:error, @unknown_node, "No such node: #{node_id}"}, session}
      end
    end
    |> with_session(session)
  end

  # The schema travels with the descriptor so a client learns what a value is
  # as it discovers the node, and a generated UI can pick a control without
  # knowing anything about robots.
  defp descriptor(%{class: :object} = node) do
    drop_nils(%{
      "nodeId" => node.node_id,
      "name" => node.name,
      "class" => "object",
      "description" => node.description,
      "hasChildren" => node.children != []
    })
  end

  defp descriptor(%{class: :property} = node) do
    drop_nils(%{
      "nodeId" => node.node_id,
      "name" => node.name,
      "class" => "property",
      "description" => node.description,
      "hasChildren" => false,
      "schema" => node.schema,
      "unit" => node.unit,
      "displayUnit" => stringify(node.display_unit),
      "readable" => node.readable,
      "writable" => node.writable,
      "observable" => node.observable
    })
  end

  defp descriptor(%{class: :method} = node) do
    drop_nils(%{
      "nodeId" => node.node_id,
      "name" => node.name,
      "class" => "method",
      "description" => node.description,
      "hasChildren" => false
    })
  end

  # ── read ──────────────────────────────────────────────────────────────────

  @doc """
  Reads a batch of nodes.

  Batched because a pendant rendering twenty properties should cost one round
  trip rather than twenty. Results are positional and always the same length as
  the request.
  """
  def read(params, session) do
    with :ok <- require_initialized(session),
         {:ok, node_ids} <- fetch_list(params, "nodeIds") do
      {module, arg} = session.source

      # Nodes the model does not know about never reach the source; nodes it
      # knows are not readable never reach it either. A source should not have
      # to reimplement the model's own access rules to stay correct.
      {readable, rejected} = split_readable(session, node_ids)

      values =
        readable
        |> then(&Source.read_many(module, &1, arg))
        |> Map.new()

      results =
        Enum.map(node_ids, fn id ->
          case Map.fetch(rejected, id) do
            {:ok, error} -> node_error(id, error)
            :error -> read_entry(id, Map.get(values, id))
          end
        end)

      {:ok, %{"values" => results}}
    end
    |> with_session(session)
  end

  defp split_readable(session, node_ids) do
    Enum.reduce(node_ids, {[], %{}}, fn id, {ok, bad} ->
      case Session.fetch_node(session, id) do
        {:ok, %{class: :property, readable: true}} -> {[id | ok], bad}
        {:ok, %{class: :property}} -> {ok, Map.put(bad, id, :not_readable)}
        {:ok, _other} -> {ok, Map.put(bad, id, :not_readable)}
        :error -> {ok, Map.put(bad, id, :unknown_node)}
      end
    end)
    |> then(fn {ok, bad} -> {Enum.reverse(ok), bad} end)
  end

  defp read_entry(id, {:ok, value}) do
    %{"nodeId" => id, "value" => value, "timestamp" => timestamp()}
  end

  defp read_entry(id, {:error, reason}), do: node_error(id, reason)
  defp read_entry(id, nil), do: node_error(id, :unknown_node)

  # ── write ─────────────────────────────────────────────────────────────────

  @doc """
  Writes a batch of nodes.

  Deliberately not atomic — see the module doc. Each entry reports its own
  outcome, and a write that the source clamps reports the value the node
  actually holds rather than the one that was asked for.
  """
  def write(params, session) do
    with :ok <- require_initialized(session),
         {:ok, writes} <- fetch_list(params, "writes") do
      {module, arg} = session.source

      results =
        Enum.map(writes, fn
          %{"nodeId" => id} = request ->
            write_one(session, module, arg, id, Map.get(request, "value"))

          _other ->
            %{
              "nodeId" => nil,
              "ok" => false,
              "error" => %{
                "code" => @invalid_params,
                "message" => "each write requires a nodeId"
              }
            }
        end)

      {:ok, %{"results" => results}}
    end
    |> with_session(session)
  end

  defp write_one(session, module, arg, id, value) do
    with {:ok, node} <- fetch_writable(session, id),
         :ok <- validate(node, value) do
      case module.write(id, value, arg) do
        {:ok, applied} ->
          # The applied value, not the requested one. A drive may clamp a
          # target to a joint limit, and a client told what it asked for will
          # draw the arm somewhere it is not.
          %{"nodeId" => id, "ok" => true, "value" => applied}

        {:error, reason} ->
          write_error(id, reason)
      end
    else
      {:error, reason} -> write_error(id, reason)
      {:invalid, message} -> write_error(id, {:invalid_value, message})
    end
  end

  defp fetch_writable(session, id) do
    case Session.fetch_node(session, id) do
      {:ok, %{class: :property, writable: true} = node} -> {:ok, node}
      {:ok, _node} -> {:error, :not_writable}
      :error -> {:error, :unknown_node}
    end
  end

  defp validate(%{schema: schema}, value) when is_map(schema) do
    case Validate.check(value, schema) do
      :ok -> :ok
      {:error, message} -> {:invalid, message}
    end
  end

  defp validate(_node, _value), do: :ok

  defp write_error(id, {:invalid_value, message}) do
    %{
      "nodeId" => id,
      "ok" => false,
      "error" => %{"code" => @invalid_value, "message" => message}
    }
  end

  defp write_error(id, reason) do
    %{"nodeId" => id, "ok" => false, "error" => error_body(reason)}
  end

  # ── subscribe ─────────────────────────────────────────────────────────────

  @doc """
  Subscribes to observable nodes.

  Refuses anything the model does not mark observable, rather than accepting it
  and never delivering — a subscription that silently produces nothing is
  indistinguishable from a broken controller.

  The requested rate is advisory and the granted rate is returned. Clients must
  read what they were granted rather than assuming they got what they asked for.
  """
  def subscribe(params, session) do
    with :ok <- require_initialized(session),
         {:ok, node_ids} <- fetch_list(params, "nodeIds"),
         :ok <- all_observable(session, node_ids),
         {:ok, rate} <- fetch_rate(params) do
      case Session.subscribe(session, node_ids, rate) do
        {:ok, id, session} ->
          {{:ok,
            %{"subscriptionId" => id, "nodeIds" => node_ids, "rateHz" => rate}}, session}

        {:error, :too_many} ->
          {{:error, @too_many_subscriptions,
            "Subscription limit of #{Session.max_subscriptions()} reached"}, session}
      end
    else
      error -> {error, session}
    end
  end

  defp all_observable(session, node_ids) do
    Enum.reduce_while(node_ids, :ok, fn id, :ok ->
      case Session.fetch_node(session, id) do
        {:ok, %{class: :property, observable: true}} ->
          {:cont, :ok}

        {:ok, _node} ->
          {:halt, {:error, @not_observable, "Node is not observable: #{id}"}}

        :error ->
          {:halt, {:error, @unknown_node, "No such node: #{id}"}}
      end
    end)
  end

  defp fetch_rate(params) do
    case Map.get(params, "rateHz", @default_rate_hz) do
      rate when is_number(rate) and rate > 0 ->
        # Granted rather than requested. The ceiling is the controller's to
        # set, and a client that asked for 5 kHz gets told it is getting 1.
        {:ok, min(rate, @max_rate_hz) * 1.0}

      other ->
        {:error, @invalid_params, "Invalid params: rateHz must be positive, got #{inspect(other)}"}
    end
  end

  @doc """
  Ends a subscription. Idempotent — see `ExProto.Session.unsubscribe/2`.
  """
  def unsubscribe(params, session) do
    with :ok <- require_initialized(session),
         {:ok, id} <- fetch_string(params, "subscriptionId") do
      {{:ok, %{}}, Session.unsubscribe(session, id)}
    else
      error -> {error, session}
    end
  end

  # ── Shared ────────────────────────────────────────────────────────────────

  defp require_initialized(%Session{initialized?: true}), do: :ok

  defp require_initialized(_session) do
    {:error, @not_initialized, "Session not initialized; call initialize first"}
  end

  defp fetch_list(params, key) do
    case Map.get(params, key) do
      list when is_list(list) -> {:ok, list}
      nil -> {:error, @invalid_params, "Invalid params: #{key} is required"}
      other -> {:error, @invalid_params, "Invalid params: #{key} must be an array, got #{inspect(other)}"}
    end
  end

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, @invalid_params, "Invalid params: #{key} must be a string"}
    end
  end

  # `with` in the methods above yields either a bare result or an error tuple;
  # this pairs whichever it was back up with the session.
  defp with_session({:ok, _} = result, session), do: {result, session}
  defp with_session({:error, _, _} = error, session), do: {error, session}
  defp with_session({:error, _, _, _} = error, session), do: {error, session}
  defp with_session({result, %Session{} = session}, _outer), do: {result, session}

  defp node_error(id, reason) do
    %{"nodeId" => id, "error" => error_body(reason)}
  end

  defp error_body(:unknown_node), do: %{"code" => @unknown_node, "message" => "No such node"}
  defp error_body(:not_readable), do: %{"code" => @not_readable, "message" => "Node is not readable"}
  defp error_body(:not_writable), do: %{"code" => @not_writable, "message" => "Node is not writable"}
  defp error_body(:rejected), do: %{"code" => @write_rejected, "message" => "The controller refused the write in its current state"}

  defp error_body(other) do
    # A source returning a reason outside ExProto.Source.reason/0 is a bug in
    # that source, and saying so beats mapping it onto a plausible-looking code
    # a client would then act on.
    %{"code" => @write_rejected, "message" => "Unmapped source error: #{inspect(other)}"}
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
