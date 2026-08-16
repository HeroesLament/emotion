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

  alias ExMo.Schema.Method
  alias ExProto.{Jog, Session, Source, Validate}

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
  @forbidden -32_011
  @not_callable -32_012
  @node_held -32_013
  @wrong_mode -32_014

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
      write_rejected: @write_rejected,
      forbidden: @forbidden,
      not_callable: @not_callable,
      node_held: @node_held,
      wrong_mode: @wrong_mode
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
        {:ok, %{class: :property, readable: true} = node} ->
          if Session.can?(session, node.read_grant) do
            {[id | ok], bad}
          else
            {ok, Map.put(bad, id, {:forbidden, node.read_grant})}
          end

        {:ok, %{class: :property}} ->
          {ok, Map.put(bad, id, :not_readable)}

        {:ok, _other} ->
          {ok, Map.put(bad, id, :not_readable)}

        :error ->
          {ok, Map.put(bad, id, :unknown_node)}
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
      {:ok, %{class: :property, writable: true} = node} ->
        # Authorisation is checked after writability and before validation, so
        # a caller without the grant learns nothing about whether the value it
        # tried to send would have been accepted.
        if Session.can?(session, node.write_grant) do
          {:ok, node}
        else
          {:error, {:forbidden, node.write_grant}}
        end

      {:ok, _node} ->
        {:error, :not_writable}

      :error ->
        {:error, :unknown_node}
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

  # ── call ──────────────────────────────────────────────────────────────────

  @doc """
  Invokes a method node.

  ## Acceptance, not completion

  Every command the model declares is asynchronous, and this returns when one
  has been accepted rather than when the machine has finished. A CiA 402 enable
  is three control words through a state machine that may refuse them; homing
  takes as long as it takes. Blocking until the drive agreed would make the
  protocol describe a machine mid-movement as though it had stopped.

  So the result is an acceptance, and the outcome is watched on the axis's
  `state`, which is subscribable and which an operator is watching anyway.
  """
  def call(params, session) do
    with :ok <- require_initialized(session),
         {:ok, node_id} <- fetch_string(params, "nodeId"),
         {:ok, node} <- fetch_callable(session, node_id) do
      args = Map.get(params, "arguments") || %{}

      if Method.watchdog?(node) do
        assert_held(node, node_id, args, session)
      else
        invoke(node, node_id, args, session)
      end
    end
    |> with_session(session)
  end

  # An ordinary command on a node that is being jogged supersedes the jog, and
  # the hold goes with it. Releasing rather than zeroing first: whoever sent
  # `stop` gets to decide what the axis does, and a zero setpoint racing their
  # command in is a second opinion nobody asked for.
  #
  # It releases a hold belonging to another session on purpose. A stop that
  # cannot stop a machine because someone else is holding the joystick is not a
  # stop, and the person sending it can generally see the arm.
  defp invoke(node, node_id, args, session) do
    {module, arg} = session.source
    Jog.release(node.parent, session.jog)

    case Source.call(module, node_id, args, arg) do
      :ok ->
        {:ok, acceptance(node, node_id)}

      # A command with an answer that exists now and nowhere else — what is
      # stored, or whether a teach created a row or overwrote one. Merged into
      # the acceptance rather than replacing it, so a client that only checks
      # `accepted` reads this the same as any other call.
      {:ok, result} when is_map(result) ->
        {:ok, Map.put(acceptance(node, node_id), "result", result)}

      {:error, reason} ->
        call_error(reason)
    end
  end

  defp acceptance(node, node_id) do
    %{"nodeId" => node_id, "accepted" => true, "async" => node.async}
  end

  # A held command. The hold is taken on the node's parent rather than on the
  # method, so a second session cannot pick a different method on the same axis
  # and move it out from under the first.
  defp assert_held(node, node_id, args, session) do
    with {:ok, args} <- watchdog_args(args) do
      case Jog.assert(node.parent, node_id, args, session.source, self(), session.jog) do
        {:ok, deadline} ->
          {:ok,
           %{
             "nodeId" => node_id,
             "accepted" => true,
             "async" => node.async,
             # Granted, not requested. A client that re-asserts on the deadline
             # it asked for rather than the one it got will be stopped for it.
             "deadlineMs" => deadline
           }}

        {:error, reason} ->
          call_error(reason)
      end
    end
  end

  # The one argument the watchdog itself depends on, checked here rather than
  # left to the source: the controller has to know the neutral value of what it
  # is asserting before it accepts responsibility for asserting it.
  defp watchdog_args(args) do
    case Map.get(args, "velocity") do
      value when is_float(value) -> {:ok, args}
      value when is_integer(value) -> {:ok, Map.put(args, "velocity", value * 1.0)}
      _ -> {:error, @invalid_params, "Invalid params: arguments.velocity must be a number"}
    end
  end

  defp fetch_callable(session, node_id) do
    case Session.fetch_node(session, node_id) do
      {:ok, %{class: :method} = node} ->
        # Authorisation before invocation, and before validating arguments: a
        # caller without the grant learns nothing about whether its arguments
        # would have been accepted.
        if Session.can?(session, node.call_grant) do
          {:ok, node}
        else
          {:error, @forbidden, "Requires the #{node.call_grant} grant",
           %{"nodeId" => node_id, "requiredGrant" => Atom.to_string(node.call_grant)}}
        end

      {:ok, _other} ->
        {:error, @not_callable, "Node is not a method: #{node_id}"}

      :error ->
        {:error, @unknown_node, "No such node: #{node_id}"}
    end
  end

  defp call_error(:not_callable),
    do: {:error, @not_callable, "This controller has no command bound to that node"}

  defp call_error(:unknown_node), do: {:error, @unknown_node, "No such node"}

  defp call_error(:held),
    do:
      {:error, @node_held,
       "Another session is holding this node. Only one may jog an axis at a time"}

  # Fail closed. The watchdog being absent is a server fault, and the wrong
  # thing to do with it is start motion that nothing is left to stop.
  defp call_error(:unavailable),
    do:
      {:error, @write_rejected,
       "The jog watchdog is not running; refusing to command motion nothing would stop"}

  # Its own code, carrying the mode. A client refused with a generic "rejected"
  # can only say the controller said no; one that is told the mode can say what
  # is actually true — the machine is in AUTO — and an operator can go and turn
  # the key rather than filing a bug.
  defp call_error({:wrong_mode, mode}),
    do:
      {:error, @wrong_mode,
       "The controller is in #{mode} mode; jogging is only permitted in manual",
       %{"mode" => Atom.to_string(mode)}}

  # The command could not be started — not that it started and failed. What
  # happened after acceptance is on `state`.
  defp call_error(:rejected),
    do: {:error, @write_rejected, "The controller refused the command in its current state"}

  defp call_error(other),
    do: {:error, @write_rejected, "Unmapped source error: #{inspect(other)}"}


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
         :ok <- all_readable_grant(session, node_ids),
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

  defp all_readable_grant(session, node_ids) do
    # A subscription is a read that repeats, so it needs the read grant. Without
    # this, an observer denied a one-off read could subscribe to the same node
    # and get it thirty times a second.
    Enum.reduce_while(node_ids, :ok, fn id, :ok ->
      case Session.fetch_node(session, id) do
        {:ok, %{class: :property} = node} ->
          if Session.can?(session, node.read_grant) do
            {:cont, :ok}
          else
            {:halt, {:error, @forbidden, "Requires the #{node.read_grant} grant",
                     %{"nodeId" => id, "requiredGrant" => Atom.to_string(node.read_grant)}}}
          end

        _other ->
          {:cont, :ok}
      end
    end)
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

  # Names the grant that was missing. Telling a caller which permission it
  # lacks is the difference between an operator who knows to ask for the
  # maintainer role and one who files a bug about the arm being broken. It
  # leaks nothing: the grant a node requires is already published in the
  # OpenRPC document and readable by anyone who can browse.
  defp error_body({:forbidden, grant}) do
    %{
      "code" => @forbidden,
      "message" => "Requires the #{grant} grant",
      "data" => %{"requiredGrant" => Atom.to_string(grant)}
    }
  end

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
