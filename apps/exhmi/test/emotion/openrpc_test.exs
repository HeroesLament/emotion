defmodule EMotion.Projection.JSONRPC.OpenRPCTest do
  @moduledoc """
  The generated OpenRPC document.

  Structural assertions live here; the full meta-schema validation happens in
  the mix task's CI check, because pulling a JSON Schema validator into the app
  to check a build artifact would be the tail wagging the dog.

  What matters most below is not that the document is well-formed — a generator
  tends to produce well-formed output — but that the properties the protocol
  depends on survive generation: that every `$ref` resolves, that error codes
  stay in the JSON-RPC server range and stay unique, and that the output is
  byte-stable so `--check` means something.
  """

  use ExUnit.Case, async: true

  alias EMotion.InformationModel
  alias EMotion.Projection.JSONRPC.OpenRPC

  setup_all do
    {:ok, model} = InformationModel.compiled_model()
    {:ok, doc} = OpenRPC.document(model)
    {:ok, model: model, doc: doc}
  end

  describe "document shape" do
    test "declares a version the tooling actually accepts", %{doc: doc} do
      # The published meta-schema enumerates valid values and tops out at
      # 1.3.2. A 1.4.x document is rejected regardless of what the spec site
      # says, which is a lesson learned the hard way.
      assert doc["openrpc"] == "1.3.2"
    end

    test "carries the three required top-level members", %{doc: doc} do
      assert is_map(doc["info"])
      assert is_list(doc["methods"])
      assert doc["openrpc"]
    end

    test "says it is generated, in the document itself", %{doc: doc} do
      # Whoever opens this file next should learn not to edit it from the file,
      # not from a commit message they will never read.
      assert doc["info"]["description"] =~ "GENERATED FILE"
      assert doc["info"]["description"] =~ "mix exmo.openrpc"
    end

    test "the protocol version is a date and is exposed", %{doc: doc} do
      assert doc["x-protocolVersion"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert doc["x-protocolVersion"] == OpenRPC.protocol_version()
    end
  end

  describe "methods" do
    test "the surface is the node surface and nothing else", %{doc: doc} do
      names = doc["methods"] |> Enum.map(& &1["name"]) |> Enum.sort()

      assert names == [
               "initialize",
               "nodes/browse",
               "nodes/call",
               "nodes/read",
               "nodes/subscribe",
               "nodes/unsubscribe",
               "nodes/write",
               "notifications/initialized",
               "notifications/nodes/changed"
             ]
    end

    test "method names are unique", %{doc: doc} do
      names = Enum.map(doc["methods"], & &1["name"])
      assert length(names) == length(Enum.uniq(names))
    end

    test "every method declares params and a result", %{doc: doc} do
      for method <- doc["methods"] do
        assert is_list(method["params"]), "#{method["name"]} has no params list"
        assert is_map(method["result"]), "#{method["name"]} has no result"
        assert method["paramStructure"] == "by-name"
      end
    end

    test "notifications are marked and have a null result", %{doc: doc} do
      notifications = Enum.filter(doc["methods"], & &1["x-notification"])

      assert length(notifications) == 2

      for n <- notifications do
        # OpenRPC has no first-class notion of a server-initiated message, so
        # the direction lives in an extension. Generated clients that ignore it
        # will wait forever for a response that is never coming.
        assert n["x-messageDirection"] in ["clientToServer", "serverToClient"]
        assert n["result"]["schema"] == %{"type" => "null"}
      end
    end

    test "read and write are batched", %{doc: doc} do
      read = find_method(doc, "nodes/read")
      write = find_method(doc, "nodes/write")

      assert param(read, "nodeIds")["schema"]["type"] == "array"
      assert param(write, "writes")["schema"]["type"] == "array"
    end

    test "subscribe documents conflation as a property, not a hint", %{doc: doc} do
      # If this ever stops being stated, someone will optimise it into a
      # buffer and a slow client will fall permanently behind.
      description = find_method(doc, "nodes/subscribe")["description"]

      assert description =~ "conflated"
      assert description =~ "never queued"
    end
  end

  describe "references" do
    test "every $ref resolves", %{doc: doc} do
      refs = collect_refs(doc)
      assert refs != [], "expected the document to use refs at all"

      for ref <- refs do
        assert resolve(doc, ref) != nil, "dangling $ref: #{ref}"
      end
    end

    test "every declared schema is referenced by something", %{doc: doc} do
      refs = doc |> collect_refs() |> MapSet.new()

      for name <- Map.keys(doc["components"]["schemas"]) do
        assert MapSet.member?(refs, "#/components/schemas/#{name}"),
               "schema #{name} is declared but never referenced"
      end
    end

    test "every declared error is reachable, as a method error or a node error",
         %{doc: doc} do
      # Not every code is a method error. Batched reads and writes report
      # per-node failures inside the result, so some codes can only ever appear
      # in a NodeError. Both are legitimate; being reachable by neither is not.
      refs = doc |> collect_refs() |> MapSet.new()
      node_errors = MapSet.new(doc["x-nodeErrors"]["codes"])

      for name <- Map.keys(doc["components"]["errors"]) do
        assert MapSet.member?(refs, "#/components/errors/#{name}") or
                 MapSet.member?(node_errors, name),
               "error #{name} is declared but nothing can ever produce it"
      end
    end

    test "every per-node error code is actually declared", %{doc: doc} do
      declared = Map.keys(doc["components"]["errors"])

      for name <- doc["x-nodeErrors"]["codes"] do
        assert name in declared, "#{name} is listed as a node error but not declared"
      end
    end
  end

  describe "error codes" do
    test "are unique", %{doc: doc} do
      codes = doc["components"]["errors"] |> Map.values() |> Enum.map(& &1["code"])
      assert length(codes) == length(Enum.uniq(codes))
    end

    test "stay inside the JSON-RPC server-defined range", %{doc: doc} do
      for {name, error} <- doc["components"]["errors"] do
        assert error["code"] >= -32_099 and error["code"] <= -32_000,
               "#{name} code #{error["code"]} is outside -32099..-32000"
      end
    end
  end

  describe "the model snapshot" do
    test "carries the axes", %{doc: doc} do
      nodes = doc["x-nodes"]["nodes"]

      assert Map.has_key?(nodes, "axes.j1.position")
      assert nodes["axes.j1.position"]["class"] == "property"
    end

    test "states SI units and holds the display hint apart", %{doc: doc} do
      position = doc["x-nodes"]["nodes"]["axes.j1.position"]

      assert position["unit"] == "rad"
      assert position["displayUnit"] == "degrees"
    end

    test "says it is informative rather than authoritative", %{doc: doc} do
      # A stale node list that looks authoritative is worse than no node list,
      # because a client will trust it instead of browsing.
      assert doc["x-nodes"]["description"] =~ "browse the live controller"
    end

    test "every property snapshot carries a usable schema", %{doc: doc} do
      for {id, node} <- doc["x-nodes"]["nodes"], node["class"] == "property" do
        assert is_map(node["schema"]), "#{id} has no schema"
        assert node["schema"]["type"], "#{id} schema has no type"
      end
    end
  end

  describe "encoding" do
    test "is valid JSON", %{doc: doc} do
      json = OpenRPC.encode(doc)
      assert {:ok, decoded} = decode(json)
      assert decoded["openrpc"] == "1.3.2"
    end

    test "is byte-stable across regeneration", %{model: model} do
      # `--check` in CI is only meaningful if an unchanged model produces an
      # identical file. Map iteration order is not guaranteed, so the encoder
      # sorts keys; this is the test that keeps it doing so.
      {:ok, a} = OpenRPC.document(model)
      {:ok, b} = OpenRPC.document(model)

      assert OpenRPC.encode(a) == OpenRPC.encode(b)
    end

    test "ends with a newline", %{doc: doc} do
      assert String.ends_with?(OpenRPC.encode(doc), "\n")
    end

    test "round-trips the node snapshot", %{doc: doc} do
      {:ok, decoded} = doc |> OpenRPC.encode() |> decode()

      assert decoded["x-nodes"]["nodes"]["axes.j1.position"]["unit"] == "rad"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp decode(json) do
    {decoded, _acc, ""} = :json.decode(json, :ok, %{})
    {:ok, decoded}
  rescue
    e -> {:error, e}
  end

  defp find_method(doc, name), do: Enum.find(doc["methods"], &(&1["name"] == name))

  defp param(method, name), do: Enum.find(method["params"], &(&1["name"] == name))

  defp collect_refs(term, acc \\ [])
  defp collect_refs(%{"$ref" => ref} = map, acc) do
    Enum.reduce(Map.delete(map, "$ref"), [ref | acc], &collect_refs(elem(&1, 1), &2))
  end

  defp collect_refs(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {_k, v}, a -> collect_refs(v, a) end)
  end

  defp collect_refs(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_refs/2)
  end

  defp collect_refs(_other, acc), do: acc

  defp resolve(doc, "#/" <> path) do
    path |> String.split("/") |> Enum.reduce(doc, fn
      _seg, nil -> nil
      seg, node when is_map(node) -> Map.get(node, seg)
      _seg, _ -> nil
    end)
  end
end
