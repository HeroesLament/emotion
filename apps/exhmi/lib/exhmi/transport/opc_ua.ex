defmodule ExHMI.Transport.OpcUA do
  @moduledoc """
  OPC UA server transport for EMotion.

  Implements `ExOpcUA.Server.NodeManager` to expose the arm's state to any
  OPC UA client — including RoboDK's OPC UA add-in.

  The model here is pull-on-read: `handle_read/1` calls
  `ExHMI.AddressSpace.snapshot/0` synchronously when a client reads a node.
  No timer, no push. Clients that want live data use subscriptions — the
  ex_opcua server calls `handle_read` on each publish tick per monitored item.

  ## Address Space layout (namespace index 1)

  Objects/
  └── ExMo  (object node)
      ├── Joints/
      │   └── J1..J6        (Double, read-only, radians)
      ├── TCP/
      │   └── X, Y, Z, RX, RY, RZ  (Double, read-only, metres/radians)
      ├── MotionState       (String, read-only)
      └── Command           (String, read-write)

  ## Starting (in ExHMI.Application or your supervision tree)

      {ExOpcUA.Server, [
        port: 4840,
        node_manager: ExHMI.Transport.OpcUA,
        application_name: "ExMo Robot Controller"
      ]}

  ## Connecting RoboDK

  Tools → OPC UA add-in → opc.tcp://<controller-ip>:4840/
  Browse Objects/ExMo to find all nodes.
  """

  @behaviour ExOpcUA.Server.NodeManager

  alias ExOpcUA.Server.NodeManager
  alias ExOpcUA.Codec.Services.{ReadValueId, WriteValue, BrowseDescription, BrowseResult,
                                 ReferenceDescription}
  alias ExOpcUA.Codec.Types.{NodeId, QualifiedName, LocalizedText}

  require Logger

  @ns 1

  @node_exmo    "ExMo"
  @node_joints  "ExMo.Joints"
  @node_tcp     "ExMo.TCP"
  @node_motion  "ExMo.MotionState"
  @node_command "ExMo.Command"

  @joint_names ~w(J1 J2 J3 J4 J5 J6)
  @tcp_names   ~w(X Y Z RX RY RZ)

  @joint_node_ids Enum.map(@joint_names, &"#{@node_joints}.#{&1}")
  @tcp_node_ids   Enum.map(@tcp_names,   &"#{@node_tcp}.#{&1}")

  # ── NodeManager callbacks ─────────────────────────────────────────────────

  @impl true
  def init_space do
    Logger.info("[ExHMI.OpcUA] address space ready (ns=#{@ns})")
    :ok
  end

  @impl true
  def handle_read(%ReadValueId{node_id: %NodeId{ns: @ns, type: :string, id: id}}) do
    cond do
      id in @joint_node_ids ->
        "ExMo.Joints." <> name = id
        idx  = Enum.find_index(@joint_names, &(&1 == name)) || 0
        snap = ExHMI.AddressSpace.snapshot()
        NodeManager.double_data_value(Enum.at(snap.joint_positions, idx, 0.0))

      id in @tcp_node_ids ->
        "ExMo.TCP." <> axis = id
        snap = ExHMI.AddressSpace.snapshot()
        NodeManager.double_data_value(tcp_axis(snap, axis))

      id == @node_motion ->
        snap = ExHMI.AddressSpace.snapshot()
        NodeManager.string_data_value(Atom.to_string(snap.motion_state))

      id == @node_command ->
        NodeManager.string_data_value("")

      id in [@node_exmo, @node_joints, @node_tcp] ->
        NodeManager.null_data_value()

      true ->
        NodeManager.bad_node_id_data_value()
    end
  end

  def handle_read(_), do: NodeManager.bad_node_id_data_value()

  @impl true
  def handle_write(%WriteValue{
        node_id: %NodeId{ns: @ns, type: :string, id: @node_command},
        value: dv
      }) do
    cmd = dv.value && dv.value.value
    if cmd && cmd != "" do
      Logger.debug("[ExHMI.OpcUA] Command: #{inspect(cmd)}")
      ExHMI.AddressSpace.handle_command(cmd)
    end
    0  # StatusCode Good
  end

  def handle_write(%WriteValue{node_id: nid}) do
    Logger.warning("[ExHMI.OpcUA] write rejected: #{inspect(nid)}")
    ExOpcUA.Codec.Primitives.status_bad_not_writable()
  end

  @impl true
  def handle_browse(%BrowseDescription{node_id: %NodeId{ns: 0, id: 85}}) do
    # Objects folder — return the top-level ExMo object
    %BrowseResult{
      status_code: 0,
      continuation_point: nil,
      references: [object_ref(@node_exmo, "ExMo")]
    }
  end

  def handle_browse(%BrowseDescription{node_id: %NodeId{ns: @ns, id: id}}) when is_binary(id) do
    %BrowseResult{
      status_code: 0,
      continuation_point: nil,
      references: browse_children(id)
    }
  end

  def handle_browse(_), do: NodeManager.empty_browse_result()

  # ── Browse tree ───────────────────────────────────────────────────────────

  defp browse_children(@node_exmo) do
    [
      object_ref(@node_joints,  "Joints"),
      object_ref(@node_tcp,     "TCP"),
      variable_ref(@node_motion,  "MotionState"),
      variable_ref(@node_command, "Command")
    ]
  end

  defp browse_children(@node_joints) do
    Enum.map(@joint_names, &variable_ref("#{@node_joints}.#{&1}", &1))
  end

  defp browse_children(@node_tcp) do
    Enum.map(@tcp_names, &variable_ref("#{@node_tcp}.#{&1}", &1))
  end

  defp browse_children(_), do: []

  # ── Reference helpers ─────────────────────────────────────────────────────

  defp object_ref(id, name) do
    %ReferenceDescription{
      reference_type_id: NodeId.ns0(35),             # Organizes
      is_forward:        true,
      node_id:           NodeId.string(@ns, id),
      browse_name:       %QualifiedName{ns: @ns, name: name},
      display_name:      %LocalizedText{locale: "en", text: name},
      node_class:        1,                           # Object
      type_definition:   NodeId.ns0(58)               # BaseObjectType
    }
  end

  defp variable_ref(id, name) do
    %ReferenceDescription{
      reference_type_id: NodeId.ns0(47),             # HasComponent
      is_forward:        true,
      node_id:           NodeId.string(@ns, id),
      browse_name:       %QualifiedName{ns: @ns, name: name},
      display_name:      %LocalizedText{locale: "en", text: name},
      node_class:        2,                           # Variable
      type_definition:   NodeId.ns0(63)               # BaseDataVariableType
    }
  end

  # ── Value helpers ─────────────────────────────────────────────────────────

  defp tcp_axis(snap, axis) do
    {x, y, z}    = snap.tcp_xyz
    {rx, ry, rz} = snap.tcp_rpy
    %{"X" => x, "Y" => y, "Z" => z, "RX" => rx, "RY" => ry, "RZ" => rz}
    |> Map.get(axis, 0.0)
  end
end
