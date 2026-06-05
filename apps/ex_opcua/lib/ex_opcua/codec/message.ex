defmodule ExOpcUA.Codec.Message do
  @moduledoc """
  UA-TCP transport layer framing (OPC UA Part 6 §7).

  ## Message types

  | Abbr | Bytes | Meaning                               |
  |------|-------|---------------------------------------|
  | HEL  | HELF  | Client hello                          |
  | ACK  | ACKF  | Server acknowledge                    |
  | ERR  | ERRF  | Transport error (either side)         |
  | OPN  | OPNF  | OpenSecureChannel (final chunk)       |
  | CLO  | CLOF  | CloseSecureChannel (final chunk)      |
  | MSG  | MSGF  | Normal service message (may chunk)    |
  | RHE  | RHEF  | Reverse Hello (server-initiated)      |

  ## Chunk framing (MSG/OPN/CLO)

  All chunks share a common 8-byte header:
  ```
  MessageType   3 bytes  e.g. "MSG"
  IsFinal       1 byte   'F'|'C'|'A' (Final/Continuation/Abort)
  MessageSize   UInt32 LE  total byte size including header
  ```

  Followed by:
  ```
  SecureChannelId  UInt32 LE
  SecurityHeader   (asymmetric for OPN, symmetric for MSG/CLO)
  SequenceHeader   UInt32 SequenceNumber, UInt32 RequestId
  Body             service message bytes
  ```

  We handle chunking reassembly in `ExOpcUA.Transport.Connection`.
  This module only deals with individual chunk encode/decode.
  """

  import ExOpcUA.Codec.Primitives

  # ── Message type atoms ────────────────────────────────────────────────────────

  @type message_type :: :hel | :ack | :err | :opn | :clo | :msg | :rhe

  @msg_type_bytes %{
    hel: "HEL",
    ack: "ACK",
    err: "ERR",
    opn: "OPN",
    clo: "CLO",
    msg: "MSG",
    rhe: "RHE"
  }
  @bytes_msg_type Map.new(@msg_type_bytes, fn {k, v} -> {v, k} end)

  @type is_final :: :final | :continuation | :abort
  @is_final_bytes %{final: ?F, continuation: ?C, abort: ?A}
  @bytes_is_final %{?F => :final, ?C => :continuation, ?A => :abort}

  # ── HEL / ACK ─────────────────────────────────────────────────────────────────
  # HEL: Version(u32) + ReceiveBufSize(u32) + SendBufSize(u32) +
  #      MaxMessageSize(u32) + MaxChunkCount(u32) + EndpointUrl(String)
  # ACK: Version(u32) + ReceiveBufSize(u32) + SendBufSize(u32) +
  #      MaxMessageSize(u32) + MaxChunkCount(u32)

  @default_version      0
  @default_recv_buf     65535
  @default_send_buf     65535
  @default_max_msg_size 0       # 0 = no limit
  @default_max_chunks   0       # 0 = no limit

  defmodule Hello do
    defstruct [
      version:          0,
      recv_buf_size:    65535,
      send_buf_size:    65535,
      max_message_size: 0,
      max_chunk_count:  0,
      endpoint_url:     nil
    ]
  end

  defmodule Acknowledge do
    defstruct [
      version:          0,
      recv_buf_size:    65535,
      send_buf_size:    65535,
      max_message_size: 0,
      max_chunk_count:  0
    ]
  end

  defmodule ErrorMessage do
    defstruct [:error_code, :reason]
  end

  @spec encode_hello(Hello.t()) :: binary()
  def encode_hello(%Hello{} = h) do
    body =
      encode_uint32(h.version) <>
      encode_uint32(h.recv_buf_size) <>
      encode_uint32(h.send_buf_size) <>
      encode_uint32(h.max_message_size) <>
      encode_uint32(h.max_chunk_count) <>
      encode_string(h.endpoint_url)

    encode_transport_header(:hel, :final, body)
  end

  @spec decode_hello(binary()) :: {:ok, Hello.t()} | {:error, atom()}
  def decode_hello(data) do
    with {:ok, :hel, :final, body} <- decode_transport_header(data),
         {ver,  r1} <- decode_uint32(body),
         {recv, r2} <- decode_uint32(r1),
         {send, r3} <- decode_uint32(r2),
         {mms,  r4} <- decode_uint32(r3),
         {mcc,  r5} <- decode_uint32(r4),
         {url,  _}  <- decode_string(r5) do
      {:ok, %Hello{
        version: ver, recv_buf_size: recv, send_buf_size: send,
        max_message_size: mms, max_chunk_count: mcc, endpoint_url: url
      }}
    end
  end

  @spec encode_acknowledge(Acknowledge.t()) :: binary()
  def encode_acknowledge(%Acknowledge{} = a) do
    body =
      encode_uint32(a.version) <>
      encode_uint32(a.recv_buf_size) <>
      encode_uint32(a.send_buf_size) <>
      encode_uint32(a.max_message_size) <>
      encode_uint32(a.max_chunk_count)

    encode_transport_header(:ack, :final, body)
  end

  @spec decode_acknowledge(binary()) :: {:ok, Acknowledge.t()} | {:error, atom()}
  def decode_acknowledge(data) do
    with {:ok, :ack, :final, body} <- decode_transport_header(data),
         {ver,  r1} <- decode_uint32(body),
         {recv, r2} <- decode_uint32(r1),
         {send, r3} <- decode_uint32(r2),
         {mms,  r4} <- decode_uint32(r3),
         {mcc,  _}  <- decode_uint32(r4) do
      {:ok, %Acknowledge{
        version: ver, recv_buf_size: recv, send_buf_size: send,
        max_message_size: mms, max_chunk_count: mcc
      }}
    end
  end

  @spec encode_error(non_neg_integer(), String.t() | nil) :: binary()
  def encode_error(error_code, reason \\ nil) do
    body = encode_uint32(error_code) <> encode_string(reason)
    encode_transport_header(:err, :final, body)
  end

  @spec decode_error(binary()) :: {:ok, ErrorMessage.t()} | {:error, atom()}
  def decode_error(data) do
    with {:ok, :err, :final, body} <- decode_transport_header(data),
         {code,   r1} <- decode_uint32(body),
         {reason, _}  <- decode_string(r1) do
      {:ok, %ErrorMessage{error_code: code, reason: reason}}
    end
  end

  # ── Chunk header encode/decode ────────────────────────────────────────────────

  @header_size 8

  @spec encode_transport_header(message_type(), is_final(), binary()) :: binary()
  def encode_transport_header(msg_type, is_final, body) do
    type_bytes  = Map.fetch!(@msg_type_bytes, msg_type)
    final_byte  = Map.fetch!(@is_final_bytes, is_final)
    total_size  = @header_size + byte_size(body)
    <<type_bytes::binary, final_byte::8, total_size::little-32, body::binary>>
  end

  @spec decode_transport_header(binary()) ::
    {:ok, message_type(), is_final(), binary()} | {:error, atom()}
  def decode_transport_header(
    <<t1, t2, t3, final_byte::8, size::little-32, rest::binary>> = data
  ) do
    type_str = <<t1, t2, t3>>
    with {:ok, msg_type} <- Map.fetch(@bytes_msg_type, type_str) |> ok_or(:unknown_message_type),
         {:ok, is_final} <- Map.fetch(@bytes_is_final, final_byte) |> ok_or(:unknown_final_byte) do
      body_size = size - @header_size
      case rest do
        <<body::binary-size(body_size), _tail::binary>> ->
          {:ok, msg_type, is_final, body}
        _ when byte_size(data) < size ->
          {:error, :incomplete}
        _ ->
          {:error, :truncated}
      end
    end
  end
  def decode_transport_header(data) when byte_size(data) < @header_size do
    {:error, :incomplete}
  end
  def decode_transport_header(_), do: {:error, :invalid_header}

  # ── Symmetric security header (MSG/CLO) ──────────────────────────────────────
  # Just a TokenId UInt32 for SecurityPolicy None.

  defmodule SymmetricSecurityHeader do
    defstruct token_id: 0
  end

  @spec encode_symmetric_header(SymmetricSecurityHeader.t()) :: binary()
  def encode_symmetric_header(%SymmetricSecurityHeader{token_id: tid}) do
    encode_uint32(tid)
  end

  @spec decode_symmetric_header(binary()) ::
    {SymmetricSecurityHeader.t(), binary()} | {:error, atom()}
  def decode_symmetric_header(data) do
    case decode_uint32(data) do
      {tid, rest} -> {%SymmetricSecurityHeader{token_id: tid}, rest}
      err -> err
    end
  end

  # ── Asymmetric security header (OPN) ─────────────────────────────────────────
  # SecurityPolicyUri (String), SenderCertificate (ByteString),
  # ReceiverCertificateThumbprint (ByteString)
  # For SecurityPolicy None: all three are null/empty.

  defmodule AsymmetricSecurityHeader do
    defstruct [
      security_policy_uri:            "http://opcfoundation.org/UA/SecurityPolicy#None",
      sender_certificate:             nil,
      receiver_certificate_thumbprint: nil
    ]
  end

  @spec encode_asymmetric_header(AsymmetricSecurityHeader.t()) :: binary()
  def encode_asymmetric_header(%AsymmetricSecurityHeader{} = h) do
    encode_string(h.security_policy_uri) <>
    encode_byte_string(h.sender_certificate) <>
    encode_byte_string(h.receiver_certificate_thumbprint)
  end

  @spec decode_asymmetric_header(binary()) ::
    {AsymmetricSecurityHeader.t(), binary()} | {:error, atom()}
  def decode_asymmetric_header(data) do
    with {uri,   r1} <- decode_string(data),
         {cert,  r2} <- decode_byte_string(r1),
         {thumb, r3} <- decode_byte_string(r2) do
      {%AsymmetricSecurityHeader{
        security_policy_uri: uri,
        sender_certificate: cert,
        receiver_certificate_thumbprint: thumb
      }, r3}
    end
  end

  # ── Sequence header (MSG/OPN/CLO) ─────────────────────────────────────────────

  defmodule SequenceHeader do
    defstruct [:sequence_number, :request_id]
  end

  @spec encode_sequence_header(SequenceHeader.t()) :: binary()
  def encode_sequence_header(%SequenceHeader{sequence_number: sn, request_id: rid}) do
    encode_uint32(sn) <> encode_uint32(rid)
  end

  @spec decode_sequence_header(binary()) ::
    {SequenceHeader.t(), binary()} | {:error, atom()}
  def decode_sequence_header(data) do
    with {sn,  r1} <- decode_uint32(data),
         {rid, r2} <- decode_uint32(r1) do
      {%SequenceHeader{sequence_number: sn, request_id: rid}, r2}
    end
  end

  # ── Full MSG chunk encode/decode ──────────────────────────────────────────────

  defmodule MsgChunk do
    @moduledoc "A decoded MSG/OPN/CLO chunk, pre-reassembly."
    defstruct [
      :msg_type,          # :msg | :opn | :clo
      :is_final,          # :final | :continuation | :abort
      :channel_id,        # uint32
      :security_header,   # %SymmetricSecurityHeader{} or %AsymmetricSecurityHeader{}
      :sequence_header,   # %SequenceHeader{}
      :body               # binary() — service message bytes (may be partial if chunked)
    ]
  end

  @spec encode_msg_chunk(MsgChunk.t()) :: binary()
  def encode_msg_chunk(%MsgChunk{msg_type: type, is_final: final,
                                  channel_id: ch_id,
                                  security_header: sec_hdr,
                                  sequence_header: seq_hdr,
                                  body: body}) do
    sec_b  = encode_security_header(sec_hdr)
    seq_b  = encode_sequence_header(seq_hdr)
    payload = encode_uint32(ch_id) <> sec_b <> seq_b <> body
    encode_transport_header(type, final, payload)
  end

  @spec decode_msg_chunk(binary()) :: {:ok, MsgChunk.t()} | {:error, atom()}
  def decode_msg_chunk(data) do
    with {:ok, msg_type, is_final, payload} <- decode_transport_header(data),
         {ch_id, rest}                      <- decode_uint32(payload),
         {sec_hdr, rest2}                   <- decode_security_header(msg_type, rest),
         {seq_hdr, body}                    <- decode_sequence_header(rest2) do
      {:ok, %MsgChunk{
        msg_type: msg_type, is_final: is_final, channel_id: ch_id,
        security_header: sec_hdr, sequence_header: seq_hdr, body: body
      }}
    end
  end

  defp encode_security_header(%SymmetricSecurityHeader{} = h), do: encode_symmetric_header(h)
  defp encode_security_header(%AsymmetricSecurityHeader{} = h), do: encode_asymmetric_header(h)
  defp encode_security_header(nil), do: encode_symmetric_header(%SymmetricSecurityHeader{})

  defp decode_security_header(:opn, data), do: decode_asymmetric_header(data)
  defp decode_security_header(_,    data), do: decode_symmetric_header(data)

  # ── Chunk reassembly ──────────────────────────────────────────────────────────
  # Accumulates chunks for a request_id until a :final chunk arrives,
  # then returns the concatenated body.

  @spec reassemble([MsgChunk.t()]) :: {:ok, binary()} | {:error, atom()}
  def reassemble(chunks) when is_list(chunks) do
    case List.last(chunks) do
      %MsgChunk{is_final: :final} ->
        body = chunks |> Enum.map(& &1.body) |> Enum.join()
        {:ok, body}
      %MsgChunk{is_final: :abort} ->
        {:error, :chunk_aborted}
      _ ->
        {:error, :incomplete_chunks}
    end
  end

  # ── Default server Acknowledge ────────────────────────────────────────────────

  @spec default_acknowledge() :: Acknowledge.t()
  def default_acknowledge do
    %Acknowledge{
      version:          @default_version,
      recv_buf_size:    @default_recv_buf,
      send_buf_size:    @default_send_buf,
      max_message_size: @default_max_msg_size,
      max_chunk_count:  @default_max_chunks
    }
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, reason), do: {:error, reason}
end
