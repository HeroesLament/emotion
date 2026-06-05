defmodule ExOpcUA.Client.Transport do
  @moduledoc """
  Owns the TCP socket. Responsibilities:
    - connect / reconnect
    - send raw bytes
    - receive bytes, reassemble complete frames
    - forward complete frames to parent (Session) as {:frame, type, body}
    - handle HEL/ACK exchange, then hand off to Session

  States: :disconnected → :connecting → :hello_sent → :ready
  """

  @behaviour :gen_statem

  require Logger

  alias ExOpcUA.Codec.Message

  @reconnect_ms 2_000

  defstruct [
    :url, :host, :port, :timeout,
    :socket, :session,
    recv_buf: <<>>
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def send_bytes(pid, data) do
    :gen_statem.cast(pid, {:send, data})
  end

  # ── gen_statem callbacks ──────────────────────────────────────────────────────

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    url     = Keyword.fetch!(opts, :url)
    session = Keyword.fetch!(opts, :session)
    {host, port} = parse_url(url)
    data = %__MODULE__{
      url:     url,
      host:    host,
      port:    port,
      timeout: Keyword.get(opts, :timeout, 5_000),
      session: session
    }
    {:ok, :disconnected, data, [{:next_event, :internal, :connect}]}
  end

  # ── State: disconnected ───────────────────────────────────────────────────────

  def disconnected(:enter, _old, _data), do: :keep_state_and_data

  def disconnected(:internal, :connect, data) do
    case :gen_tcp.connect(
           String.to_charlist(data.host), data.port,
           [:binary, packet: :raw, active: :once, nodelay: true],
           data.timeout
         ) do
      {:ok, sock} ->
        Logger.info("[Transport] Connected to #{data.url}")
        new_data = %{data | socket: sock, recv_buf: <<>>}
        send_hello(new_data)
        {:next_state, :hello_sent, new_data}

      {:error, reason} ->
        Logger.warning("[Transport] Connect failed: #{inspect(reason)}, retrying in #{@reconnect_ms}ms")
        {:keep_state_and_data, [{{:timeout, :reconnect}, @reconnect_ms, nil}]}
    end
  end

  def disconnected({:timeout, :reconnect}, nil, _data) do
    {:keep_state_and_data, [{:next_event, :internal, :connect}]}
  end

  def disconnected(:cast, {:send, _}, _data), do: :keep_state_and_data
  def disconnected(:info, _, _data), do: :keep_state_and_data

  # ── State: hello_sent ─────────────────────────────────────────────────────────

  def hello_sent(:enter, _old, _data), do: :keep_state_and_data

  def hello_sent(:info, {:tcp, sock, bytes}, %{socket: sock} = data) do
    :inet.setopts(sock, active: :once)
    case process_buf(data.recv_buf <> bytes, data) do
      {:ack, rest_data} ->
        Logger.debug("[Transport] ACK received")
        send(data.session, :transport_ready)
        {:next_state, :ready, %{rest_data | recv_buf: <<>>}}
      {:more, new_data} ->
        {:keep_state, new_data}
      {:error, reason} ->
        Logger.warning("[Transport] Protocol error in hello: #{inspect(reason)}")
        reconnect(data)
    end
  end

  def hello_sent(:info, {:tcp_closed, _}, data), do: reconnect(data)
  def hello_sent(:info, {:tcp_error, _, r}, data) do
    Logger.warning("[Transport] TCP error: #{inspect(r)}")
    reconnect(data)
  end

  def hello_sent(:cast, {:send, _}, _data), do: :keep_state_and_data

  # ── State: ready ──────────────────────────────────────────────────────────────

  def ready(:enter, _old, _data), do: :keep_state_and_data

  def ready(:info, {:tcp, sock, bytes}, %{socket: sock} = data) do
    :inet.setopts(sock, active: :once)
    case process_buf(data.recv_buf <> bytes, data) do
      {:more, new_data}  -> {:keep_state, new_data}
      {:error, reason}   ->
        Logger.warning("[Transport] Protocol error: #{inspect(reason)}")
        reconnect(data)
      # ACK not expected in :ready, ignore
      {:ack, new_data}   -> {:keep_state, new_data}
    end
  end

  def ready(:cast, {:send, bytes}, data) do
    case :gen_tcp.send(data.socket, bytes) do
      :ok -> :keep_state_and_data
      {:error, reason} ->
        Logger.warning("[Transport] Send failed: #{inspect(reason)}")
        reconnect(data)
    end
  end

  def ready(:info, {:tcp_closed, _}, data) do
    Logger.info("[Transport] Connection closed by server")
    reconnect(data)
  end

  def ready(:info, {:tcp_error, _, reason}, data) do
    Logger.warning("[Transport] TCP error: #{inspect(reason)}")
    reconnect(data)
  end

  # ── Internal helpers ──────────────────────────────────────────────────────────

  defp send_hello(data) do
    alias ExOpcUA.Codec.Message.Hello
    hello = %Hello{
      version:          0,
      recv_buf_size:    65535,
      send_buf_size:    65535,
      max_message_size: 0,
      max_chunk_count:  0,
      endpoint_url:     data.url
    }
    :gen_tcp.send(data.socket, Message.encode_hello(hello))
  end

  # Returns {:ack, data} | {:more, data} | {:error, reason}
  defp process_buf(buf, data) do
    case extract_frame(buf) do
      {:ok, type, frame, rest} ->
        dispatch_frame(type, frame, data, rest)
      :incomplete ->
        {:more, %{data | recv_buf: buf}}
      {:error, _} = err ->
        err
    end
  end

  defp extract_frame(<<type_a, type_b, type_c, _final, size::little-32, _::binary>> = buf)
       when byte_size(buf) >= size do
    type = decode_msg_type(<<type_a, type_b, type_c>>)
    <<frame::binary-size(size), rest::binary>> = buf
    {:ok, type, frame, rest}
  end
  defp extract_frame(buf) when byte_size(buf) < 8, do: :incomplete
  defp extract_frame(_), do: {:error, :bad_frame}

  defp decode_msg_type(<<"ACK">>), do: :ack
  defp decode_msg_type(<<"MSG">>), do: :msg
  defp decode_msg_type(<<"OPN">>), do: :opn
  defp decode_msg_type(<<"CLO">>), do: :clo
  defp decode_msg_type(<<"ERR">>), do: :err
  defp decode_msg_type(_),         do: :unknown

  defp dispatch_frame(:ack, _frame, data, rest) do
    # Consume ACK, signal caller
    {:ack, %{data | recv_buf: rest}}
  end

  defp dispatch_frame(type, frame, data, rest) when type in [:msg, :opn, :clo] do
    case Message.decode_msg_chunk(frame) do
      {:ok, chunk} ->
        send(data.session, {:frame, type, chunk})
        # Recurse — there may be more frames in rest
        if rest == <<>> do
          {:more, %{data | recv_buf: <<>>}}
        else
          process_buf(rest, %{data | recv_buf: <<>>})
        end
      {:error, _} = err -> err
    end
  end

  defp dispatch_frame(:err, frame, data, rest) do
    case Message.decode_error(frame) do
      {:ok, err} ->
        Logger.error("[Transport] Server ERR: #{inspect(err.reason)} (0x#{Integer.to_string(err.error_code, 16)})")
      _ -> :ok
    end
    send(data.session, :transport_error)
    {:more, %{data | recv_buf: rest}}
  end

  defp dispatch_frame(_type, _frame, data, rest) do
    {:more, %{data | recv_buf: rest}}
  end

  defp reconnect(data) do
    if data.socket, do: :gen_tcp.close(data.socket)
    send(data.session, :transport_disconnected)
    new_data = %{data | socket: nil, recv_buf: <<>>}
    {:next_state, :disconnected, new_data, [{:next_event, :internal, :connect}]}
  end

  defp parse_url("opc.tcp://" <> rest) do
    case String.split(rest, ":") do
      [host, port] -> {host, String.to_integer(port)}
      [host]       -> {host, 4840}
    end
  end
  defp parse_url(url), do: raise("Invalid OPC UA URL: #{url}")
end
