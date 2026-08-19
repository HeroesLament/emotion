defmodule EMotion.Projection.OPCUA.NodeId do
  @moduledoc """
  Deterministic mapping from E-Motion schema paths to OPC-UA string NodeIds.

  All E-Motion nodes live in namespace 1 (ns=1).
  NodeIds are derived from the schema path list, joined with dots.

  Standard UA well-known nodes (Objects folder) use ns=0 numeric IDs.

  Examples:
      path_to_node_id(["EMotion"])                           # => "ns=1;s=EMotion"
      path_to_node_id(["EMotion", "Behaviors", "Catalog"])   # => "ns=1;s=EMotion.Behaviors.Catalog"
      objects_folder_id()                                  # => "ns=0;i=85"
  """

  @exmo_ns 1

  @doc "Returns the OPC-UA Objects folder NodeId (well-known)."
  @spec objects_folder_id() :: String.t()
  def objects_folder_id, do: "ns=0;i=85"

  @doc "Converts a schema path list to a stable string NodeId in namespace 1."
  @spec path_to_node_id([String.t()]) :: String.t()
  def path_to_node_id(path) when is_list(path) do
    "ns=#{@exmo_ns};s=#{Enum.join(path, ".")}"
  end

  @doc "Returns the namespace index used for E-Motion nodes."
  @spec exmo_ns() :: non_neg_integer()
  def exmo_ns, do: @exmo_ns
end
