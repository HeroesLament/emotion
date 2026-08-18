defmodule ExHMI.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:exhmi, :port, 4840)

    children = [
      # First, and blocking: the Information Model's axis nodes are derived
      # from the loaded chain, so nothing that projects the model may start
      # before the controller knows which robot it is.
      ExMo.Cell.Boot,
      ExHMI.AddressSpace,
      {ExOpcUA.Server, [
        port: port,
        node_manager: ExHMI.Transport.OpcUA,
        application_name: "ExMo Robot Controller"
      ]}
    ]

    opts = [strategy: :one_for_one, name: ExHMI.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
