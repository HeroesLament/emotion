defmodule ExOpcUA.Codec.Primitives do
  @moduledoc """
  OPC UA binary encoding for all primitive (scalar) built-in types.

  All multi-byte integers are **little-endian** as per OPC UA Part 6 §5.2.2.
  All functions follow the convention:

      encode_TYPE(value) :: binary()
      decode_TYPE(binary()) :: {value, rest :: binary()} | {:error, reason}

  Strings: length-prefixed Int32 (LE). -1 (0xFFFFFFFF) means null/absent.
  DateTime: UInt64 100-nanosecond intervals since 1601-01-01 00:00:00 UTC.
  Guid: 16 bytes — Data1(u32 LE), Data2(u16 LE), Data3(u16 LE), Data4(8 bytes BE).
  """

  # ── Boolean ──────────────────────────────────────────────────────────────────

  @spec encode_boolean(boolean()) :: binary()
  def encode_boolean(true),  do: <<1::8>>
  def encode_boolean(false), do: <<0::8>>

  @spec decode_boolean(binary()) :: {boolean(), binary()} | {:error, :truncated}
  def decode_boolean(<<0, rest::binary>>), do: {false, rest}
  def decode_boolean(<<_, rest::binary>>), do: {true,  rest}
  def decode_boolean(<<>>),                do: {:error, :truncated}

  # ── Signed integers ──────────────────────────────────────────────────────────

  @spec encode_sbyte(integer()) :: binary()
  def encode_sbyte(v), do: <<v::little-signed-8>>

  @spec decode_sbyte(binary()) :: {integer(), binary()} | {:error, :truncated}
  def decode_sbyte(<<v::little-signed-8, rest::binary>>), do: {v, rest}
  def decode_sbyte(_),                                     do: {:error, :truncated}

  @spec encode_int16(integer()) :: binary()
  def encode_int16(v), do: <<v::little-signed-16>>

  @spec decode_int16(binary()) :: {integer(), binary()} | {:error, :truncated}
  def decode_int16(<<v::little-signed-16, rest::binary>>), do: {v, rest}
  def decode_int16(_),                                      do: {:error, :truncated}

  @spec encode_int32(integer()) :: binary()
  def encode_int32(v), do: <<v::little-signed-32>>

  @spec decode_int32(binary()) :: {integer(), binary()} | {:error, :truncated}
  def decode_int32(<<v::little-signed-32, rest::binary>>), do: {v, rest}
  def decode_int32(_),                                      do: {:error, :truncated}

  @spec encode_int64(integer()) :: binary()
  def encode_int64(v), do: <<v::little-signed-64>>

  @spec decode_int64(binary()) :: {integer(), binary()} | {:error, :truncated}
  def decode_int64(<<v::little-signed-64, rest::binary>>), do: {v, rest}
  def decode_int64(_),                                      do: {:error, :truncated}

  # ── Unsigned integers ─────────────────────────────────────────────────────────

  @spec encode_byte(non_neg_integer()) :: binary()
  def encode_byte(v), do: <<v::8>>

  @spec decode_byte(binary()) :: {non_neg_integer(), binary()} | {:error, :truncated}
  def decode_byte(<<v::8, rest::binary>>), do: {v, rest}
  def decode_byte(_),                       do: {:error, :truncated}

  @spec encode_uint16(non_neg_integer()) :: binary()
  def encode_uint16(v), do: <<v::little-unsigned-16>>

  @spec decode_uint16(binary()) :: {non_neg_integer(), binary()} | {:error, :truncated}
  def decode_uint16(<<v::little-unsigned-16, rest::binary>>), do: {v, rest}
  def decode_uint16(_),                                        do: {:error, :truncated}

  @spec encode_uint32(non_neg_integer()) :: binary()
  def encode_uint32(v), do: <<v::little-unsigned-32>>

  @spec decode_uint32(binary()) :: {non_neg_integer(), binary()} | {:error, :truncated}
  def decode_uint32(<<v::little-unsigned-32, rest::binary>>), do: {v, rest}
  def decode_uint32(_),                                        do: {:error, :truncated}

  @spec encode_uint64(non_neg_integer()) :: binary()
  def encode_uint64(v), do: <<v::little-unsigned-64>>

  @spec decode_uint64(binary()) :: {non_neg_integer(), binary()} | {:error, :truncated}
  def decode_uint64(<<v::little-unsigned-64, rest::binary>>), do: {v, rest}
  def decode_uint64(_),                                        do: {:error, :truncated}

  # ── Floats (IEEE 754, LE) ─────────────────────────────────────────────────────

  @spec encode_float(float()) :: binary()
  def encode_float(v), do: <<v::little-float-32>>

  @spec decode_float(binary()) :: {float(), binary()} | {:error, :truncated}
  def decode_float(<<v::little-float-32, rest::binary>>), do: {v, rest}
  def decode_float(_),                                     do: {:error, :truncated}

  @spec encode_double(float()) :: binary()
  def encode_double(v), do: <<v::little-float-64>>

  @spec decode_double(binary()) :: {float(), binary()} | {:error, :truncated}
  def decode_double(<<v::little-float-64, rest::binary>>), do: {v, rest}
  def decode_double(_),                                     do: {:error, :truncated}

  # ── String (UA String / XmlElement / ByteString share this framing) ───────────
  # Length-prefixed Int32 LE. -1 = null. Empty string has length 0.

  @spec encode_string(String.t() | nil) :: binary()
  def encode_string(nil), do: <<-1::little-signed-32>>
  def encode_string(s) when is_binary(s) do
    len = byte_size(s)
    <<len::little-signed-32, s::binary>>
  end

  @spec decode_string(binary()) :: {String.t() | nil, binary()} | {:error, atom()}
  def decode_string(<<-1::little-signed-32, rest::binary>>), do: {nil, rest}
  def decode_string(<<len::little-signed-32, rest::binary>>) when len >= 0 do
    case rest do
      <<s::binary-size(len), tail::binary>> -> {s, tail}
      _ -> {:error, :truncated}
    end
  end
  def decode_string(<<len::little-signed-32, _::binary>>) when len < -1,
    do: {:error, :invalid_length}
  def decode_string(_), do: {:error, :truncated}

  # ByteString uses the same encoding as String at the wire level
  @spec encode_byte_string(binary() | nil) :: binary()
  defdelegate encode_byte_string(v), to: __MODULE__, as: :encode_string

  @spec decode_byte_string(binary()) :: {binary() | nil, binary()} | {:error, atom()}
  defdelegate decode_byte_string(b), to: __MODULE__, as: :decode_string

  # ── DateTime ──────────────────────────────────────────────────────────────────
  # UInt64: 100-nanosecond intervals since 1601-01-01 00:00:00 UTC.
  # Elixir DateTime uses Unix epoch (1970-01-01). Delta = 11644473600 seconds.

  @ua_epoch_offset_us 11_644_473_600_000_000
  # Convert microseconds → 100ns intervals: multiply by 10
  @us_to_100ns 10

  @spec encode_datetime(DateTime.t() | nil) :: binary()
  def encode_datetime(nil), do: <<0::little-unsigned-64>>
  def encode_datetime(%DateTime{} = dt) do
    unix_us = DateTime.to_unix(dt, :microsecond)
    ua_100ns = (unix_us + @ua_epoch_offset_us) * @us_to_100ns
    <<ua_100ns::little-unsigned-64>>
  end

  @spec decode_datetime(binary()) :: {DateTime.t() | nil, binary()} | {:error, atom()}
  def decode_datetime(<<0::little-unsigned-64, rest::binary>>), do: {nil, rest}
  def decode_datetime(<<ua_100ns::little-unsigned-64, rest::binary>>) do
    unix_us = div(ua_100ns, @us_to_100ns) - @ua_epoch_offset_us
    case DateTime.from_unix(unix_us, :microsecond) do
      {:ok, dt} -> {dt, rest}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end
  def decode_datetime(_), do: {:error, :truncated}

  @spec now_ua() :: binary()
  def now_ua, do: encode_datetime(DateTime.utc_now())

  # ── Guid ──────────────────────────────────────────────────────────────────────
  # 16 bytes: Data1(u32 LE), Data2(u16 LE), Data3(u16 LE), Data4(8 bytes, big-endian)
  # Represented in Elixir as a 16-byte binary (raw) or string "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

  @spec encode_guid(binary()) :: binary()
  def encode_guid(<<d1::32, d2::16, d3::16, d4::binary-8>>) do
    # Input is raw 16-byte big-endian UUID; re-encode D1/D2/D3 as LE
    <<d1::little-32, d2::little-16, d3::little-16, d4::binary>>
  end
  def encode_guid(s) when is_binary(s) and byte_size(s) == 36 do
    # Parse "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    s
    |> String.replace("-", "")
    |> Base.decode16!(case: :mixed)
    |> encode_guid()
  end

  @spec decode_guid(binary()) :: {binary(), binary()} | {:error, atom()}
  def decode_guid(<<d1::little-32, d2::little-16, d3::little-16, d4::binary-8, rest::binary>>) do
    # Return as canonical 16-byte big-endian binary
    guid = <<d1::32, d2::16, d3::16, d4::binary>>
    {guid, rest}
  end
  def decode_guid(_), do: {:error, :truncated}

  @spec guid_to_string(binary()) :: String.t()
  def guid_to_string(<<d1::binary-4, d2::binary-2, d3::binary-2, d4a::binary-2, d4b::binary-6>>) do
    [d1, d2, d3, d4a, d4b]
    |> Enum.map(&Base.encode16(&1, case: :upper))
    |> Enum.join("-")
  end

  # ── StatusCode ────────────────────────────────────────────────────────────────
  # Encoded as UInt32. 0 = Good.

  @spec encode_status_code(non_neg_integer()) :: binary()
  defdelegate encode_status_code(v), to: __MODULE__, as: :encode_uint32

  @spec decode_status_code(binary()) :: {non_neg_integer(), binary()} | {:error, atom()}
  defdelegate decode_status_code(b), to: __MODULE__, as: :decode_uint32

  # Well-known status codes
  def status_good,                    do: 0x00000000
  def status_bad_internal_error,      do: 0x80020000
  def status_bad_node_id_unknown,     do: 0x80340000
  def status_bad_not_readable,        do: 0x803B0000
  def status_bad_not_writable,        do: 0x803C0000
  def status_bad_out_of_range,        do: 0x80350000
  def status_bad_session_closed,      do: 0x80050000
  def status_bad_security_mode_rejected, do: 0x80120000
  def status_bad_too_many_sessions,   do: 0x80080000
  def status_bad_service_unsupported, do: 0x800B0000
  def status_bad_decoding_error,      do: 0x80070000
  def status_uncertain_initial_value, do: 0x40920000

  # ── Array helpers ─────────────────────────────────────────────────────────────
  # OPC UA arrays: Int32 length (-1 = null array), then elements.

  @spec encode_array([term()], (term() -> binary())) :: binary()
  def encode_array(nil, _encode_fn) do
    <<-1::little-signed-32>>
  end
  def encode_array(items, encode_fn) when is_list(items) do
    count = length(items)
    body  = Enum.map_join(items, &encode_fn.(&1))
    <<count::little-signed-32, body::binary>>
  end

  @spec decode_array(binary(), (binary() -> {term(), binary()})) ::
    {[term()] | nil, binary()} | {:error, atom()}
  def decode_array(<<-1::little-signed-32, rest::binary>>, _decode_fn), do: {nil, rest}
  def decode_array(<<count::little-signed-32, rest::binary>>, decode_fn) when count >= 0 do
    decode_array_elements(rest, count, [], decode_fn)
  end
  def decode_array(_, _), do: {:error, :truncated}

  defp decode_array_elements(rest, 0, acc, _decode_fn) do
    {Enum.reverse(acc), rest}
  end
  defp decode_array_elements(data, n, acc, decode_fn) do
    case decode_fn.(data) do
      {item, rest} -> decode_array_elements(rest, n - 1, [item | acc], decode_fn)
      {:error, _} = err -> err
    end
  end
end
