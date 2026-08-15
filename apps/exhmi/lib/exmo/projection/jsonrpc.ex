defmodule ExMo.Projection.JSONRPC do
  @moduledoc """
  Projects an ExMo Information Model into the node table a JSON-RPC client
  browses, reads, writes and subscribes against.

  A sibling of `ExMo.Projection.OPCUA`, and deliberately the same shape: a pure
  transformation from a compiled model to a flat table, with no running server
  state involved. Everything a JSON-RPC client can discover about this
  controller comes from here, which is what stops the JSON-RPC and OPC UA
  surfaces drifting apart — they are two renderings of one model rather than
  two hand-maintained descriptions of one machine.

  ## Node identifiers are the model's own paths

  OPC UA needs opaque numeric node ids because that is what the standard wants.
  A JSON-RPC client wants something it can read in a log and type into a
  console, so nodes are identified by their dotted path: `axes.j1.position`.
  Those are already stable — they are the schema's own ids — and they survive
  the model growing around them.

  ## Types become JSON Schema

  Each property's transport-neutral type is rendered as a JSON Schema fragment,
  so a client can validate a write before sending it and a generated admin UI
  can pick a control without special-casing anything. See
  `ExMo.Projection.JSONRPC.TypeMap`.

  ## Usage

      {:ok, model} = ExMo.InformationModel.compiled_model()
      {:ok, table} = ExMo.Projection.JSONRPC.project(model)

      table.nodes["axes.j1.position"]
      #=> %{class: :property, writable: false, unit: "rad", ...}
  """

  alias ExMo.Schema.{Model, Object, Property, Method, Event}
  alias ExMo.Projection.JSONRPC.TypeMap

  @type node_class :: :object | :property | :method
  @type node_entry :: map()
  @type table :: %{root: String.t(), nodes: %{String.t() => node_entry()}}

  @doc """
  Projects a compiled model into a node table.

  Returns `{:ok, table}` where `table.nodes` is keyed by dotted path and
  `table.root` names the entry point for a browse.
  """
  @spec project(Model.t()) :: {:ok, table()} | {:error, term()}
  def project(%Model{root: root, types: types}) do
    entries = walk(root, nil, types)

    case {duplicate_ids(entries), ungranted_writes(entries)} do
      {[], []} ->
        nodes = Map.new(entries, fn entry -> {entry.node_id, entry} end)
        {:ok, %{root: node_id(root), nodes: nodes}}

      {[_ | _] = dups, _} ->
        {:error, {:duplicate_node_ids, dups}}

      {[], [_ | _] = ungranted} ->
        {:error, {:writable_without_grant, ungranted}}
    end
  rescue
    e -> {:error, e}
  end

  # The compiler checks that ids are unique among siblings, which is all a tree
  # needs. A flat table needs more: two objects could each declare a child
  # `position`, and building the map would keep one and lose the other with no
  # error anywhere. Refusing is the only honest option — a node table missing a
  # node is worse than no node table.
  defp duplicate_ids(entries) do
    entries
    |> Elixir.Enum.frequencies_by(& &1.node_id)
    |> Elixir.Enum.filter(fn {_id, count} -> count > 1 end)
    |> Elixir.Enum.map(&elem(&1, 0))
    |> Elixir.Enum.sort()
  end

  # A writable property that names no write grant is a modelling error, not a
  # property anyone may write. Refusing to project it means the mistake surfaces
  # when the model is built — in a test, at boot — rather than as an
  # unauthorised write that nobody notices because it succeeded.
  #
  # The alternative, defaulting to some grant, is worse in both directions: a
  # permissive default is an open door, and a restrictive one silently makes a
  # property unwritable and sends somebody hunting through the transport for a
  # bug that is in the model.
  defp ungranted_writes(entries) do
    entries
    |> Elixir.Enum.filter(&(&1.class == :property and &1.writable and is_nil(&1.write_grant)))
    |> Elixir.Enum.map(& &1.node_id)
    |> Elixir.Enum.sort()
  end

  @doc """
  Direct children of a node, in declaration order.

  Browse returns children rather than a subtree because a pendant renders one
  level at a time and a whole-model dump is the thing you least want on a
  controller with a hundred axes.
  """
  @spec children(table(), String.t()) :: [node_entry()]
  def children(%{nodes: nodes}, node_id) do
    case Map.fetch(nodes, node_id) do
      {:ok, %{children: ids}} -> Enum.map(ids, &Map.fetch!(nodes, &1))
      :error -> []
    end
  end

  @doc "Every node of a given class, for tests and inspection."
  @spec filter(table(), node_class()) :: [node_entry()]
  def filter(%{nodes: nodes}, class) do
    nodes |> Map.values() |> Enum.filter(&(&1.class == class))
  end

  @doc """
  Every observable property, which is exactly the set a client may subscribe to.

  Kept as a function rather than left to callers to filter, because "what can I
  subscribe to" is a question the protocol has to answer identically every time
  it is asked.
  """
  @spec observable(table()) :: [node_entry()]
  def observable(table) do
    table |> filter(:property) |> Enum.filter(& &1.observable)
  end

  # ── Walking ───────────────────────────────────────────────────────────────

  defp walk(%Object{} = obj, parent, types) do
    id = node_id(obj)
    child_nodes = Enum.reject(obj.children, &match?(%Event{}, &1))

    entry = %{
      node_id: id,
      name: obj.name,
      class: :object,
      description: obj.description,
      parent: parent,
      children: Enum.map(child_nodes, &node_id/1),
      meta: obj.meta || %{}
    }

    [entry | Enum.flat_map(child_nodes, &walk(&1, id, types))]
  end

  defp walk(%Property{} = prop, parent, types) do
    meta = prop.meta || %{}

    [
      %{
        node_id: node_id(prop),
        name: prop.name,
        class: :property,
        description: prop.description,
        parent: parent,
        children: [],
        schema: TypeMap.to_json_schema(prop.type, types),
        # The unit of the value on the wire. Always SI; see ExMo.Schema.FromAxis.
        unit: prop.unit,
        # How a human-facing surface should render it. Never affects the wire.
        display_unit: Map.get(meta, :display_unit),
        readable: prop.readable,
        writable: prop.writable,
        observable: prop.observable,
        # The authorisation the enforcement point checks. See
        # ExMo.Schema.Property on why these live on the model and not here.
        read_grant: prop.read_grant,
        write_grant: prop.write_grant,
        default: prop.default,
        meta: meta
      }
    ]
  end

  defp walk(%Method{} = meth, parent, types) do
    [
      %{
        node_id: node_id(meth),
        name: meth.name,
        class: :method,
        description: meth.description,
        parent: parent,
        children: [],
        async: meth.async,
        params: Enum.map(meth.input_args, &argument(&1, types)),
        result: Enum.map(meth.output_args, &result_field(&1, types)),
        meta: meth.meta || %{}
      }
    ]
  end

  # Events are modelled but not projected yet — they belong to the journal and
  # its sequence numbers rather than to the node table, and pretending
  # otherwise would invite a client to subscribe to a fault the way it
  # subscribes to a position. Faults are not a stream.
  defp walk(%Event{}, _parent, _types), do: []

  defp argument(arg, types) do
    %{
      name: arg.name,
      description: arg.description,
      required: arg.required,
      schema: TypeMap.to_json_schema(arg.type, types)
    }
  end

  defp result_field(field, types) do
    %{
      name: field.name,
      description: field.description,
      schema: TypeMap.to_json_schema(field.type, types)
    }
  end

  # Deliberately the schema id rather than the compiled path. The compiler
  # derives paths from display *names* — ["ExMo", "Axes", "J1", "Position"] —
  # which is correct for OPC UA browse names and wrong for an identifier a
  # client stores, logs, and types. Ids are already dotted, already stable, and
  # do not move when someone renames a display label.
  defp node_id(%{id: id}), do: id
end
