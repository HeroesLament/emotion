defmodule ExProto.Controller do
  @moduledoc """
  Brings up a whole running controller: drives, node table, endpoint.

  This is the composition root — the one place that knows the simulated arm,
  the Information Model and the JSON-RPC transport are meant to be the same
  machine. Everything it wires together was already testable on its own, which
  is why this module is short and has no logic worth testing in it.

  ## What it starts

  A `Exdrive.Drive` per axis declared in the model, the model projected into a
  node table, and `ExProto.Endpoint` over TLS bound to those drives through
  `ExProto.Source.Exdrive`.

  Drives run on their internal 1 kHz clock here. A controller with the FPGA
  metronome fitted would pass `clock: :external` and step them from the
  fieldbus instead; nothing else in this module changes.

  ## Usage

      ExProto.Controller.start_link(port: 4001)

  or `mix exmo.controller`, which is the same thing with a console attached.
  """

  require Logger

  alias ExMo.InformationModel
  alias ExMo.Projection.JSONRPC
  alias ExProto.{Endpoint, Source}

  @doc """
  Starts drives and the endpoint.

  Options:

    * `:port` — defaults to 4001
    * `:scheme` — `:https` (default) or `:http`
    * `:tls` — passed to `ExProto.TLS.material/1`; `:dir` is where the
      certificate lives
    * `:clock` — `:internal` (default) or `:external`
    * `:mode_position` — where the mode selector starts; `:manual` by default
  """
  def start_link(opts \\ []) do
    with {:ok, table} <- node_table(),
         :ok <- start_drives(table, Keyword.get(opts, :clock, :internal)) do
      port = Keyword.get(opts, :port, 4001)
      mode = Keyword.get(opts, :mode, Module.concat(ExProto.Mode, "P#{port}"))

      {:ok, _run} =
        ExProto.Program.Run.start_link(name: ExProto.Program.Run, mode: mode)

      endpoint_opts =
        opts
        |> Keyword.take([:port, :scheme, :tls, :mode_position])
        |> Keyword.merge(table: table, source: source(mode), mode: mode)

      Endpoint.start_link(endpoint_opts)
    end
  end

  # Drives and stored geometry are different kinds of thing with different
  # failure modes, so they are different sources and the router is explicit.
  # `state.*` stays with the drives because it is derived from them — whether
  # anything is faulted is a question about the axes.
  defp source(mode) do
    drives = {Source.Exdrive, [mode: mode]}

    {Source.Composite,
     %{
       "axes" => drives,
       "state" => drives,
       "cell" => {Source.Cell, []},
       "program" => {Source.Program, [run: ExProto.Program.Run]}
     }}
  end

  @doc "The projected node table this controller serves."
  def node_table do
    with {:ok, model} <- InformationModel.compiled_model() do
      JSONRPC.project(model)
    end
  end

  @doc """
  The axis ids the model declares, which is what the drives are named after.

  Derived from the table rather than from a second list, so a model that grows
  an axis does not need this module edited — and cannot end up with a node that
  has no drive because someone updated one list and not the other.
  """
  def axes(table) do
    table
    |> JSONRPC.filter(:property)
    |> Enum.flat_map(fn node ->
      case String.split(node.node_id, ".") do
        ["axes", axis, _field] -> [axis]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp start_drives(table, clock) do
    axes = axes(table)

    Enum.each(axes, fn axis ->
      case Exdrive.Supervisor.start_drive(axis_id: axis, clock: clock) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Logger.error("could not start axis #{axis}: #{inspect(reason)}")
      end
    end)

    Logger.info("E-Motion controller: #{length(axes)} axes running — #{Enum.join(axes, ", ")}")
    audit_mastering()
    :ok
  end

  # Write down what the fleet says, and say out loud what changed.
  #
  # This is the only place a re-mastered axis can be caught. Everything else
  # about such a cell looks fine — every joint reports a plausible angle, every
  # move executes cleanly — and the work lands somewhere other than where it
  # was taught. A log line is the minimum; an operator confirmation before the
  # first program runs is the eventual answer.
  defp audit_mastering do
    case ExMo.Cell.audit_mastering() do
      {:ok, []} ->
        :ok

      {:ok, findings} ->
        Enum.each(findings, fn
          {:changed, axis, was, now} ->
            Logger.warning(
              "mastering CHANGED on #{axis}: #{was} -> #{now} rad. " <>
                "Every point taught on this robot has moved by the difference."
            )

          {:lost, axis, was} ->
            Logger.warning("mastering LOST on #{axis} (was #{was} rad) — a replaced board?")

          {:new, axis, now} ->
            Logger.info("mastering recorded for #{axis}: #{now} rad")
        end)
    end
  rescue
    # A controller that will not start because its shadow table is unhappy is
    # worse than one that starts without the audit. Say so and carry on.
    error -> Logger.error("mastering audit skipped: #{inspect(error)}")
  end
end
