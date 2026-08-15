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

  alias ExProto.{Router, TLS}

  @default_port 4001

  @doc """
  A child spec for a supervision tree.

  Options:

    * `:table` — the projected node table
    * `:source` — `{module, arg}` for reading and writing values
    * `:port` — defaults to 4001
    * `:scheme` — `:https` (default) or `:http`
    * `:tls` — passed to `ExProto.TLS.material/1`
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

    with {:ok, plug_opts} <- build(opts, scheme) do
      Bandit.start_link(
        plug: {Router, plug_opts.plug_opts},
        scheme: scheme,
        port: port,
        thousand_island_options: plug_opts.transport
      )
      |> tap(fn
        {:ok, _pid} -> announce(scheme, port, plug_opts.fingerprint)
        _ -> :ok
      end)
    end
  end

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
      fingerprint: fingerprint
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
