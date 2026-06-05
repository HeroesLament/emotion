defmodule ExOpcUA.Codec.Types do
  @moduledoc """
  OPC UA binary encoding for composite built-in types.

  Covers:
  - NodeId / ExpandedNodeId
  - QualifiedName
  - LocalizedText
  - Variant (discriminated union of all built-in types)
  - DataValue
  - ExtensionObject
  - DiagnosticInfo
  - RequestHeader / ResponseHeader

  All spec references: OPC UA Part 6 §5.2.2
  """

  import Bitwise, only: [band: 2, bor: 2]
  import ExOpcUA.Codec.Primitives

  # ── Structs ───────────────────────────────────────────────────────────────────

  defmodule NodeId do
    @moduledoc "OPC UA NodeId — ns + typed identifier."
    @enforce_keys [:ns, :type, :id]
    defstruct [:ns, :type, :id]
    # type: :two_byte | :four_byte | :numeric | :string | :guid | :byte_string
    # id:   integer() | String.t() | binary() (guid/bytestring)

    @type t :: %__MODULE__{}

    @spec numeric(non_neg_integer(), non_neg_integer()) :: t()
    def numeric(ns, id), do: %__MODULE__{ns: ns, type: :numeric, id: id}

    @spec string(non_neg_integer(), String.t()) :: t()
    def string(ns, id), do: %__MODULE__{ns: ns, type: :string, id: id}

    @spec guid(non_neg_integer(), binary()) :: t()
    def guid(ns, id), do: %__MODULE__{ns: ns, type: :guid, id: id}

    # Namespace 0 numeric shorthand — very common for standard nodes
    @spec ns0(non_neg_integer()) :: t()
    def ns0(id), do: %__MODULE__{ns: 0, type: :numeric, id: id}
  end

  defmodule QualifiedName do
    @enforce_keys [:ns, :name]
    defstruct [:ns, :name]
    @type t :: %__MODULE__{}
  end

  defmodule LocalizedText do
    defstruct locale: nil, text: nil
    @type t :: %__MODULE__{}
  end

  defmodule Variant do
    @type t :: %__MODULE__{}
    defstruct type: :null, value: nil, array_dimensions: nil
    # type: atom from @variant_types below
    # value: scalar or list (for arrays)
    # array_dimensions: nil | [integer()] (for multidimensional arrays)
  end

  defmodule DataValue do
    @type t :: %__MODULE__{}
    defstruct [
      :value,               # %Variant{} | nil
      :status_code,         # non_neg_integer() | nil
      :source_timestamp,    # DateTime.t() | nil
      :server_timestamp,    # DateTime.t() | nil
      :source_picoseconds,  # uint16 | nil
      :server_picoseconds   # uint16 | nil
    ]
  end

  defmodule ExtensionObject do
    @type t :: %__MODULE__{}
    defstruct type_id: nil, encoding: :none, body: nil
    # type_id: %NodeId{}, encoding: :none | :binary | :xml, body: binary() | nil
  end

  defmodule DiagnosticInfo do
    @type t :: %__MODULE__{}
    defstruct [
      symbolic_id:        nil,   # int32 index into string table
      namespace_uri:      nil,   # int32
      localized_text:     nil,   # int32
      locale:             nil,   # int32
      additional_info:    nil,   # String.t()
      inner_status_code:  nil,   # uint32
      inner_diagnostic:   nil    # %DiagnosticInfo{} | nil
    ]
  end

  # ── NodeId encoding ───────────────────────────────────────────────────────────
  # Part 6 Table 6-9: encoding byte selects format
  # 0x00 = TwoByte (ns=0, numeric 0..255)
  # 0x01 = FourByte (ns=0..255, numeric 0..65535)
  # 0x02 = Numeric (ns uint16, id uint32)
  # 0x03 = String
  # 0x04 = Guid
  # 0x05 = ByteString

  @spec encode_node_id(NodeId.t()) :: binary()
  def encode_node_id(%NodeId{ns: 0, type: :numeric, id: id}) when id <= 0xFF do
    <<0x00, id::8>>
  end
  def encode_node_id(%NodeId{ns: ns, type: :numeric, id: id})
      when ns <= 0xFF and id <= 0xFFFF do
    <<0x01, ns::8, id::little-16>>
  end
  def encode_node_id(%NodeId{ns: ns, type: :numeric, id: id}) do
    <<0x02, ns::little-16, id::little-32>>
  end
  def encode_node_id(%NodeId{ns: ns, type: :string, id: s}) do
    <<0x03, ns::little-16, encode_string(s)::binary>>
  end
  def encode_node_id(%NodeId{ns: ns, type: :guid, id: g}) do
    <<0x04, ns::little-16, encode_guid(g)::binary>>
  end
  def encode_node_id(%NodeId{ns: ns, type: :byte_string, id: b}) do
    <<0x05, ns::little-16, encode_byte_string(b)::binary>>
  end

  @spec decode_node_id(binary()) :: {NodeId.t(), binary()} | {:error, atom()}
  def decode_node_id(<<0x00, id::8, rest::binary>>) do
    {%NodeId{ns: 0, type: :two_byte, id: id}, rest}
  end
  def decode_node_id(<<0x01, ns::8, id::little-16, rest::binary>>) do
    {%NodeId{ns: ns, type: :four_byte, id: id}, rest}
  end
  def decode_node_id(<<0x02, ns::little-16, id::little-32, rest::binary>>) do
    {%NodeId{ns: ns, type: :numeric, id: id}, rest}
  end
  def decode_node_id(<<0x03, ns::little-16, rest::binary>>) do
    case decode_string(rest) do
      {s, tail} -> {%NodeId{ns: ns, type: :string, id: s}, tail}
      err -> err
    end
  end
  def decode_node_id(<<0x04, ns::little-16, rest::binary>>) do
    case decode_guid(rest) do
      {g, tail} -> {%NodeId{ns: ns, type: :guid, id: g}, tail}
      err -> err
    end
  end
  def decode_node_id(<<0x05, ns::little-16, rest::binary>>) do
    case decode_byte_string(rest) do
      {b, tail} -> {%NodeId{ns: ns, type: :byte_string, id: b}, tail}
      err -> err
    end
  end
  def decode_node_id(_), do: {:error, :truncated}

  # ExpandedNodeId: same as NodeId but encoding byte may have
  # bit 7 (NamespaceUri present) and bit 6 (ServerIndex present) set.
  @spec encode_expanded_node_id(NodeId.t(), String.t() | nil, non_neg_integer() | nil) :: binary()
  def encode_expanded_node_id(%NodeId{} = nid, ns_uri \\ nil, server_index \\ nil) do
    base = encode_node_id(nid)
    <<enc_byte, rest::binary>> = base
    flags  = if(ns_uri,      do: 0x80, else: 0x00)
    flags  = if(server_index && server_index != 0, do: bor(flags, 0x40), else: flags)
    enc    = <<bor(enc_byte, flags), rest::binary>>
    suffix = if(ns_uri, do: encode_string(ns_uri), else: <<>>)
    si     = if(server_index && server_index != 0, do: encode_uint32(server_index), else: <<>>)
    enc <> suffix <> si
  end

  @spec decode_expanded_node_id(binary()) ::
    {{NodeId.t(), String.t() | nil, non_neg_integer() | nil}, binary()} | {:error, atom()}
  def decode_expanded_node_id(<<enc_byte, _::binary>> = data) do
    # Strip the flag bits from the encoding byte before delegating
    stripped = :binary.copy(<<band(enc_byte, 0x3F)>>) <> binary_part(data, 1, byte_size(data) - 1)
    case decode_node_id(stripped) do
      {nid, rest} ->
        {ns_uri, rest} =
          if (band(enc_byte, 0x80)) != 0, do: decode_string(rest), else: {nil, rest}
        {server_index, rest} =
          if (band(enc_byte, 0x40)) != 0, do: decode_uint32(rest), else: {nil, rest}
        {{nid, ns_uri, server_index}, rest}
      err -> err
    end
  end
  def decode_expanded_node_id(_), do: {:error, :truncated}

  # ── QualifiedName ─────────────────────────────────────────────────────────────
  # UInt16 ns_index, then UA String

  @spec encode_qualified_name(QualifiedName.t()) :: binary()
  def encode_qualified_name(%QualifiedName{ns: ns, name: name}) do
    <<ns::little-16, encode_string(name)::binary>>
  end

  @spec decode_qualified_name(binary()) :: {QualifiedName.t(), binary()} | {:error, atom()}
  def decode_qualified_name(<<ns::little-16, rest::binary>>) do
    case decode_string(rest) do
      {name, tail} -> {%QualifiedName{ns: ns, name: name}, tail}
      err -> err
    end
  end
  def decode_qualified_name(_), do: {:error, :truncated}

  # ── LocalizedText ─────────────────────────────────────────────────────────────
  # Encoding byte: bit 0 = locale present, bit 1 = text present

  @spec encode_localized_text(LocalizedText.t()) :: binary()
  def encode_localized_text(%LocalizedText{locale: locale, text: text}) do
    flags  = if(locale, do: 0x01, else: 0x00)
    flags  = if(text,   do: bor(flags, 0x02), else: flags)
    loc_b  = if(locale, do: encode_string(locale), else: <<>>)
    text_b = if(text,   do: encode_string(text),   else: <<>>)
    <<flags::8, loc_b::binary, text_b::binary>>
  end

  @spec decode_localized_text(binary()) :: {LocalizedText.t(), binary()} | {:error, atom()}
  def decode_localized_text(<<flags::8, rest::binary>>) do
    {locale, rest} =
      if (band(flags, 0x01)) != 0, do: decode_string(rest), else: {nil, rest}
    {text, rest} =
      if (band(flags, 0x02)) != 0, do: decode_string(rest), else: {nil, rest}
    {%LocalizedText{locale: locale, text: text}, rest}
  end
  def decode_localized_text(_), do: {:error, :truncated}

  # ── Variant ───────────────────────────────────────────────────────────────────
  # Encoding byte: bits 0-5 = type id, bit 6 = array, bit 7 = array dimensions present
  # Part 6 Table 1 for type ids.

  @variant_type_ids %{
    null:           0,
    boolean:        1,
    sbyte:          2,
    byte:           3,
    int16:          4,
    uint16:         5,
    int32:          6,
    uint32:         7,
    int64:          8,
    uint64:         9,
    float:          10,
    double:         11,
    string:         12,
    date_time:      13,
    guid:           14,
    byte_string:    15,
    xml_element:    16,
    node_id:        17,
    expanded_node_id: 18,
    status_code:    19,
    qualified_name: 20,
    localized_text: 21,
    extension_object: 22,
    data_value:     23,
    variant:        24,
    diagnostic_info: 25
  }

  @variant_ids_type Map.new(@variant_type_ids, fn {k, v} -> {v, k} end)

  @spec encode_variant(Variant.t()) :: binary()
  def encode_variant(%Variant{type: :null}) do
    <<0::8>>
  end
  def encode_variant(%Variant{type: type, value: value, array_dimensions: dims})
      when is_list(value) do
    type_id  = Map.fetch!(@variant_type_ids, type)
    is_multi = dims != nil
    enc_byte = bor(bor(type_id, 0x40), if(is_multi, do: 0x80, else: 0x00))
    items    = encode_array(value, &encode_variant_value(type, &1))
    dims_b   = if is_multi, do: encode_array(dims, &encode_int32/1), else: <<>>
    <<enc_byte::8, items::binary, dims_b::binary>>
  end
  def encode_variant(%Variant{type: type, value: value}) do
    type_id = Map.fetch!(@variant_type_ids, type)
    <<type_id::8, encode_variant_value(type, value)::binary>>
  end

  @spec decode_variant(binary()) :: {Variant.t(), binary()} | {:error, atom()}
  def decode_variant(<<0::8, rest::binary>>) do
    {%Variant{type: :null, value: nil}, rest}
  end
  def decode_variant(<<enc_byte::8, rest::binary>>) do
    type_id  = band(enc_byte, 0x3F)
    is_array = (band(enc_byte, 0x40)) != 0
    has_dims = (band(enc_byte, 0x80)) != 0
    type     = Map.get(@variant_ids_type, type_id, :unknown)

    decoder = &decode_variant_value(type, &1)

    if is_array do
      case decode_array(rest, decoder) do
        {items, rest2} ->
          {dims, rest3} =
            if has_dims do
              case decode_array(rest2, &decode_int32/1) do
                {d, r} -> {d, r}
                _ -> {nil, rest2}
              end
            else
              {nil, rest2}
            end
          {%Variant{type: type, value: items, array_dimensions: dims}, rest3}
        err -> err
      end
    else
      case decoder.(rest) do
        {val, rest2} -> {%Variant{type: type, value: val}, rest2}
        err -> err
      end
    end
  end
  def decode_variant(_), do: {:error, :truncated}

  # Scalar encode/decode dispatch by type atom
  defp encode_variant_value(:boolean,     v), do: encode_boolean(v)
  defp encode_variant_value(:sbyte,       v), do: encode_sbyte(v)
  defp encode_variant_value(:byte,        v), do: encode_byte(v)
  defp encode_variant_value(:int16,       v), do: encode_int16(v)
  defp encode_variant_value(:uint16,      v), do: encode_uint16(v)
  defp encode_variant_value(:int32,       v), do: encode_int32(v)
  defp encode_variant_value(:uint32,      v), do: encode_uint32(v)
  defp encode_variant_value(:int64,       v), do: encode_int64(v)
  defp encode_variant_value(:uint64,      v), do: encode_uint64(v)
  defp encode_variant_value(:float,       v), do: encode_float(v)
  defp encode_variant_value(:double,      v), do: encode_double(v)
  defp encode_variant_value(:string,      v), do: encode_string(v)
  defp encode_variant_value(:xml_element, v), do: encode_string(v)
  defp encode_variant_value(:byte_string, v), do: encode_byte_string(v)
  defp encode_variant_value(:date_time,   v), do: encode_datetime(v)
  defp encode_variant_value(:guid,        v), do: encode_guid(v)
  defp encode_variant_value(:status_code, v), do: encode_status_code(v)
  defp encode_variant_value(:node_id,     v), do: encode_node_id(v)
  defp encode_variant_value(:qualified_name, v), do: encode_qualified_name(v)
  defp encode_variant_value(:localized_text, v), do: encode_localized_text(v)
  defp encode_variant_value(:extension_object, v), do: encode_extension_object(v)
  defp encode_variant_value(:data_value,  v), do: encode_data_value(v)
  defp encode_variant_value(:variant,     v), do: encode_variant(v)

  defp decode_variant_value(:boolean,     b), do: decode_boolean(b)
  defp decode_variant_value(:sbyte,       b), do: decode_sbyte(b)
  defp decode_variant_value(:byte,        b), do: decode_byte(b)
  defp decode_variant_value(:int16,       b), do: decode_int16(b)
  defp decode_variant_value(:uint16,      b), do: decode_uint16(b)
  defp decode_variant_value(:int32,       b), do: decode_int32(b)
  defp decode_variant_value(:uint32,      b), do: decode_uint32(b)
  defp decode_variant_value(:int64,       b), do: decode_int64(b)
  defp decode_variant_value(:uint64,      b), do: decode_uint64(b)
  defp decode_variant_value(:float,       b), do: decode_float(b)
  defp decode_variant_value(:double,      b), do: decode_double(b)
  defp decode_variant_value(:string,      b), do: decode_string(b)
  defp decode_variant_value(:xml_element, b), do: decode_string(b)
  defp decode_variant_value(:byte_string, b), do: decode_byte_string(b)
  defp decode_variant_value(:date_time,   b), do: decode_datetime(b)
  defp decode_variant_value(:guid,        b), do: decode_guid(b)
  defp decode_variant_value(:status_code, b), do: decode_status_code(b)
  defp decode_variant_value(:node_id,     b), do: decode_node_id(b)
  defp decode_variant_value(:qualified_name, b), do: decode_qualified_name(b)
  defp decode_variant_value(:localized_text, b), do: decode_localized_text(b)
  defp decode_variant_value(:extension_object, b), do: decode_extension_object(b)
  defp decode_variant_value(:data_value,  b), do: decode_data_value(b)
  defp decode_variant_value(:variant,     b), do: decode_variant(b)
  defp decode_variant_value(:unknown,     _), do: {:error, :unknown_variant_type}

  # ── DataValue ─────────────────────────────────────────────────────────────────
  # Encoding byte bitmask:
  # bit 0: Value present
  # bit 1: StatusCode present
  # bit 2: SourceTimestamp present
  # bit 3: ServerTimestamp present
  # bit 4: SourcePicoseconds present
  # bit 5: ServerPicoseconds present

  @spec encode_data_value(DataValue.t()) :: binary()
  def encode_data_value(%DataValue{} = dv) do
    flags = 0
    flags = if dv.value,             do: bor(flags, 0x01), else: flags
    flags = if dv.status_code,       do: bor(flags, 0x02), else: flags
    flags = if dv.source_timestamp,  do: bor(flags, 0x04), else: flags
    flags = if dv.server_timestamp,  do: bor(flags, 0x08), else: flags
    flags = if dv.source_picoseconds,do: bor(flags, 0x10), else: flags
    flags = if dv.server_picoseconds,do: bor(flags, 0x20), else: flags

    val_b  = if dv.value,              do: encode_variant(dv.value),             else: <<>>
    sc_b   = if dv.status_code,        do: encode_status_code(dv.status_code),   else: <<>>
    sts_b  = if dv.source_timestamp,   do: encode_datetime(dv.source_timestamp), else: <<>>
    svts_b = if dv.server_timestamp,   do: encode_datetime(dv.server_timestamp), else: <<>>
    sps_b  = if dv.source_picoseconds, do: encode_uint16(dv.source_picoseconds), else: <<>>
    svps_b = if dv.server_picoseconds, do: encode_uint16(dv.server_picoseconds), else: <<>>

    <<flags::8, val_b::binary, sc_b::binary, sts_b::binary,
      svts_b::binary, sps_b::binary, svps_b::binary>>
  end

  @spec decode_data_value(binary()) :: {DataValue.t(), binary()} | {:error, atom()}
  def decode_data_value(<<flags::8, rest::binary>>) do
    {value, rest}             = if (band(flags, 0x01)) != 0, do: decode_variant(rest),    else: {nil, rest}
    {status_code, rest}       = if (band(flags, 0x02)) != 0, do: decode_status_code(rest),else: {nil, rest}
    {source_timestamp, rest}  = if (band(flags, 0x04)) != 0, do: decode_datetime(rest),   else: {nil, rest}
    {server_timestamp, rest}  = if (band(flags, 0x08)) != 0, do: decode_datetime(rest),   else: {nil, rest}
    {source_pico, rest}       = if (band(flags, 0x10)) != 0, do: decode_uint16(rest),     else: {nil, rest}
    {server_pico, rest}       = if (band(flags, 0x20)) != 0, do: decode_uint16(rest),     else: {nil, rest}

    dv = %DataValue{
      value: value,
      status_code: status_code,
      source_timestamp: source_timestamp,
      server_timestamp: server_timestamp,
      source_picoseconds: source_pico,
      server_picoseconds: server_pico
    }
    {dv, rest}
  end
  def decode_data_value(_), do: {:error, :truncated}

  # ── ExtensionObject ───────────────────────────────────────────────────────────
  # TypeId (NodeId), encoding byte (0=none, 1=binary, 2=xml), then body

  @spec encode_extension_object(ExtensionObject.t()) :: binary()
  def encode_extension_object(%ExtensionObject{type_id: nil}) do
    # Null extension object: NodeId(0,0), encoding=0
    <<0x00, 0x00, 0x00>>
  end
  def encode_extension_object(%ExtensionObject{type_id: type_id, encoding: :none}) do
    <<encode_node_id(type_id)::binary, 0x00>>
  end
  def encode_extension_object(%ExtensionObject{type_id: type_id, encoding: :binary, body: body}) do
    body_b = body || <<>>
    <<encode_node_id(type_id)::binary, 0x01,
      byte_size(body_b)::little-32, body_b::binary>>
  end
  def encode_extension_object(%ExtensionObject{type_id: type_id, encoding: :xml, body: body}) do
    <<encode_node_id(type_id)::binary, 0x02, encode_string(body)::binary>>
  end

  @spec decode_extension_object(binary()) :: {ExtensionObject.t(), binary()} | {:error, atom()}
  def decode_extension_object(data) do
    with {type_id, rest} <- decode_node_id(data),
         <<enc::8, rest2::binary>> <- rest do
      case enc do
        0x00 ->
          {%ExtensionObject{type_id: type_id, encoding: :none, body: nil}, rest2}
        0x01 ->
          case rest2 do
            <<len::little-32, body::binary-size(len), tail::binary>> ->
              {%ExtensionObject{type_id: type_id, encoding: :binary, body: body}, tail}
            _ -> {:error, :truncated}
          end
        0x02 ->
          case decode_string(rest2) do
            {xml, tail} ->
              {%ExtensionObject{type_id: type_id, encoding: :xml, body: xml}, tail}
            err -> err
          end
        _ -> {:error, {:unknown_extension_encoding, enc}}
      end
    else
      {:error, _} = err -> err
      _ -> {:error, :truncated}
    end
  end

  # ── DiagnosticInfo ────────────────────────────────────────────────────────────
  # Encoding byte bitmask controls which optional fields follow.

  @spec encode_diagnostic_info(DiagnosticInfo.t() | nil) :: binary()
  def encode_diagnostic_info(nil), do: <<0x00>>
  def encode_diagnostic_info(%DiagnosticInfo{} = di) do
    flags = 0
    flags = if di.symbolic_id,       do: bor(flags, 0x01), else: flags
    flags = if di.namespace_uri,     do: bor(flags, 0x02), else: flags
    flags = if di.localized_text,    do: bor(flags, 0x04), else: flags
    flags = if di.locale,            do: bor(flags, 0x08), else: flags
    flags = if di.additional_info,   do: bor(flags, 0x10), else: flags
    flags = if di.inner_status_code, do: bor(flags, 0x20), else: flags
    flags = if di.inner_diagnostic,  do: bor(flags, 0x40), else: flags

    body = <<>>
    body = if di.symbolic_id,       do: body <> encode_int32(di.symbolic_id),       else: body
    body = if di.namespace_uri,     do: body <> encode_int32(di.namespace_uri),     else: body
    body = if di.localized_text,    do: body <> encode_int32(di.localized_text),    else: body
    body = if di.locale,            do: body <> encode_int32(di.locale),            else: body
    body = if di.additional_info,   do: body <> encode_string(di.additional_info),  else: body
    body = if di.inner_status_code, do: body <> encode_status_code(di.inner_status_code), else: body
    body = if di.inner_diagnostic,  do: body <> encode_diagnostic_info(di.inner_diagnostic), else: body

    <<flags::8, body::binary>>
  end

  @spec decode_diagnostic_info(binary()) :: {DiagnosticInfo.t(), binary()} | {:error, atom()}
  def decode_diagnostic_info(<<flags::8, rest::binary>>) do
    {sym_id,  rest} = if (band(flags, 0x01)) != 0, do: decode_int32(rest),  else: {nil, rest}
    {ns_uri,  rest} = if (band(flags, 0x02)) != 0, do: decode_int32(rest),  else: {nil, rest}
    {loc_txt, rest} = if (band(flags, 0x04)) != 0, do: decode_int32(rest),  else: {nil, rest}
    {locale,  rest} = if (band(flags, 0x08)) != 0, do: decode_int32(rest),  else: {nil, rest}
    {addl,    rest} = if (band(flags, 0x10)) != 0, do: decode_string(rest), else: {nil, rest}
    {isc,     rest} = if (band(flags, 0x20)) != 0, do: decode_uint32(rest), else: {nil, rest}
    {inner,   rest} = if (band(flags, 0x40)) != 0, do: decode_diagnostic_info(rest), else: {nil, rest}

    di = %DiagnosticInfo{
      symbolic_id: sym_id, namespace_uri: ns_uri, localized_text: loc_txt,
      locale: locale, additional_info: addl, inner_status_code: isc,
      inner_diagnostic: inner
    }
    {di, rest}
  end
  def decode_diagnostic_info(_), do: {:error, :truncated}

  # ── RequestHeader ─────────────────────────────────────────────────────────────
  # AuthenticationToken (NodeId), Timestamp (DateTime), RequestHandle (UInt32),
  # ReturnDiagnostics (UInt32), AuditEntryId (String), TimeoutHint (UInt32),
  # AdditionalHeader (ExtensionObject)

  defmodule RequestHeader do
    defstruct [
      auth_token:           nil,   # %NodeId{}
      timestamp:            nil,   # DateTime.t()
      request_handle:       0,     # uint32
      return_diagnostics:   0,     # uint32
      audit_entry_id:       nil,   # String.t() | nil
      timeout_hint:         0,     # uint32 (ms)
      additional_header:    nil    # %ExtensionObject{} | nil
    ]
  end

  defmodule ResponseHeader do
    defstruct [
      timestamp:          nil,   # DateTime.t()
      request_handle:     0,     # uint32
      service_result:     0,     # StatusCode uint32
      service_diagnostics: nil,  # %DiagnosticInfo{}
      string_table:       [],    # [String.t()]
      additional_header:  nil    # %ExtensionObject{} | nil
    ]
  end

  @spec encode_request_header(RequestHeader.t()) :: binary()
  def encode_request_header(%RequestHeader{} = h) do
    auth  = encode_node_id(h.auth_token || %NodeId{ns: 0, type: :two_byte, id: 0})
    ts    = encode_datetime(h.timestamp || DateTime.utc_now())
    rh    = encode_uint32(h.request_handle)
    rd    = encode_uint32(h.return_diagnostics)
    aeid  = encode_string(h.audit_entry_id)
    toh   = encode_uint32(h.timeout_hint)
    addl  = encode_extension_object(h.additional_header || %ExtensionObject{})
    auth <> ts <> rh <> rd <> aeid <> toh <> addl
  end

  @spec decode_request_header(binary()) :: {RequestHeader.t(), binary()} | {:error, atom()}
  def decode_request_header(data) do
    with {auth,  r1} <- decode_node_id(data),
         {ts,    r2} <- decode_datetime(r1),
         {rh,    r3} <- decode_uint32(r2),
         {rd,    r4} <- decode_uint32(r3),
         {aeid,  r5} <- decode_string(r4),
         {toh,   r6} <- decode_uint32(r5),
         {:ok, addl, r7} <- ok2(decode_extension_object(r6)) do
      h = %RequestHeader{
        auth_token: auth, timestamp: ts, request_handle: rh,
        return_diagnostics: rd, audit_entry_id: aeid,
        timeout_hint: toh, additional_header: addl
      }
      {h, r7}
    end
  end

  @spec encode_response_header(ResponseHeader.t()) :: binary()
  def encode_response_header(%ResponseHeader{} = h) do
    ts    = encode_datetime(h.timestamp || DateTime.utc_now())
    rh    = encode_uint32(h.request_handle)
    sr    = encode_status_code(h.service_result)
    diag  = encode_diagnostic_info(h.service_diagnostics)
    strs  = encode_array(h.string_table || [], &encode_string/1)
    addl  = encode_extension_object(h.additional_header || %ExtensionObject{})
    ts <> rh <> sr <> diag <> strs <> addl
  end

  @spec decode_response_header(binary()) :: {ResponseHeader.t(), binary()} | {:error, atom()}
  def decode_response_header(data) do
    with {ts,   r1} <- decode_datetime(data),
         {rh,   r2} <- decode_uint32(r1),
         {sr,   r3} <- decode_status_code(r2),
         {diag, r4} <- decode_diagnostic_info(r3),
         {strs, r5} <- decode_array(r4, &decode_string/1),
         {:ok, addl, r6} <- ok2(decode_extension_object(r5)) do
      h = %ResponseHeader{
        timestamp: ts, request_handle: rh, service_result: sr,
        service_diagnostics: diag, string_table: strs || [],
        additional_header: addl
      }
      {h, r6}
    end
  end

  # ── Convenience constructors ──────────────────────────────────────────────────

  @spec good_data_value(Variant.t()) :: DataValue.t()
  def good_data_value(variant) do
    %DataValue{
      value: variant,
      status_code: 0,
      server_timestamp: DateTime.utc_now()
    }
  end

  @spec double_variant(float()) :: Variant.t()
  def double_variant(v), do: %Variant{type: :double, value: v}

  @spec string_variant(String.t()) :: Variant.t()
  def string_variant(v), do: %Variant{type: :string, value: v}

  @spec uint32_variant(non_neg_integer()) :: Variant.t()
  def uint32_variant(v), do: %Variant{type: :uint32, value: v}

  # Guard for with-pipelines: reject {:error, _} tuples that would otherwise
  # match {val, rest} patterns and silently corrupt subsequent decode steps.
  @spec ok2({term(), binary()} | {:error, term()}) ::
    {:ok, term(), binary()} | {:error, term()}
  def ok2({:error, _} = err), do: err
  def ok2({val, rest}),        do: {:ok, val, rest}
end
