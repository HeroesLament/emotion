defmodule ExAuth.Bootstrap do
  @moduledoc """
  First-boot provisioning, synchronously, at startup.

  Migrations used to happen here too. They moved to `ExStore.Migrator` when the
  database stopped being the credential store and became the controller's, and
  the split is the honest one: bringing a schema up is a fact about every app
  that stores something, while inventing an administrator is a fact about this
  one.

  Ordering still holds without a code dependency. `exauth` depends on `exstore`,
  so its application starts second, and the migrator has already blocked its own
  supervisor until the schema was current before this process exists.

  Returns `:ignore`, so this leaves no process behind once it has run.
  """

  use GenServer, restart: :transient

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    if Application.get_env(:exauth, :auto_provision, true), do: provision()
    :ignore
  end

  defp provision do
    case ExAuth.Provision.ensure_administrator() do
      {:created, _username, _password} -> :ok
      :exists -> :ok
      {:error, reason} -> Logger.error("could not provision administrator: #{inspect(reason)}")
    end
  end
end
