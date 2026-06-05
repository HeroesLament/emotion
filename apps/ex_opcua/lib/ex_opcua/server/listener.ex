defmodule ExOpcUA.Server.Listener do
  @moduledoc """
  TCP accept loop for the OPC UA server.

  Listens on a configured port and spawns one
  `ExOpcUA.Server.Connection` per incoming client.
  Supervised under `ExOpcUA.Server`.
  """

  use GenServer
  require Logger

  defstruct [:port, :listen_sock, :acceptor_ref, :connection_sup, :node_manager, :server_config]

  @default_port 4840
  @tcp_opts [
    :binary,
    packet: :raw,
    active: false,
    reuseaddr: true,
    nodelay: true,
    keepalive: true
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def port do
    GenServer.call(__MODULE__, :port)
  end

  # ── init ──────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    port           = Keyword.get(opts, :port, @default_port)
    node_manager   = Keyword.fetch!(opts, :node_manager)
    server_config  = Keyword.get(opts, :server_config, %{})
    connection_sup = Keyword.fetch!(opts, :connection_sup)

    case :gen_tcp.listen(port, @tcp_opts) do
      {:ok, listen_sock} ->
        Logger.info("[ExOpcUA] Listening on opc.tcp://0.0.0.0:#{port}")
        state = %__MODULE__{
          port: port,
          listen_sock: listen_sock,
          connection_sup: connection_sup,
          node_manager: node_manager,
          server_config: server_config
        }
        # Kick off the first accept in a non-blocking way
        send(self(), :accept)
        {:ok, state}

      {:error, reason} ->
        Logger.error("[ExOpcUA] Failed to listen on port #{port}: #{inspect(reason)}")
        {:stop, {:listen_failed, reason}}
    end
  end

  # ── handle_info ───────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:accept, %{listen_sock: lsock} = state) do
    ref = make_ref()
    listener_pid = self()

    Task.start(fn ->
      case :gen_tcp.accept(lsock) do
        {:ok, sock} ->
          # Transfer ownership to the listener process immediately, while the
          # Task is still alive. The listener will then hand it to the connection.
          :gen_tcp.controlling_process(sock, listener_pid)
          send(listener_pid, {:accepted, ref, {:ok, sock}})
        {:error, reason} ->
          send(listener_pid, {:accepted, ref, {:error, reason}})
      end
    end)

    {:noreply, %{state | acceptor_ref: ref}}
  end

  def handle_info({:accepted, ref, {:ok, sock}}, %{acceptor_ref: ref} = state) do
    spawn_connection(sock, state)
    send(self(), :accept)
    {:noreply, %{state | acceptor_ref: nil}}
  end

  def handle_info({:accepted, ref, {:error, :closed}}, %{acceptor_ref: ref} = state) do
    Logger.info("[ExOpcUA] Listen socket closed, stopping listener")
    {:stop, :normal, state}
  end

  def handle_info({:accepted, ref, {:error, reason}}, %{acceptor_ref: ref} = state) do
    Logger.warning("[ExOpcUA] Accept error: #{inspect(reason)}, retrying")
    send(self(), :accept)
    {:noreply, %{state | acceptor_ref: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("[ExOpcUA.Listener] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── handle_call ───────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  # ── terminate ─────────────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, %{listen_sock: sock}) when is_port(sock) do
    :gen_tcp.close(sock)
  end
  def terminate(_reason, _state), do: :ok

  # ── Private ───────────────────────────────────────────────────────────────────

  defp spawn_connection(sock, state) do
    conn_opts = [
      socket:        sock,
      node_manager:  state.node_manager,
      server_config: state.server_config
    ]
    case DynamicSupervisor.start_child(state.connection_sup, {ExOpcUA.Server.Connection, conn_opts}) do
      {:ok, pid} ->
        # Listener now owns the socket (transferred in the accept Task).
        # Hand it to the connection process and arm it.
        case :gen_tcp.controlling_process(sock, pid) do
          :ok ->
            send(pid, :socket_ready)
            Logger.debug("[ExOpcUA] New connection #{inspect(pid)} from #{peer_info(sock)}")
          {:error, reason} ->
            Logger.error("[ExOpcUA] controlling_process failed: #{inspect(reason)}")
            :gen_tcp.close(sock)
            DynamicSupervisor.terminate_child(state.connection_sup, pid)
        end

      {:error, reason} ->
        Logger.error("[ExOpcUA] Failed to start connection: #{inspect(reason)}")
        :gen_tcp.close(sock)
    end
  end

  defp peer_info(sock) do
    case :inet.peername(sock) do
      {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
      _ -> "unknown"
    end
  end
end
