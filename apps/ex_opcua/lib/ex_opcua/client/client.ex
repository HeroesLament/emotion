defmodule ExOpcUA.Client do
  @moduledoc """
  OPC UA client — public API.

  ## Usage

      {:ok, client} = ExOpcUA.Client.start_link(url: "opc.tcp://192.168.1.10:4840")

      {:ok, [data_value]} = ExOpcUA.Client.read(client, [NodeId.string(1, "J1")])

      :ok = ExOpcUA.Client.write(client, NodeId.string(1, "Command"),
                                  %Variant{type: :string, value: "stop"})

      {:ok, sub_id} = ExOpcUA.Client.subscribe(client,
        [NodeId.string(1, "J1")],
        fn changes -> IO.inspect(changes) end,
        interval: 200.0
      )

      :ok = ExOpcUA.Client.unsubscribe(client, sub_id)

      {:ok, refs} = ExOpcUA.Client.browse(client, NodeId.ns0(85))

      :ok = ExOpcUA.Client.disconnect(client)

  ## Options

  - `:url`      — `"opc.tcp://host:port"` (**required**)
  - `:identity` — `:anonymous` | `{:username, user, pass}` (default: `:anonymous`)
  - `:timeout`  — connect + request timeout in ms (default: 5000)
  """

  alias ExOpcUA.Client.Session

  @type client :: pid()

  def start_link(opts) do
    Session.start_link(opts)
  end

  @doc "Read one or more node values. Returns `{:ok, [%DataValue{}]}` or `{:error, reason}`."
  def read(client, node_ids, attribute_id \\ 13, timeout \\ 5000) when is_list(node_ids) do
    Session.read(client, node_ids, attribute_id, timeout)
  end

  @doc "Write a single value. Returns `:ok` or `{:error, reason}`."
  def write(client, node_id, variant, timeout \\ 5000) do
    Session.write(client, node_id, variant, timeout)
  end

  @doc "Browse a node. Returns `{:ok, [%ReferenceDescription{}]}` or `{:error, reason}`."
  def browse(client, node_id, opts \\ [], timeout \\ 5000) do
    Session.browse(client, node_id, opts, timeout)
  end

  @doc "Subscribe to nodes. `callback` receives `[{node_id, data_value}]` on each publish."
  def subscribe(client, node_ids, callback, opts \\ []) when is_list(node_ids) do
    Session.subscribe(client, node_ids, callback, opts)
  end

  @doc "Unsubscribe from a subscription. Returns `:ok`."
  def unsubscribe(client, sub_id, timeout \\ 5000) do
    Session.unsubscribe(client, sub_id, timeout)
  end

  @doc "Close the session and disconnect."
  def disconnect(client) do
    Session.disconnect(client)
  end

  @doc "Returns the current connection state atom."
  def state(client) do
    Session.conn_state(client)
  end
end
