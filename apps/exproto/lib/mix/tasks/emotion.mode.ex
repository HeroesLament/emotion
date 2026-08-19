defmodule Mix.Tasks.Emotion.Mode do
  @shortdoc "Turns a bench controller's mode selector"

  @moduledoc """
  Reads or turns the mode selector on a running bench controller.

      mix emotion.mode                      # where is it?
      mix emotion.mode auto                 # turn it
      mix emotion.mode manual --sname bench --port 4001

  ## Why this is not on the protocol, and why this task is not a hole in that

  `ExProto.Mode` reads a position rather than offering one, because a keyswitch
  that can be turned from another building is not a keyswitch. That stays true.

  What this replaces is the *ceremony*, not the interlock. Turning it already
  required a remote shell into the controller's own node — cookie, node name,
  `iex --remsh` — and every one of those is still required here, because this
  task does the same thing the same way. What it does not require is
  remembering that the server is named after its port.

  The distinction worth keeping: a client on the protocol could be anywhere and
  is authenticated as an account. Something with the node's cookie is on the
  machine, or has already been let into the room where the machine is.

  ## The two interlocks it makes visible

  Jogging is refused outside manual and programs are refused outside auto,
  which is not an inconsistency: teaching happens with somebody at the arm and
  running happens with somebody further away. Turning the key to auto releases
  any jog in progress and turning it away from auto stops a running program —
  `ExProto.Mode` does both, and this task inherits that rather than reimplementing
  it.
  """

  use Mix.Task

  @cookie :emotion
  @positions ~w(manual auto idle)

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _invalid} =
      OptionParser.parse(argv, strict: [sname: :string, port: :integer, host: :string])

    sname = Keyword.get(opts, :sname, "bench")
    port = Keyword.get(opts, :port, 4001)
    host = Keyword.get(opts, :host, hostname())
    node = :"#{sname}@#{host}"
    server = Module.concat(ExProto.Mode, "P#{port}")

    connect!(node)

    case rest do
      [] ->
        report(node, server)

      [position] when position in @positions ->
        turn(node, server, String.to_atom(position))

      [other] ->
        Mix.raise("mode must be one of #{Enum.join(@positions, ", ")}, got #{inspect(other)}")

      _many ->
        Mix.raise("one position at a time")
    end
  end

  defp report(node, server) do
    Mix.shell().info("#{node} selector: #{call!(node, server, :selected, [])}")
  end

  # Says what it was as well as what it is. "It is in auto" is not the useful
  # sentence when somebody is working out why a program would not start; "it was
  # in manual and is now in auto" is.
  defp turn(node, server, position) do
    was = call!(node, server, :selected, [])

    case :rpc.call(node, ExProto.Mode, :select, [position, server]) do
      :ok ->
        Mix.shell().info("#{node} selector: #{was} -> #{position}")
        note(position)

      {:badrpc, reason} ->
        Mix.raise("could not turn the selector: #{inspect(reason)}")

      other ->
        Mix.raise("controller refused: #{inspect(other)}")
    end
  end

  defp note(:auto), do: Mix.shell().info("jogging is now refused")
  defp note(:manual), do: Mix.shell().info("programs will now be refused")
  defp note(:idle), do: Mix.shell().info("both jogging and programs are now refused")

  defp call!(node, server, fun, args) do
    case :rpc.call(node, ExProto.Mode, fun, args ++ [server]) do
      {:badrpc, reason} ->
        Mix.raise("""
        Could not reach #{node}: #{inspect(reason)}

        Is the controller running with --sname? It prints the node name and the
        command to attach at boot:

            mix emotion.controller --sname bench
        """)

      value ->
        value
    end
  end

  defp connect!(node) do
    {:ok, _} = Node.start(:"emotion_mode_#{System.unique_integer([:positive])}", :shortnames)
    Node.set_cookie(@cookie)

    unless Node.connect(node) do
      Mix.raise("""
      Could not connect to #{node}.

      A controller started without --sname has no node to connect to, which is
      the normal state for one that nobody intends to reach from outside.
      """)
    end
  end

  defp hostname do
    {name, 0} = System.cmd("hostname", ["-s"])
    String.trim(name)
  end
end
