defmodule ExProto.EchoSource do
  @moduledoc """
  A source that reports every command to a pid instead of running one.

  `ExProto.Source.Static` records into an Agent, which is right for asking
  "did this arrive" after the fact. A watchdog test needs the opposite: to
  watch commands arrive in order, in real time, and to assert on what did NOT
  arrive after a deadline. Sending them as messages makes both an
  `assert_receive` rather than a sleep.
  """

  @behaviour ExProto.Source

  @impl true
  def read(_node_id, _pid), do: {:error, :unknown_node}

  @impl true
  def write(_node_id, _value, _pid), do: {:error, :not_writable}

  @impl true
  def call(node_id, args, pid) do
    send(pid, {:commanded, node_id, args})
    :ok
  end
end
