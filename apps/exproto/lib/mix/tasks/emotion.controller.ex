defmodule Mix.Tasks.Emotion.Controller do
  @moduledoc """
  Runs an E-Motion controller against the simulated arm.

      mix emotion.controller [--port 4001] [--http] [--enable] [--mode manual]
                             [--sname bench]

    * `--port`   — defaults to 4001
    * `--sname`  — start distribution under this short name, so a console can
      attach with `iex --sname console --cookie emotion --remsh <sname>@<host>`.
      That is where the mode selector gets turned, since it is not on the
      protocol.
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

  # Fixed rather than random, because the point of the cookie here is to keep
  # two bench controllers on one laptop from finding each other, not to keep
  # anyone out. A controller reachable over a network gets a real one from
  # config, and this task is documented as a bench tool.
  @cookie :emotion

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [port: :integer, http: :boolean, enable: :boolean, mode: :string, sname: :string]
      )

    Mix.Task.run("app.start")

    # After app.start, not before: Logger is not running yet at the top of a
    # task, so a distribution failure reported there is a message nobody sees.
    start_distribution(Keyword.get(opts, :sname))

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
    ensure_account("programmer", :programmer)
    ensure_account("viewer", :observer)

    # Worth a line of its own. A controller that refuses every jog because its
    # selector is in auto should say so at boot rather than being diagnosed one
    # rejected command at a time.
    Logger.info("mode selector: #{position}#{if position != :manual, do: " — jogging refused"}")
    Logger.info("controller up — Ctrl-C twice to stop")
    Process.sleep(:infinity)
  end

  # A controller is a headless machine, so the console is somewhere else.
  #
  # This matters more than it sounds, because the mode selector is deliberately
  # not on the protocol — `ExProto.Mode` reads a position rather than offering
  # one, since a keyswitch that can be turned from another building is not a
  # keyswitch. Turning it therefore needs somewhere to stand that is *at* the
  # machine but not *on* the wire, and a remote shell into the controller's own
  # node is exactly that.
  #
  #     mix emotion.controller --sname bench
  #     iex --sname console --cookie emotion --remsh bench@<host>
  #     iex> ExProto.Mode.select(:auto)
  #
  # `iex -S mix emotion.controller` does not work and is worth saying so: a mix
  # task that blocks never returns to the boot sequence, so the IEx shell it
  # would have started never starts. `IEx.started?/0` reads false there, which
  # is the opposite of what it looks like it should mean.
  defp start_distribution(nil), do: :ok

  defp start_distribution(sname) do
    case Node.start(String.to_atom(sname), :shortnames) do
      {:ok, _pid} ->
        Node.set_cookie(@cookie)
        Logger.info("node #{Node.self()} — attach with: iex --sname console --cookie #{@cookie} --remsh #{Node.self()}")

      {:error, reason} ->
        Logger.warning("could not start distribution as #{sname}: #{inspect(reason)}")
    end
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
      EMotion.Axis.enable(axis)
    end

    Logger.info("all axes walked to operation_enabled")
  end

  # A controller nobody can log into is not much of a demonstration. Three
  # accounts so the grant boundary can actually be seen from a client: one that
  # may only watch, one that may command motion, and one that may also write and
  # run programs.
  #
  # The third is not a convenience. Without it the bench controller could jog
  # and teach but not create a program — `operator` has neither `edit_program`
  # nor `execute_program`, so the teach-to-run loop this task exists to
  # demonstrate stopped with -32011 at the first `program.create`. Which is the
  # grant boundary working; it was the account list that was wrong.
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

      Shown once. These exist so `mix emotion.controller` is usable immediately;
      they are not part of a real deployment, where the only account on first
      boot is the administrator ExAuth.Provision mints.
      """)
    end
  end
end
