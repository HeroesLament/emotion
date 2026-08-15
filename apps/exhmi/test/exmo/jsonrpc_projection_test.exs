defmodule ExMo.Projection.JSONRPCTest do
  @moduledoc """
  The node surface a JSON-RPC client browses, and the unit contract underneath
  it.

  The projection is pure, so all of this runs with no socket, no server, and no
  drive — which is the point of putting it here rather than testing it through
  a transport later.
  """

  use ExUnit.Case, async: true

  alias ExMo.InformationModel
  alias ExMo.Projection.JSONRPC
  alias ExMo.Projection.JSONRPC.TypeMap
  alias ExMo.Schema.{Enum, FromAxis, Registry}

  setup_all do
    {:ok, model} = InformationModel.compiled_model()
    {:ok, table} = JSONRPC.project(model)
    {:ok, model: model, table: table}
  end

  describe "the node table" do
    test "every node is reachable from the root", %{table: table} do
      reachable = walk_from(table, table.root, MapSet.new())
      declared = table.nodes |> Map.keys() |> MapSet.new()

      # An orphan is a node no client can ever browse to, which makes it
      # invisible in exactly the way that is hardest to notice.
      assert MapSet.equal?(reachable, declared),
             "unreachable: #{inspect(MapSet.difference(declared, reachable))}"
    end

    test "every child names a node that exists", %{table: table} do
      for {id, node} <- table.nodes, child <- node.children do
        assert Map.has_key?(table.nodes, child),
               "#{id} claims a child #{child} that is not in the table"
      end
    end

    test "every non-root node names its parent", %{table: table} do
      for {id, node} <- table.nodes, id != table.root do
        assert node.parent != nil, "#{id} has no parent"
        assert Map.has_key?(table.nodes, node.parent)
      end
    end

    test "node ids are dotted paths, not opaque handles", %{table: table} do
      # A client should be able to read one in a log and type it into a console.
      assert Map.has_key?(table.nodes, "axes.j1.position")
    end

    test "browse returns direct children in declaration order", %{table: table} do
      names = table |> JSONRPC.children("axes") |> Elixir.Enum.map(& &1.name)

      assert names == ~w(J1 J2 J3 J4 J5 J6)
    end
  end

  describe "the axes fragment" do
    test "the arm is in the model at all", %{table: table} do
      # FromAxis existed for months without Registry ever calling it, so the
      # axes were absent from every projection. This is the regression test for
      # that having been fixed.
      assert Map.has_key?(table.nodes, "axes")
      assert length(JSONRPC.children(table, "axes")) == 6
    end

    test "each axis carries the standard property set", %{table: table} do
      names = table |> JSONRPC.children("axes.j1") |> Elixir.Enum.map(& &1.name)

      assert "Position" in names
      assert "TargetPosition" in names
      assert "Velocity" in names
      # State is the neutral node every interface has; PdsState is the CiA 402
      # detail beside it, and the arm axes are CiA 402.
      assert "State" in names
      assert "PdsState" in names
      assert "FaultCode" in names
      # rotary
      assert "Direction" in names
      refute "AtHome" in names
    end

    test "position is readable and observable but not writable", %{table: table} do
      pos = table.nodes["axes.j1.position"]

      assert pos.readable
      assert pos.observable
      refute pos.writable
    end

    test "the target is writable, and is not a stream", %{table: table} do
      target = table.nodes["axes.j1.target_position"]

      assert target.writable
      refute target.observable
    end
  end

  describe "SI contract" do
    test "rotary axes report radians on the wire", %{table: table} do
      assert table.nodes["axes.j1.position"].unit == "rad"
      assert table.nodes["axes.j1.velocity"].unit == "rad/s"
    end

    test "linear axes report metres" do
      object = FromAxis.to_object(%{id: "axis.z", name: "Z", type: :linear})
      position = Elixir.Enum.find(object.children, &(&1.name == "Position"))

      assert position.unit == "m"
    end

    test "degrees are a display hint and never the wire unit", %{table: table} do
      pos = table.nodes["axes.j1.position"]

      # Both facts, held apart on purpose: the value is radians, and a human
      # should see degrees. Collapsing these is how a 57x error ships.
      assert pos.unit == "rad"
      assert pos.display_unit == :degrees
    end

    test "an axis with no display preference simply has none" do
      object = FromAxis.to_object(%{id: "axis.q", name: "Q", type: :rotary})
      position = Elixir.Enum.find(object.children, &(&1.name == "Position"))

      assert position.unit == "rad"
      refute Map.has_key?(position.meta, :display_unit)
    end

    test "limits travel with the axis, in SI", %{table: table} do
      assert {min, max} = table.nodes["axes.j1"].meta.limits
      assert min < 0 and max > 0
      # Radians. A ±3.05 rad limit is ±175°; the same numbers read as degrees
      # would be a joint with three degrees of travel.
      assert abs(max) < 7.0
    end

    test "an unknown axis type is rejected rather than defaulted" do
      assert_raise ArgumentError, ~r/unknown axis type/, fn ->
        FromAxis.to_object(%{id: "axis.x", name: "X", type: :helical})
      end
    end
  end

  describe "types become JSON Schema" do
    test "primitives map to the obvious things" do
      assert TypeMap.to_json_schema(:boolean) == %{"type" => "boolean"}
      assert TypeMap.to_json_schema(:string) == %{"type" => "string"}
      assert TypeMap.to_json_schema(:double) == %{"type" => "number"}
    end

    test "integer bounds are stated, not implied" do
      schema = TypeMap.to_json_schema(:uint16)

      assert schema["type"] == "integer"
      assert schema["minimum"] == 0
      assert schema["maximum"] == 65_535
    end

    test "an enum becomes a constrained string" do
      enum = %Enum{id: "t", name: "T", values: ~w(idle running fault)}
      schema = TypeMap.to_json_schema({:enum, enum})

      assert schema["type"] == "string"
      assert schema["enum"] == ~w(idle running fault)
    end

    test "a named reference resolves through the model registry", %{model: model} do
      schema = TypeMap.to_json_schema({:ref, "type.behavior_phase"}, model.types)

      assert schema["type"] == "string"
      assert "idle" in schema["enum"]
    end

    test "an unresolved reference raises rather than validating everything" do
      # `%{}` as a fallback would accept any value and hide the modelling bug
      # until something wrote nonsense to a real axis.
      assert_raise ArgumentError, ~r/unresolved type reference/, fn ->
        TypeMap.to_json_schema({:ref, "type.nope"}, %{})
      end
    end

    test "every property in the model has a usable schema", %{table: table} do
      for node <- JSONRPC.filter(table, :property) do
        assert is_map(node.schema), "#{node.node_id} has no schema"
        assert Map.has_key?(node.schema, "type"), "#{node.node_id} schema has no type"
      end
    end
  end

  describe "subscription surface" do
    test "observable properties are exactly what a client may subscribe to", %{table: table} do
      observable = JSONRPC.observable(table)

      assert Elixir.Enum.all?(observable, &(&1.class == :property))
      assert Elixir.Enum.all?(observable, & &1.observable)
      assert "axes.j1.position" in Elixir.Enum.map(observable, & &1.node_id)
    end

    test "a write-only target is not offered as a stream", %{table: table} do
      ids = JSONRPC.observable(table) |> Elixir.Enum.map(& &1.node_id)

      refute "axes.j1.target_position" in ids
    end
  end

  describe "registry" do
    test "the axis specs are inspectable without building a model" do
      # Whoever wires drives to the model needs the specs, and should not have
      # to compile and walk a model to get at them.
      assert length(Registry.arm_axes()) == 6
      assert Elixir.Enum.all?(Registry.arm_axes(), &(&1.type == :rotary))
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp walk_from(table, id, seen) do
    if MapSet.member?(seen, id) do
      seen
    else
      seen = MapSet.put(seen, id)
      node = Map.fetch!(table.nodes, id)
      Elixir.Enum.reduce(node.children, seen, &walk_from(table, &1, &2))
    end
  end

  describe "grants" do
    setup do
      {:ok, model} = ExMo.InformationModel.compiled_model()
      {:ok, table} = ExMo.Projection.JSONRPC.project(model)
      %{table: table}
    end

    test "every property carries the grant needed to read it", %{table: table} do
      for node <- ExMo.Projection.JSONRPC.filter(table, :property) do
        assert node.read_grant, "#{node.node_id} declares no read grant"
        assert ExAuth.Grant.known?(node.read_grant),
               "#{node.node_id} declares unknown read grant #{inspect(node.read_grant)}"
      end
    end

    test "every writable property names the grant needed to write it", %{table: table} do
      # Elixir.Enum, not Enum: this module aliases ExMo.Schema.Enum.
      writable =
        table
        |> ExMo.Projection.JSONRPC.filter(:property)
        |> Elixir.Enum.filter(& &1.writable)

      # If this list is ever empty the test has stopped testing anything.
      assert writable != []

      for node <- writable do
        assert node.write_grant, "#{node.node_id} is writable but names no write grant"
        assert ExAuth.Grant.known?(node.write_grant),
               "#{node.node_id} declares unknown write grant #{inspect(node.write_grant)}"
      end
    end

    test "read-only properties do not name a write grant", %{table: table} do
      for node <- ExMo.Projection.JSONRPC.filter(table, :property), not node.writable do
        assert is_nil(node.write_grant),
               "#{node.node_id} is read-only but names write grant #{inspect(node.write_grant)}"
      end
    end

    test "commanding a joint requires a motion grant, not a configuration grant", %{table: table} do
      target = table.nodes["axes.j1.target_position"]

      assert target.writable
      assert target.write_grant == :write_setpoint
      assert target.write_grant in ExAuth.Grant.motion_grants()
    end

    test "an observer can read every property in the model", %{table: table} do
      observer = ExAuth.Role.grants(:observer)

      for node <- ExMo.Projection.JSONRPC.filter(table, :property) do
        assert node.read_grant in observer,
               "#{node.node_id} needs #{inspect(node.read_grant)}, which an observer lacks"
      end
    end

    test "an observer can write nothing in the model", %{table: table} do
      observer = ExAuth.Role.grants(:observer)

      for node <- ExMo.Projection.JSONRPC.filter(table, :property), node.writable do
        refute node.write_grant in observer,
               "an observer could write #{node.node_id}"
      end
    end
  end

  describe "failing closed" do
    test "a writable property with no write grant is refused, not defaulted" do
      # The whole point of the design: forgetting the annotation must break the
      # build, because the alternatives are an open door or a silently
      # unwritable property.
      model = %ExMo.Schema.Model{
        id: "test",
        root: %ExMo.Schema.Object{
          id: "root",
          name: "Root",
          children: [
            %ExMo.Schema.Property{
              id: "root.oops",
              name: "Oops",
              type: :double,
              writable: true
            }
          ]
        },
        types: %{}
      }

      assert {:error, {:writable_without_grant, ["root.oops"]}} =
               ExMo.Projection.JSONRPC.project(model)
    end

    test "the same property is fine once the grant is declared" do
      model = %ExMo.Schema.Model{
        id: "test",
        root: %ExMo.Schema.Object{
          id: "root",
          name: "Root",
          children: [
            %ExMo.Schema.Property{
              id: "root.fine",
              name: "Fine",
              type: :double,
              writable: true,
              write_grant: :write_configuration
            }
          ]
        },
        types: %{}
      }

      assert {:ok, table} = ExMo.Projection.JSONRPC.project(model)
      assert table.nodes["root.fine"].write_grant == :write_configuration
    end
  end
end
