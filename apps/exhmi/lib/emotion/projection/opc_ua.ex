defmodule EMotion.Projection.OPCUA do
  @moduledoc """
  Projects an E-Motion Information Model into a flat list of OPC-UA NodeSpecs.

  This is a pure transformation — it does not mutate any running server state.
  The resulting NodeSpecs can be inspected/tested standalone, then fed into
  ExHMI.AddressSpace or ExOpcUA.Server.NodeManager in a later integration pass.

  ## Usage

      {:ok, model} = EMotion.InformationModel.compiled_model()
      {:ok, nodes} = EMotion.Projection.OPCUA.project(model)
      IO.inspect(nodes, pretty: true, limit: :infinity)

  ## Node counts

  The projection emits one NodeSpec per schema node:
  - Object   -> :object node
  - Property -> :variable node
  - Method   -> :method node
  - Event    -> (deferred, not yet emitted)
  """

  alias EMotion.Schema.Model
  alias EMotion.Projection.OPCUA.{NodeSpec, Walker}

  @spec project(Model.t()) :: {:ok, [NodeSpec.t()]} | {:error, term()}
  def project(%Model{} = model) do
    nodes = Walker.walk(model)
    {:ok, nodes}
  rescue
    e -> {:error, e}
  end

  @doc """
  Returns the subset of projected nodes matching a given node_class.

  Useful in tests and inspection:

      {:ok, nodes} = EMotion.Projection.OPCUA.project(model)
      EMotion.Projection.OPCUA.filter(nodes, :method)
  """
  @spec filter([NodeSpec.t()], NodeSpec.node_class()) :: [NodeSpec.t()]
  def filter(nodes, class) do
    Enum.filter(nodes, & &1.node_class == class)
  end

  @doc "Find a node by its node_id string."
  @spec find([ NodeSpec.t()], String.t()) :: NodeSpec.t() | nil
  def find(nodes, node_id) do
    Enum.find(nodes, & &1.node_id == node_id)
  end
end
