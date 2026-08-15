defmodule ExProto.Router do
  @moduledoc """
  The HTTP surface: the WebSocket upgrade, and the few things a client wants
  before it has a session.

  Bulk transfer — program source, logs, motion traces — belongs here too when
  it exists, deliberately off the live link so that downloading a log cannot
  compete with telemetry for the same connection.
  """

  use Plug.Router

  alias ExMo.Projection.JSONRPC.OpenRPC
  alias ExProto.Socket

  plug(:match)
  # Hands the endpoint's options to each route, so the node table and the value
  # source reach a connection without being global state.
  plug(:dispatch, builder_opts())

  # The live link.
  get "/rpc" do
    conn
    |> WebSockAdapter.upgrade(
      Socket,
      %{table: opts.table, source: opts.source},
      timeout: 60_000
    )
    |> halt()
  end

  # Unauthenticated on purpose: it exists so a supervisor, a load balancer, or
  # an operator with curl can tell whether the controller is up without holding
  # a credential, and it says nothing a port scan could not already infer.
  get "/health" do
    send_json(conn, 200, %{
      "status" => "ok",
      "protocolVersion" => OpenRPC.protocol_version()
    })
  end

  # The contract, served by the thing it describes. A client that fetches this
  # from the controller it is talking to cannot be reading a document for
  # different firmware, which is exactly the failure mode of shipping the file
  # separately from the device.
  get "/openrpc.json" do
    case document() do
      {:ok, json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, json)

      {:error, reason} ->
        send_json(conn, 500, %{"error" => inspect(reason)})
    end
  end

  # The certificate fingerprint, so an operator can compare what a client is
  # about to pin against what the controller believes it is presenting.
  #
  # Served over the very connection whose identity is in question, which proves
  # nothing by itself — that is what verifying out of band is for — but it makes
  # the comparison possible at all without shell access to the device.
  get "/fingerprint" do
    case opts.fingerprint do
      nil -> send_json(conn, 404, %{"error" => "not serving TLS"})
      print -> send_json(conn, 200, %{"fingerprint" => print})
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body |> :json.encode() |> IO.iodata_to_binary())
  end

  defp document do
    with {:ok, model} <- ExMo.InformationModel.compiled_model(),
         {:ok, doc} <- OpenRPC.document(model) do
      {:ok, OpenRPC.encode(doc)}
    end
  end
end
