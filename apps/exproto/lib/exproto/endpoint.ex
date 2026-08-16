defmodule ExProto.Endpoint do
  @moduledoc """
  The listener: Bandit serving the router, over TLS by default.

  ## TLS is the default and plaintext is a decision

  `scheme: :http` exists, logs a warning every time it starts, and has to be
  asked for by name. An accidental plaintext listener on a device that can move
  a robot arm is not a configuration mistake anyone should be able to make
  quietly, and the asymmetry — encrypted unless someone typed otherwise — is
  the only version of this that survives contact with a rushed deployment.

  Certificate material comes from `ExProto.TLS`, which mints a self-signed pair
  on first boot when no CA-issued one is configured.

  ## What TLS here does and does not protect

  It encrypts the link, so joint positions and program contents are not
  readable by anything else on the segment, and it authenticates the controller
  to a client that pinned its fingerprint. It is not authorisation: anyone who
  can reach the port and complete the handshake can currently drive the arm.
  That gap is real and named rather than papered over — a token in `initialize`
  is the next thing this needs, and network segmentation is not a substitute
  for it any more than TLS is.
  """

  require Logger

  alias ExProto.{Jog, Mode, Router, TLS}

  @default_port 4001

  @doc """
  A child spec for a supervision tree.

  Options:

    * `:table` — the projected node table
    * `:source` — `{module, arg}` for reading and writing values
    * `:port` — defaults to 4001
    * `:scheme` — `:https` (default) or `:http`
    * `:tls` — passed to `ExProto.TLS.material/1`
    * `:jog` — name for this endpoint's held-command watchdog; defaults to one
      derived from the port
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    scheme = Keyword.get(opts, :scheme, :https)
    port = Keyword.get(opts, :port, @default_port)
    jog = Keyword.get(opts, :jog, jog_name(port))
    mode = Keyword.get(opts, :mode, mode_name(port))

    with {:ok, built} <- build(Keyword.put(opts, :jog, jog), scheme) do
      children = [
        # First, and therefore last to stop. A connection that arrives before
        # the watchdog exists would be refused rather than jogged unguarded —
        # correct, but the reason to order it this way is the other end:
        # :rest_for_one means the listener goes down before the watchdog, so
        # nothing can be holding an axis by the time it runs terminate/2 and
        # zeroes whatever is left.
        {Jog, name: jog},
        # After the watchdog and before the listener. Turning the selector
        # releases every hold, so the thing it releases them through has to
        # outlive it — and no connection should be able to jog before there is
        # a mode to check against.
        {Mode, name: mode, jog: jog, position: Keyword.get(opts, :mode_position, :manual)},
        {Bandit,
         plug: {Router, built.plug_opts},
         scheme: scheme,
         port: port,
         thousand_island_options: built.transport}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)
      |> tap(fn
        {:ok, _pid} -> announce(scheme, port, built.fingerprint)
        _ -> :ok
      end)
    end
  end

  # Per endpoint, not global. The test suite runs several controllers in one VM
  # and they must not share holds; the port is what already distinguishes them.
  # An endpoint on an ephemeral port needs `:jog` passed explicitly.
  defp jog_name(port), do: Module.concat(Jog, "P#{port}")
  defp mode_name(port), do: Module.concat(Mode, "P#{port}")

  defp build(opts, :http) do
    Logger.warning("""
    ExProto.Endpoint is starting WITHOUT TLS.

    Everything on this link — joint positions, program contents, commands that
    move the arm — is readable and forgeable by anything else on this network.
    Acceptable for a test or a bench; not for a machine anyone stands near.
    """)

    {:ok, %{plug_opts: plug_opts(opts, nil), transport: [], fingerprint: nil}}
  end

  defp build(opts, :https) do
    with {:ok, material} <- TLS.material(Keyword.get(opts, :tls, [])) do
      {:ok,
       %{
         plug_opts: plug_opts(opts, material.fingerprint),
         transport: [transport_options: TLS.ssl_options(material)],
         fingerprint: material.fingerprint
       }}
    end
  end

  defp plug_opts(opts, fingerprint) do
    %{
      table: Keyword.fetch!(opts, :table),
      source: Keyword.fetch!(opts, :source),
      fingerprint: fingerprint,
      jog: Keyword.get(opts, :jog, Jog),
      idle_timeout: Keyword.get(opts, :idle_timeout, 60_000),
      keepalive_ms: Keyword.get(opts, :keepalive_ms)
    }
  end

  defp announce(:https, port, fingerprint) do
    Logger.info("""
    E-Motion controller listening on wss://0.0.0.0:#{port}/rpc

      fingerprint  #{fingerprint}

    Clients pin this on first connection. A fingerprint that changes without a
    deliberate certificate rotation means the controller is not the one you
    connected to before.
    """)
  end

  defp announce(:http, port, _fingerprint) do
    Logger.info("E-Motion controller listening on ws://0.0.0.0:#{port}/rpc (NO TLS)")
  end
end
