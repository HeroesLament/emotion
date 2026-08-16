defmodule Mix.Tasks.Exmo.Controller do
  @moduledoc """
  Runs an E-Motion controller against the simulated arm.

      mix exmo.controller [--port 4001] [--http] [--enable] [--mode manual]

    * `--port`   — defaults to 4001
    * `--http`   — plaintext, for poking at it with a tool that cannot pin a
      self-signed certificate. Logs a warning, as it should.
    * `--enable` — walk every drive to operation_enabled at boot, so setpoints
      are accepted immediately. Off by default: a real controller does not
      energise its axes because someone started it.
    * `--mode`   — where the mode selector starts: `manual` (default), `auto` or
      `idle`. Jogging is refused outside manual. This is the imaginary keyswitch
      of a bench controller; a machine comes up wherever its real one is
      pointing, which is why `ExProto.Mode` reads a position rather than
      offering one over the protocol.

  Ctrl-C twice to stop.
  """

  @shortdoc "Run a controller with the simulated arm and a JSON-RPC API"

  use Mix.Task

  require Logger

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [port: :integer, http: :boolean, enable: :boolean, mode: :string]
      )

    Mix.Task.run("app.start")

    port = Keyword.get(opts, :port, 4001)
    scheme = if Keyword.get(opts, :http, false), do: :http, else: :https
    dir = Path.join([File.cwd!(), ".emotion", "tls"])

    position = mode_position(opts)

    {:ok, _pid} =
      ExProto.Controller.start_link(
        port: port,
        scheme: scheme,
        mode_position: position,
        tls: [dir: dir, hostnames: ["localhost"]]
      )

    if Keyword.get(opts, :enable, false), do: enable_all()

    ensure_account("operator", :operator)
    ensure_account("viewer", :observer)

    # Worth a line of its own. A controller that refuses every jog because its
    # selector is in auto should say so at boot rather than being diagnosed one
    # rejected command at a time.
    Logger.info("mode selector: #{position}#{if position != :manual, do: " — jogging refused"}")
    Logger.info("controller up — Ctrl-C twice to stop")
    Process.sleep(:infinity)
  end

  # Refused rather than defaulted. `--mode manul` silently coming up in manual is
  # the kind of typo that ends with somebody sure the interlock does not work.
  defp mode_position(opts) do
    case Keyword.get(opts, :mode, "manual") do
      "manual" -> :manual
      "auto" -> :auto
      "idle" -> :idle
      other -> Mix.raise("--mode must be manual, auto or idle, got #{inspect(other)}")
    end
  end

  defp enable_all do
    {:ok, table} = ExProto.Controller.node_table()

    for axis <- ExProto.Controller.axes(table) do
      Exdrive.Drive.enable(axis)
    end

    Logger.info("all axes walked to operation_enabled")
  end

  # A controller nobody can log into is not much of a demonstration. Two
  # accounts so the grant boundary can actually be seen from a client: one that
  # may command motion and one that may only watch.
  #
  # Said loudly enough that it cannot be mistaken for something to ship.
  defp ensure_account(username, role) do
    if ExAuth.Accounts.get_by_username(username) do
      Logger.info("account #{username} (#{role}) already exists")
    else
      password = ExAuth.Provision.generate_password()

      {:ok, _account} =
        ExAuth.Accounts.create(%{username: username, password: password, role: role})

      Logger.warning("""

      Development account created — #{role}

          username  #{username}
          password  #{password}

      Shown once. These exist so `mix exmo.controller` is usable immediately;
      they are not part of a real deployment, where the only account on first
      boot is the administrator ExAuth.Provision mints.
      """)
    end
  end
end
