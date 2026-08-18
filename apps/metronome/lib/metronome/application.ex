defmodule Metronome.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Milestone 1 owns no long-lived processes yet — the USB session handle is
    # opened explicitly from IEx for the descriptor-readback oracle. The
    # streaming session GenServer (which will own the device handle, the
    # setpoint-window OUT stream, and the feedback IN loop) arrives in
    # milestone 2 and will be supervised here.
    children = []
    opts = [strategy: :one_for_one, name: Metronome.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
