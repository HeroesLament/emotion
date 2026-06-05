defmodule ExOpcUA do
  @moduledoc """
  Pure Elixir OPC UA client and server stack.

  ## Server

      {:ok, _} = ExOpcUA.Server.start_link(
        port: 4840,
        node_manager: MyApp.AddressSpace
      )

  ## Client

      {:ok, client} = ExOpcUA.Client.start_link(url: "opc.tcp://localhost:4840")
      {:ok, [dv]}   = ExOpcUA.Client.read(client, [ExOpcUA.NodeId.numeric(1, 1001)])
      :ok           = ExOpcUA.Client.write(client, node_id, ExOpcUA.Variant.double(3.14))

  ## Codec (direct binary access)

      bin = ExOpcUA.Codec.Primitives.encode_double(1.234)
      bin = ExOpcUA.Codec.Services.encode(:read_req, %ReadRequest{...})
  """

  defdelegate encode_node_id(node_id),  to: ExOpcUA.Codec.Types
  defdelegate decode_node_id(binary),   to: ExOpcUA.Codec.Types

  # ── Convenience constructors (avoid alias clutter in user code) ───────────────

  defmodule NodeId do
    defdelegate numeric(ns, id), to: ExOpcUA.Codec.Types.NodeId
    defdelegate string(ns, id),  to: ExOpcUA.Codec.Types.NodeId
    defdelegate guid(ns, id),    to: ExOpcUA.Codec.Types.NodeId
    defdelegate ns0(id),         to: ExOpcUA.Codec.Types.NodeId
  end

  defmodule Variant do
    alias ExOpcUA.Codec.Types

    def double(v),  do: Types.double_variant(v)
    def string(v),  do: Types.string_variant(v)
    def uint32(v),  do: Types.uint32_variant(v)
    def boolean(v), do: %Types.Variant{type: :boolean, value: v}
    def int32(v),   do: %Types.Variant{type: :int32,   value: v}
    def float(v),   do: %Types.Variant{type: :float,   value: v}

    def array(type, values),
      do: %Types.Variant{type: type, value: values}
  end
end
