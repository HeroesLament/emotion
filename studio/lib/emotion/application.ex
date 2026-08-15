defmodule EMotion.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Workbench discovery is NOT done here, and that is the whole reason the
    # studio shows a splash within half a second instead of two.
    #
    # It walks every loaded application's module list and takes ~1.5s on this
    # machine. Run from `start/2` it blocks before the supervision tree exists,
    # so no window — not even the splash whose job is to cover exactly this —
    # can be on screen until it finishes. It is already a Boot step, so it was
    # also being done twice.
    #
    # It is safe to leave to Boot: the splash view does not read the registry,
    # and the workspace is only shown once Boot reports every step complete.
    # `Registry.all/0` still refreshes on demand if something reads it early,
    # which is a stall rather than an error.

    children = [
      EMotion.Job,
      # Opened onto a demo arm rather than an empty void: a blank 3D viewport
      # gives a new user no way to tell "working, nothing loaded" from
      # "broken". Goes away when there is a start page and a file format.
      {EMotion.Cell.Server, cell: EMotion.Startup.demo_cell()},

      # Present but not connected. A link process that exists from boot means
      # connecting is a call rather than a process start, and disconnecting
      # leaves something to ask the status of; nothing here dials anything.
      EMotion.Link,

      {EMotion.Boot, steps: EMotion.Startup.steps()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EMotion.Supervisor)
  end
end
