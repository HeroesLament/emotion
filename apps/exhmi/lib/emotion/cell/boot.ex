defmodule EMotion.Cell.Boot do
  @moduledoc """
  Reads the commissioned robot, once, before anything projects the model.

  The same shape as `ExStore.Migrator` and for the same reason: it runs in
  `init/1` rather than in a `Task`, so it blocks its supervisor and nothing
  further down the tree can start against a controller that does not yet know
  how many axes it has. A `Task` would be a race whose outcome is an address
  space that is sometimes right.

  Returns `:ignore`, so this leaves no process behind once it has run.
  """

  use GenServer, restart: :transient

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    if Application.get_env(:exhmi, :auto_load_robot, true), do: EMotion.Cell.Loaded.install()
    :ignore
  end
end
