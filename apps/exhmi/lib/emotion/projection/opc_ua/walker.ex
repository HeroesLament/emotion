defmodule EMotion.Projection.OPCUA.Walker do
  @moduledoc """
  Recursively walks an E-Motion Schema tree and emits a flat list of
  EMotion.Projection.OPCUA.NodeSpec structs.

  The first call starts from the root Object, parented under the OPC-UA
  Objects folder (ns=0;i=85).
  """

  alias EMotion.Schema.{Object, Property, Method, Event}
  alias EMotion.Projection.OPCUA.{NodeSpec, NodeId, TypeMap}

  @doc """
  Walk the model root and return a flat list of NodeSpecs.

  Also emits the root E-Motion Object as a child of the OPC-UA Objects folder.
  """
  @spec walk(EMotion.Schema.Model.t()) :: [NodeSpec.t()]
  def walk(%EMotion.Schema.Model{root: root, types: types}) do
    walk_object(root, NodeId.objects_folder_id(), :organizes, types)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp walk_object(%Object{path: path, children: children} = obj, parent_id, ref_type, types) do
    node_id = NodeId.path_to_node_id(path)

    self_spec = %NodeSpec{
      node_id:        node_id,
      browse_name:    obj.name,
      display_name:   obj.name,
      description:    obj.description,
      node_class:     :object,
      parent_node_id: parent_id,
      reference_type: ref_type
    }

    child_specs =
      Enum.flat_map(children, fn child ->
        child_ref = child_reference_type(child)
        walk_node(child, node_id, child_ref, types)
      end)

    [self_spec | child_specs]
  end

  defp walk_node(%Object{}   = obj,  parent_id, ref_type, types), do: walk_object(obj, parent_id, ref_type, types)
  defp walk_node(%Property{} = prop, parent_id, ref_type, types), do: [walk_property(prop, parent_id, ref_type, types)]
  defp walk_node(%Method{}   = meth, parent_id, ref_type, _types), do: [walk_method(meth, parent_id, ref_type)]
  defp walk_node(%Event{}    = _evt, _parent_id, _ref_type, _types), do: []  # deferred

  defp walk_property(%Property{path: path} = prop, parent_id, ref_type, types) do
    %NodeSpec{
      node_id:        NodeId.path_to_node_id(path),
      browse_name:    prop.name,
      display_name:   prop.name,
      description:    prop.description,
      node_class:     :variable,
      parent_node_id: parent_id,
      reference_type: ref_type,
      data_type:      TypeMap.to_ua_type(prop.type, types),
      value:          prop.default,
      access_level:   access_level(prop)
    }
  end

  defp walk_method(%Method{path: path} = meth, parent_id, ref_type) do
    %NodeSpec{
      node_id:         NodeId.path_to_node_id(path),
      browse_name:     meth.name,
      display_name:    meth.name,
      description:     meth.description,
      node_class:      :method,
      parent_node_id:  parent_id,
      reference_type:  ref_type,
      executable:      true,
      user_executable: true,
      input_args:      Enum.map(meth.input_args,  &arg_spec/1),
      output_args:     Enum.map(meth.output_args, &result_spec/1)
    }
  end

  # Objects always use :has_component; the root->Objects link uses :organizes.
  # Children that are Objects get :organizes; Properties and Methods get :has_component.
  defp child_reference_type(%Object{}),   do: :organizes
  defp child_reference_type(%Property{}), do: :has_component
  defp child_reference_type(%Method{}),   do: :has_component
  defp child_reference_type(%Event{}),    do: :has_component

  defp access_level(%Property{readable: true, writable: true}),   do: :read_write
  defp access_level(%Property{readable: true,  writable: false}),  do: :read_only
  defp access_level(%Property{readable: false, writable: true}),   do: :write_only
  defp access_level(_),                                             do: :read_only

  defp arg_spec(arg) do
    %{name: arg.name, type: arg.type, description: arg.description, required: arg.required}
  end

  defp result_spec(rf) do
    %{name: rf.name, type: rf.type, description: rf.description}
  end
end
