defmodule EMotion.InformationModelTest do
  use ExUnit.Case, async: true

  alias EMotion.InformationModel
  alias EMotion.Projection.OPCUA

  # ── Compiler ────────────────────────────────────────────────────────────────

  describe "compiled_model/0" do
    test "compiles successfully" do
      assert {:ok, model} = InformationModel.compiled_model()
      assert model.id == "emotion"
    end

    test "root object has correct name" do
      {:ok, model} = InformationModel.compiled_model()
      assert model.root.name == "EMotion"
    end

    test "root path is normalized" do
      {:ok, model} = InformationModel.compiled_model()
      assert model.root.path == ["EMotion"]
    end

    test "types registry contains behavior_phase enum" do
      {:ok, model} = InformationModel.compiled_model()
      assert %EMotion.Schema.Enum{} = model.types["type.behavior_phase"]
      assert "fault" in model.types["type.behavior_phase"].values
      assert "complete" in model.types["type.behavior_phase"].values
    end

    test "child paths are normalized recursively" do
      {:ok, model} = InformationModel.compiled_model()
      behaviors = find_child(model.root, "Behaviors")
      assert behaviors.path == ["EMotion", "Behaviors"]

      catalog = find_child(behaviors, "Catalog")
      assert catalog.path == ["EMotion", "Behaviors", "Catalog"]
    end
  end

  # ── Behavior -> schema fragment ─────────────────────────────────────────────

  describe "RemovePreviousPrint behavior fragment" do
    setup do
      {:ok, model} = InformationModel.compiled_model()
      {:ok, model: model}
    end

    test "catalog object exists", %{model: model} do
      assert find_deep(model.root, ["Behaviors", "Catalog", "RemovePreviousPrint"])
    end

    test "Invoke method exists under catalog entry", %{model: model} do
      rpp = find_deep(model.root, ["Behaviors", "Catalog", "RemovePreviousPrint"])
      invoke = find_child(rpp, "Invoke")
      assert invoke
      assert %EMotion.Schema.Method{} = invoke
    end

    test "Invoke method has input args", %{model: model} do
      rpp    = find_deep(model.root, ["Behaviors", "Catalog", "RemovePreviousPrint"])
      invoke = find_child(rpp, "Invoke")
      names  = Enum.map(invoke.input_args, & &1.name)
      assert "printer_id"  in names
      assert "unload_lane" in names
    end

    test "Invoke method has output args", %{model: model} do
      rpp    = find_deep(model.root, ["Behaviors", "Catalog", "RemovePreviousPrint"])
      invoke = find_child(rpp, "Invoke")
      names  = Enum.map(invoke.output_args, & &1.name)
      assert "accepted"    in names
      assert "job_id"      in names
      assert "result_code" in names
    end

    test "ActiveBehavior has runtime property nodes", %{model: model} do
      active = find_deep(model.root, ["Behaviors", "Runtime", "ActiveBehavior"])
      prop_names = Enum.map(active.children, & &1.name)
      assert "Phase"       in prop_names
      assert "Progress"    in prop_names
      assert "FaultCode"   in prop_names
      assert "Id"          in prop_names
      assert "Name"        in prop_names
      assert "JobId"       in prop_names
      assert "PlateGripped" in prop_names
    end
  end

  # ── Printers and State ───────────────────────────────────────────────────────

  describe "Printers and State fragments" do
    setup do
      {:ok, model} = InformationModel.compiled_model()
      {:ok, model: model}
    end

    test "K1C_01 object exists", %{model: model} do
      k1c = find_deep(model.root, ["Printers", "K1C_01"])
      assert k1c
    end

    test "K1C_01 has expected properties", %{model: model} do
      k1c   = find_deep(model.root, ["Printers", "K1C_01"])
      names = Enum.map(k1c.children, & &1.name)
      assert "ReadyForUnload"    in names
      assert "DoorState"         in names
      assert "BuildPlatePresent" in names
      assert "UnloadLaneClear"   in names
    end

    test "State has ControllerMode and FaultPresent", %{model: model} do
      state = find_child(model.root, "State")
      names = Enum.map(state.children, & &1.name)
      assert "ControllerMode" in names
      assert "FaultPresent"   in names
    end
  end

  # ── OPC-UA projection ────────────────────────────────────────────────────────

  describe "OPCUA.project/1" do
    setup do
      {:ok, model} = InformationModel.compiled_model()
      {:ok, nodes} = OPCUA.project(model)
      {:ok, nodes: nodes}
    end

    test "produces a non-empty node list", %{nodes: nodes} do
      assert length(nodes) > 0
    end

    test "E-Motion root object is present", %{nodes: nodes} do
      node = OPCUA.find(nodes, "ns=1;s=EMotion")
      assert node
      assert node.node_class == :object
      assert node.browse_name == "EMotion"
      assert node.parent_node_id == "ns=0;i=85"
    end

    test "Invoke becomes a method node", %{nodes: nodes} do
      node = OPCUA.find(nodes, "ns=1;s=EMotion.Behaviors.Catalog.RemovePreviousPrint.Invoke")
      assert node
      assert node.node_class      == :method
      assert node.executable      == true
      assert node.user_executable == true
    end

    test "Invoke method carries input and output arg metadata", %{nodes: nodes} do
      node       = OPCUA.find(nodes, "ns=1;s=EMotion.Behaviors.Catalog.RemovePreviousPrint.Invoke")
      input_names  = Enum.map(node.input_args,  & &1.name)
      output_names = Enum.map(node.output_args, & &1.name)
      assert "printer_id" in input_names
      assert "accepted"   in output_names
    end

    test "Phase becomes a variable node", %{nodes: nodes} do
      node = OPCUA.find(nodes, "ns=1;s=EMotion.Behaviors.Runtime.ActiveBehavior.Phase")
      assert node
      assert node.node_class == :variable
      assert node.data_type  == :string   # enum ref projected as string phase 1
    end

    test "K1C_01.ReadyForUnload becomes a variable node", %{nodes: nodes} do
      node = OPCUA.find(nodes, "ns=1;s=EMotion.Printers.K1C_01.ReadyForUnload")
      assert node
      assert node.node_class == :variable
      assert node.data_type  == :boolean
    end

    test "State.FaultPresent is boolean variable", %{nodes: nodes} do
      node = OPCUA.find(nodes, "ns=1;s=EMotion.State.FaultPresent")
      assert node
      assert node.node_class == :variable
      assert node.data_type  == :boolean
    end

    test "object nodes have correct parent references", %{nodes: nodes} do
      behaviors = OPCUA.find(nodes, "ns=1;s=EMotion.Behaviors")
      assert behaviors.parent_node_id == "ns=1;s=EMotion"

      catalog = OPCUA.find(nodes, "ns=1;s=EMotion.Behaviors.Catalog")
      assert catalog.parent_node_id == "ns=1;s=EMotion.Behaviors"
    end

    test "all variable nodes have a data_type", %{nodes: nodes} do
      variables = OPCUA.filter(nodes, :variable)
      assert length(variables) > 0
      Enum.each(variables, fn v ->
        assert v.data_type != nil, "Variable #{v.node_id} has no data_type"
      end)
    end

    test "all method nodes have input_args and output_args lists", %{nodes: nodes} do
      methods = OPCUA.filter(nodes, :method)
      assert length(methods) > 0
      Enum.each(methods, fn m ->
        assert is_list(m.input_args),  "Method #{m.node_id} missing input_args"
        assert is_list(m.output_args), "Method #{m.node_id} missing output_args"
      end)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp find_child(%{children: children}, name) do
    Enum.find(children, & &1.name == name)
  end

  defp find_deep(node, []), do: node
  defp find_deep(node, [head | tail]) do
    case find_child(node, head) do
      nil   -> nil
      child -> find_deep(child, tail)
    end
  end
end
