defmodule ExOpcUA.Server do
  @moduledoc """
  OPC UA server — public API and supervisor.

  ## Usage

      {:ok, _} = ExOpcUA.Server.start_link(
        port: 4840,
        node_manager: MyApp.NodeManager,
        application_uri: "urn:myapp:server",
        application_name: "My OPC UA Server"
      )

  ## Options

  - `:port` — TCP port to listen on (default: 4840)
  - `:node_manager` — module implementing `ExOpcUA.Server.NodeManager` behaviour (**required**)
  - `:application_uri` — server application URI (default: `"urn:ExOpcUA:Server"`)
  - `:application_name` — human-readable name (default: `"ExOpcUA Server"`)
  - `:hostname` — hostname for endpoint URL (default: system hostname)
  - `:security` — list of security modes to advertise (default: `[:none]`)
  """

  use Supervisor

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop(reason \\ :normal) do
    Supervisor.stop(__MODULE__, reason)
  end

  def port do
    ExOpcUA.Server.Listener.port()
  end

  # ── Supervisor init ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    port         = Keyword.get(opts, :port, 4840)
    node_manager = Keyword.fetch!(opts, :node_manager)

    # Call init_space if implemented
    if function_exported?(node_manager, :init_space, 0) do
      case node_manager.init_space() do
        :ok -> :ok
        {:error, reason} -> raise "NodeManager.init_space/0 failed: #{inspect(reason)}"
      end
    end

    hostname = Keyword.get(opts, :hostname, detect_hostname())
    server_config = %{
      port:             port,
      hostname:         hostname,
      application_uri:  Keyword.get(opts, :application_uri,  "urn:ExOpcUA:Server"),
      application_name: Keyword.get(opts, :application_name, "ExOpcUA Server"),
      product_uri:      Keyword.get(opts, :product_uri,      "urn:ex_opcua"),
      security:         Keyword.get(opts, :security,         [:none])
    }

    connection_sup_name = __MODULE__.ConnectionSupervisor

    children = [
      {DynamicSupervisor,
        name:     connection_sup_name,
        strategy: :one_for_one
      },
      {ExOpcUA.Server.Listener,
        port:           port,
        node_manager:   node_manager,
        server_config:  server_config,
        connection_sup: connection_sup_name
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp detect_hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "localhost"
    end
  end
end
