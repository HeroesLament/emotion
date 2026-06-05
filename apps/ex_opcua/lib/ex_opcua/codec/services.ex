defmodule ExOpcUA.Codec.Services do
  @moduledoc """
  Binary encode/decode for all OPC UA service request/response structures.

  ## TypeId convention
  Every service message on the wire is preceded by a NodeId (the binary
  encoding TypeId, ns=0, numeric). The Connection layer prepends/strips this;
  these functions encode/decode only the **body** that follows.

  Use `type_id/1` and `from_type_id/1` to map between service atoms and wire ids.

  ## Service atoms
  `:get_endpoints_req`, `:get_endpoints_res`,
  `:find_servers_req`, `:find_servers_res`,
  `:open_secure_channel_req`, `:open_secure_channel_res`,
  `:close_secure_channel_req`, `:close_secure_channel_res`,
  `:create_session_req`, `:create_session_res`,
  `:activate_session_req`, `:activate_session_res`,
  `:close_session_req`, `:close_session_res`,
  `:browse_req`, `:browse_res`,
  `:browse_next_req`, `:browse_next_res`,
  `:translate_browse_paths_req`, `:translate_browse_paths_res`,
  `:read_req`, `:read_res`,
  `:write_req`, `:write_res`,
  `:create_subscription_req`, `:create_subscription_res`,
  `:modify_subscription_req`, `:modify_subscription_res`,
  `:set_publishing_mode_req`, `:set_publishing_mode_res`,
  `:create_monitored_items_req`, `:create_monitored_items_res`,
  `:delete_monitored_items_req`, `:delete_monitored_items_res`,
  `:publish_req`, `:publish_res`,
  `:republish_req`, `:republish_res`,
  `:delete_subscriptions_req`, `:delete_subscriptions_res`,
  `:service_fault`
  """

  import ExOpcUA.Codec.Primitives
  import ExOpcUA.Codec.Types

  alias ExOpcUA.Codec.Types.{
    NodeId, QualifiedName, LocalizedText, Variant, DataValue,
    ExtensionObject, DiagnosticInfo, RequestHeader, ResponseHeader
  }

  # ── TypeId mapping (ns=0 binary encoding ids) ────────────────────────────────
  # Source: OPC UA NodeIds.csv / Part 6 Annex A
  # Pattern: ServiceName_Encoding_DefaultBinary

  @type_ids %{
    find_servers_req:              422,
    find_servers_res:              425,
    get_endpoints_req:             428,
    get_endpoints_res:             431,
    open_secure_channel_req:       446,
    open_secure_channel_res:       449,
    close_secure_channel_req:      452,
    close_secure_channel_res:      455,
    create_session_req:            459,
    create_session_res:            462,
    activate_session_req:          465,
    activate_session_res:          468,
    close_session_req:             471,
    close_session_res:             474,
    browse_req:                    525,
    browse_res:                    528,
    browse_next_req:               531,
    browse_next_res:               534,
    translate_browse_paths_req:    552,
    translate_browse_paths_res:    555,
    read_req:                      629,
    read_res:                      632,
    write_req:                     671,
    write_res:                     674,
    create_subscription_req:       787,
    create_subscription_res:       790,
    modify_subscription_req:       793,
    modify_subscription_res:       796,
    set_publishing_mode_req:       797,
    set_publishing_mode_res:       800,
    create_monitored_items_req:    751,
    create_monitored_items_res:    754,
    modify_monitored_items_req:    757,
    modify_monitored_items_res:    760,
    delete_monitored_items_req:    769,
    delete_monitored_items_res:    772,
    publish_req:                   826,
    publish_res:                   829,
    republish_req:                 832,
    republish_res:                 835,
    delete_subscriptions_req:      845,
    delete_subscriptions_res:      848,
    service_fault:                 395
  }

  @ids_type Map.new(@type_ids, fn {k, v} -> {v, k} end)

  @spec type_id(atom()) :: non_neg_integer() | nil
  def type_id(service), do: Map.get(@type_ids, service)

  @spec from_type_id(non_neg_integer()) :: atom() | nil
  def from_type_id(id), do: Map.get(@ids_type, id)

  @spec all_type_ids() :: %{atom() => non_neg_integer()}
  def all_type_ids, do: @type_ids

  # ── Encode/decode dispatch ────────────────────────────────────────────────────

  @spec encode(atom(), map()) :: binary() | {:error, atom()}
  def encode(service, params), do: do_encode(service, params)

  @spec decode(atom(), binary()) :: {:ok, map()} | {:error, atom()}
  def decode(service, body), do: do_decode(service, body)

  # ── Common sub-structures ─────────────────────────────────────────────────────

  # ApplicationDescription
  defmodule ApplicationDescription do
    defstruct [
      application_uri:      nil,   # String
      product_uri:          nil,   # String
      application_name:     nil,   # LocalizedText
      application_type:     0,     # 0=Server,1=Client,2=ClientServer,3=DiscoveryServer
      gateway_server_uri:   nil,
      discovery_profile_uri: nil,
      discovery_urls:       []
    ]
  end

  defp encode_app_desc(%ApplicationDescription{} = a) do
    encode_string(a.application_uri) <>
    encode_string(a.product_uri) <>
    encode_localized_text(a.application_name || %LocalizedText{}) <>
    encode_uint32(a.application_type) <>
    encode_string(a.gateway_server_uri) <>
    encode_string(a.discovery_profile_uri) <>
    encode_array(a.discovery_urls || [], &encode_string/1)
  end

  defp decode_app_desc(data) do
    with {app_uri,   r1} <- decode_string(data),
         {prod_uri,  r2} <- decode_string(r1),
         {app_name,  r3} <- decode_localized_text(r2),
         {app_type,  r4} <- decode_uint32(r3),
         {gw_uri,    r5} <- decode_string(r4),
         {disc_prof, r6} <- decode_string(r5),
         {disc_urls, r7} <- decode_array(r6, &decode_string/1) do
      desc = %ApplicationDescription{
        application_uri: app_uri, product_uri: prod_uri,
        application_name: app_name, application_type: app_type,
        gateway_server_uri: gw_uri, discovery_profile_uri: disc_prof,
        discovery_urls: disc_urls || []
      }
      {desc, r7}
    end
  end

  # UserTokenPolicy
  defmodule UserTokenPolicy do
    defstruct [
      policy_id:          nil,   # String
      token_type:         0,     # 0=Anonymous,1=UserName,2=Certificate,3=IssuedToken
      issued_token_type:  nil,
      issuer_endpoint_url: nil,
      security_policy_uri: nil
    ]
  end

  defp encode_user_token_policy(%UserTokenPolicy{} = p) do
    encode_string(p.policy_id) <>
    encode_uint32(p.token_type) <>
    encode_string(p.issued_token_type) <>
    encode_string(p.issuer_endpoint_url) <>
    encode_string(p.security_policy_uri)
  end

  defp decode_user_token_policy(data) do
    with {pid,    r1} <- decode_string(data),
         {ttype,  r2} <- decode_uint32(r1),
         {ittpe,  r3} <- decode_string(r2),
         {iepurl, r4} <- decode_string(r3),
         {spu,    r5} <- decode_string(r4) do
      p = %UserTokenPolicy{
        policy_id: pid, token_type: ttype,
        issued_token_type: ittpe, issuer_endpoint_url: iepurl,
        security_policy_uri: spu
      }
      {p, r5}
    end
  end

  # EndpointDescription
  defmodule EndpointDescription do
    defstruct [
      endpoint_url:          nil,
      server:                nil,   # %ApplicationDescription{}
      server_certificate:    nil,   # binary
      security_mode:         1,     # 1=None,2=Sign,3=SignAndEncrypt
      security_policy_uri:   nil,
      user_identity_tokens:  [],
      transport_profile_uri: nil,
      security_level:        0
    ]
  end

  @ua_transport_profile "http://opcfoundation.org/UA-Profile/Transport/uatcp-uasc-uabinary"

  defp encode_endpoint_desc(%EndpointDescription{} = e) do
    encode_string(e.endpoint_url) <>
    encode_app_desc(e.server || %ApplicationDescription{}) <>
    encode_byte_string(e.server_certificate) <>
    encode_uint32(e.security_mode) <>
    encode_string(e.security_policy_uri) <>
    encode_array(e.user_identity_tokens || [], &encode_user_token_policy/1) <>
    encode_string(e.transport_profile_uri || @ua_transport_profile) <>
    encode_byte(e.security_level)
  end

  defp decode_endpoint_desc(data) do
    with {url,     r1} <- decode_string(data),
         {server,  r2} <- decode_app_desc(r1),
         {cert,    r3} <- decode_byte_string(r2),
         {sec_mode,r4} <- decode_uint32(r3),
         {sec_pol, r5} <- decode_string(r4),
         {tokens,  r6} <- decode_array(r5, &decode_user_token_policy/1),
         {tp_uri,  r7} <- decode_string(r6),
         {sec_lvl, r8} <- decode_byte(r7) do
      e = %EndpointDescription{
        endpoint_url: url, server: server, server_certificate: cert,
        security_mode: sec_mode, security_policy_uri: sec_pol,
        user_identity_tokens: tokens || [],
        transport_profile_uri: tp_uri, security_level: sec_lvl
      }
      {e, r8}
    end
  end

  # SignatureData
  defmodule SignatureData do
    defstruct algorithm: nil, signature: nil
  end

  defp encode_signature(%SignatureData{} = s) do
    encode_string(s.algorithm) <> encode_byte_string(s.signature)
  end

  defp decode_signature(data) do
    with {alg, r1} <- decode_string(data),
         {sig, r2} <- decode_byte_string(r1) do
      {%SignatureData{algorithm: alg, signature: sig}, r2}
    end
  end

  # ── OpenSecureChannel ─────────────────────────────────────────────────────────
  # SecurityTokenRequestType: 0=Issue, 1=Renew

  defmodule OpenSecureChannelRequest do
    defstruct [
      request_header:           nil,
      client_protocol_version:  0,
      request_type:             0,    # 0=Issue, 1=Renew
      security_mode:            1,    # 1=None
      client_nonce:             nil,
      requested_lifetime:       3_600_000  # ms
    ]
  end

  defmodule OpenSecureChannelResponse do
    defstruct [
      response_header:          nil,
      server_protocol_version:  0,
      security_token:           nil,   # %ChannelSecurityToken{}
      server_nonce:             nil
    ]
  end

  defmodule ChannelSecurityToken do
    defstruct [
      channel_id:       0,
      token_id:         0,
      created_at:       nil,
      revised_lifetime: 3_600_000
    ]
  end

  defp encode_channel_security_token(%ChannelSecurityToken{} = t) do
    encode_uint32(t.channel_id) <>
    encode_uint32(t.token_id) <>
    encode_datetime(t.created_at || DateTime.utc_now()) <>
    encode_uint32(t.revised_lifetime)
  end

  defp decode_channel_security_token(data) do
    with {ch_id,   r1} <- decode_uint32(data),
         {tok_id,  r2} <- decode_uint32(r1),
         {created, r3} <- decode_datetime(r2),
         {life,    r4} <- decode_uint32(r3) do
      {%ChannelSecurityToken{
        channel_id: ch_id, token_id: tok_id,
        created_at: created, revised_lifetime: life
      }, r4}
    end
  end

  defp do_encode(:open_secure_channel_req, %OpenSecureChannelRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_uint32(r.client_protocol_version) <>
    encode_uint32(r.request_type) <>
    encode_uint32(r.security_mode) <>
    encode_byte_string(r.client_nonce) <>
    encode_uint32(r.requested_lifetime)
  end

  defp do_decode(:open_secure_channel_req, data) do
    with {hdr,   r1} <- decode_request_header(data),
         {cpv,   r2} <- decode_uint32(r1),
         {rtype, r3} <- decode_uint32(r2),
         {smode, r4} <- decode_uint32(r3),
         {nonce, r5} <- decode_byte_string(r4),
         {life,  r6} <- decode_uint32(r5) do
      {:ok, %OpenSecureChannelRequest{
        request_header: hdr, client_protocol_version: cpv,
        request_type: rtype, security_mode: smode,
        client_nonce: nonce, requested_lifetime: life
      }, r6}
    end
  end

  defp do_encode(:open_secure_channel_res, %OpenSecureChannelResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_uint32(r.server_protocol_version) <>
    encode_channel_security_token(r.security_token || %ChannelSecurityToken{}) <>
    encode_byte_string(r.server_nonce)
  end

  defp do_decode(:open_secure_channel_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {spv,   r2} <- decode_uint32(r1),
         {token, r3} <- decode_channel_security_token(r2),
         {nonce, r4} <- decode_byte_string(r3) do
      {:ok, %OpenSecureChannelResponse{
        response_header: hdr, server_protocol_version: spv,
        security_token: token, server_nonce: nonce
      }, r4}
    end
  end

  defp do_encode(:close_secure_channel_req, %{request_header: hdr}) do
    encode_request_header(hdr || %RequestHeader{})
  end
  defp do_decode(:close_secure_channel_req, data) do
    with {hdr, rest} <- decode_request_header(data) do
      {:ok, %{request_header: hdr}, rest}
    end
  end

  defp do_encode(:close_secure_channel_res, %{response_header: hdr}) do
    encode_response_header(hdr || %ResponseHeader{})
  end
  defp do_decode(:close_secure_channel_res, data) do
    with {hdr, rest} <- decode_response_header(data) do
      {:ok, %{response_header: hdr}, rest}
    end
  end

  # ── GetEndpoints ──────────────────────────────────────────────────────────────

  defmodule GetEndpointsRequest do
    defstruct [request_header: nil, endpoint_url: nil, locale_ids: [], profile_uris: []]
  end

  defmodule GetEndpointsResponse do
    defstruct [response_header: nil, endpoints: []]
  end

  defp do_encode(:get_endpoints_req, %GetEndpointsRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_string(r.endpoint_url) <>
    encode_array(r.locale_ids || [], &encode_string/1) <>
    encode_array(r.profile_uris || [], &encode_string/1)
  end

  defp do_decode(:get_endpoints_req, data) do
    with {hdr,     r1} <- decode_request_header(data),
         {ep_url,  r2} <- decode_string(r1),
         {locales, r3} <- decode_array(r2, &decode_string/1),
         {profiles,r4} <- decode_array(r3, &decode_string/1) do
      {:ok, %GetEndpointsRequest{
        request_header: hdr, endpoint_url: ep_url,
        locale_ids: locales || [], profile_uris: profiles || []
      }, r4}
    end
  end

  defp do_encode(:get_endpoints_res, %GetEndpointsResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_array(r.endpoints || [], &encode_endpoint_desc/1)
  end

  defp do_decode(:get_endpoints_res, data) do
    with {hdr, r1} <- decode_response_header(data),
         {eps, r2} <- decode_array(r1, &decode_endpoint_desc/1) do
      {:ok, %GetEndpointsResponse{response_header: hdr, endpoints: eps || []}, r2}
    end
  end

  # ── FindServers ───────────────────────────────────────────────────────────────

  defmodule FindServersRequest do
    defstruct [request_header: nil, endpoint_url: nil, locale_ids: [], server_uris: []]
  end

  defmodule FindServersResponse do
    defstruct [response_header: nil, servers: []]
  end

  defp do_encode(:find_servers_req, %FindServersRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_string(r.endpoint_url) <>
    encode_array(r.locale_ids || [], &encode_string/1) <>
    encode_array(r.server_uris || [], &encode_string/1)
  end

  defp do_decode(:find_servers_req, data) do
    with {hdr,      r1} <- decode_request_header(data),
         {ep_url,   r2} <- decode_string(r1),
         {locales,  r3} <- decode_array(r2, &decode_string/1),
         {srv_uris, r4} <- decode_array(r3, &decode_string/1) do
      {:ok, %FindServersRequest{
        request_header: hdr, endpoint_url: ep_url,
        locale_ids: locales || [], server_uris: srv_uris || []
      }, r4}
    end
  end

  defp do_encode(:find_servers_res, %FindServersResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_array(r.servers || [], &encode_app_desc/1)
  end

  defp do_decode(:find_servers_res, data) do
    with {hdr,  r1} <- decode_response_header(data),
         {srvs, r2} <- decode_array(r1, &decode_app_desc/1) do
      {:ok, %FindServersResponse{response_header: hdr, servers: srvs || []}, r2}
    end
  end

  # ── CreateSession ─────────────────────────────────────────────────────────────

  defmodule CreateSessionRequest do
    defstruct [
      request_header:           nil,
      client_description:       nil,
      server_uri:               nil,
      endpoint_url:             nil,
      session_name:             nil,
      client_nonce:             nil,
      client_certificate:       nil,
      requested_session_timeout: 1_200_000.0,
      max_response_message_size: 0
    ]
  end

  defmodule CreateSessionResponse do
    defstruct [
      response_header:           nil,
      session_id:                nil,
      authentication_token:      nil,
      revised_session_timeout:   1_200_000.0,
      server_nonce:              nil,
      server_certificate:        nil,
      server_endpoints:          [],
      server_software_certificates: [],
      server_signature:          nil,
      max_request_message_size:  0
    ]
  end

  defp do_encode(:create_session_req, %CreateSessionRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_app_desc(r.client_description || %ApplicationDescription{}) <>
    encode_string(r.server_uri) <>
    encode_string(r.endpoint_url) <>
    encode_string(r.session_name) <>
    encode_byte_string(r.client_nonce) <>
    encode_byte_string(r.client_certificate) <>
    encode_double(r.requested_session_timeout) <>
    encode_uint32(r.max_response_message_size)
  end

  defp do_decode(:create_session_req, data) do
    with {hdr,     r1} <- decode_request_header(data),
         {cli_desc,r2} <- decode_app_desc(r1),
         {srv_uri, r3} <- decode_string(r2),
         {ep_url,  r4} <- decode_string(r3),
         {ses_name,r5} <- decode_string(r4),
         {nonce,   r6} <- decode_byte_string(r5),
         {cert,    r7} <- decode_byte_string(r6),
         {timeout, r8} <- decode_double(r7),
         {max_msg, r9} <- decode_uint32(r8) do
      {:ok, %CreateSessionRequest{
        request_header: hdr, client_description: cli_desc,
        server_uri: srv_uri, endpoint_url: ep_url,
        session_name: ses_name, client_nonce: nonce,
        client_certificate: cert, requested_session_timeout: timeout,
        max_response_message_size: max_msg
      }, r9}
    end
  end

  defp do_encode(:create_session_res, %CreateSessionResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_node_id(r.session_id || NodeId.ns0(0)) <>
    encode_node_id(r.authentication_token || NodeId.ns0(0)) <>
    encode_double(r.revised_session_timeout) <>
    encode_byte_string(r.server_nonce) <>
    encode_byte_string(r.server_certificate) <>
    encode_array(r.server_endpoints || [], &encode_endpoint_desc/1) <>
    encode_array([], fn x -> x end) <>   # server_software_certificates (deprecated, empty array)
    encode_signature(r.server_signature || %SignatureData{}) <>
    encode_uint32(r.max_request_message_size)
  end

  defp do_decode(:create_session_res, data) do
    with {hdr,     r1}  <- decode_response_header(data),
         {ses_id,  r2}  <- decode_node_id(r1),
         {auth_tok,r3}  <- decode_node_id(r2),
         {timeout, r4}  <- decode_double(r3),
         {nonce,   r5}  <- decode_byte_string(r4),
         {cert,    r6}  <- decode_byte_string(r5),
         {eps,     r7}  <- decode_array(r6, &decode_endpoint_desc/1),
         {_certs,  r8}  <- decode_array(r7, &decode_extension_object/1),
         {sig,     r9}  <- decode_signature(r8),
         {max_msg, r10} <- decode_uint32(r9) do
      {:ok, %CreateSessionResponse{
        response_header: hdr, session_id: ses_id,
        authentication_token: auth_tok, revised_session_timeout: timeout,
        server_nonce: nonce, server_certificate: cert,
        server_endpoints: eps || [], server_signature: sig,
        max_request_message_size: max_msg
      }, r10}
    end
  end

  # ── ActivateSession ───────────────────────────────────────────────────────────

  defmodule ActivateSessionRequest do
    defstruct [
      request_header:             nil,
      client_signature:           nil,
      client_software_certificates: [],
      locale_ids:                 [],
      user_identity_token:        nil,   # ExtensionObject (AnonymousIdentityToken etc.)
      user_token_signature:       nil
    ]
  end

  defmodule ActivateSessionResponse do
    defstruct [
      response_header:  nil,
      server_nonce:     nil,
      results:          [],
      diagnostic_infos: []
    ]
  end

  defp do_encode(:activate_session_req, %ActivateSessionRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_signature(r.client_signature || %SignatureData{}) <>
    encode_array([], fn x -> x end) <>   # client_software_certificates (deprecated)
    encode_array(r.locale_ids || [], &encode_string/1) <>
    encode_extension_object(r.user_identity_token || anonymous_identity_token()) <>
    encode_signature(r.user_token_signature || %SignatureData{})
  end

  defp do_decode(:activate_session_req, data) do
    with {hdr,    r1} <- decode_request_header(data),
         {sig,    r2} <- decode_signature(r1),
         {_certs, r3} <- decode_array(r2, &decode_extension_object/1),
         {locs,   r4} <- decode_array(r3, &decode_string/1),
         {token,  r5} <- decode_extension_object(r4),
         {tok_sig,r6} <- decode_signature(r5) do
      {:ok, %ActivateSessionRequest{
        request_header: hdr, client_signature: sig,
        locale_ids: locs || [], user_identity_token: token,
        user_token_signature: tok_sig
      }, r6}
    end
  end

  defp do_encode(:activate_session_res, %ActivateSessionResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_byte_string(r.server_nonce) <>
    encode_array(r.results || [], &encode_status_code/1) <>
    encode_array(r.diagnostic_infos || [], &encode_diagnostic_info/1)
  end

  defp do_decode(:activate_session_res, data) do
    with {hdr,    r1} <- decode_response_header(data),
         {nonce,  r2} <- decode_byte_string(r1),
         {res,    r3} <- decode_array(r2, &decode_status_code/1),
         {diags,  r4} <- decode_array(r3, &decode_diagnostic_info/1) do
      {:ok, %ActivateSessionResponse{
        response_header: hdr, server_nonce: nonce,
        results: res || [], diagnostic_infos: diags || []
      }, r4}
    end
  end

  # ── CloseSession ──────────────────────────────────────────────────────────────

  defp do_encode(:close_session_req, %{request_header: hdr, delete_subscriptions: del}) do
    encode_request_header(hdr || %RequestHeader{}) <>
    encode_boolean(del != false)
  end
  defp do_decode(:close_session_req, data) do
    with {hdr, r1} <- decode_request_header(data),
         {del, r2} <- decode_boolean(r1) do
      {:ok, %{request_header: hdr, delete_subscriptions: del}, r2}
    end
  end

  defp do_encode(:close_session_res, %{response_header: hdr}) do
    encode_response_header(hdr || %ResponseHeader{})
  end
  defp do_decode(:close_session_res, data) do
    with {hdr, rest} <- decode_response_header(data) do
      {:ok, %{response_header: hdr}, rest}
    end
  end

  # ── Browse ────────────────────────────────────────────────────────────────────

  defmodule ViewDescription do
    defstruct [view_id: nil, timestamp: nil, view_version: 0]
  end

  defmodule BrowseDescription do
    defstruct [
      node_id:            nil,
      browse_direction:   0,   # 0=Forward,1=Inverse,2=Both
      reference_type_id:  nil,
      include_subtypes:   true,
      node_class_mask:    0,   # 0=all
      result_mask:        63   # all reference fields
    ]
  end

  defmodule ReferenceDescription do
    defstruct [
      reference_type_id:  nil,
      is_forward:         true,
      node_id:            nil,   # ExpandedNodeId
      browse_name:        nil,
      display_name:       nil,
      node_class:         0,
      type_definition:    nil
    ]
  end

  defmodule BrowseResult do
    defstruct [status_code: 0, continuation_point: nil, references: []]
  end

  defmodule BrowseRequest do
    defstruct [request_header: nil, view: nil, max_references_per_node: 0, nodes_to_browse: []]
  end

  defmodule BrowseResponse do
    defstruct [response_header: nil, results: [], diagnostic_infos: []]
  end

  defp encode_view_desc(%ViewDescription{} = v) do
    encode_node_id(v.view_id || NodeId.ns0(0)) <>
    encode_datetime(v.timestamp) <>
    encode_uint32(v.view_version)
  end

  defp decode_view_desc(data) do
    with {vid, r1} <- decode_node_id(data),
         {ts,  r2} <- decode_datetime(r1),
         {ver, r3} <- decode_uint32(r2) do
      {%ViewDescription{view_id: vid, timestamp: ts, view_version: ver}, r3}
    end
  end

  defp encode_browse_desc(%BrowseDescription{} = b) do
    encode_node_id(b.node_id || NodeId.ns0(0)) <>
    encode_uint32(b.browse_direction) <>
    encode_node_id(b.reference_type_id || NodeId.ns0(0)) <>
    encode_boolean(b.include_subtypes) <>
    encode_uint32(b.node_class_mask) <>
    encode_uint32(b.result_mask)
  end

  defp decode_browse_desc(data) do
    with {nid,     r1} <- decode_node_id(data),
         {bdir,    r2} <- decode_uint32(r1),
         {ref_tid, r3} <- decode_node_id(r2),
         {incl_st, r4} <- decode_boolean(r3),
         {ncmask,  r5} <- decode_uint32(r4),
         {rmask,   r6} <- decode_uint32(r5) do
      {%BrowseDescription{
        node_id: nid, browse_direction: bdir, reference_type_id: ref_tid,
        include_subtypes: incl_st, node_class_mask: ncmask, result_mask: rmask
      }, r6}
    end
  end

  defp encode_ref_desc(%ReferenceDescription{} = r) do
    encode_node_id(r.reference_type_id || NodeId.ns0(0)) <>
    encode_boolean(r.is_forward) <>
    encode_expanded_node_id(r.node_id || NodeId.ns0(0)) <>
    encode_qualified_name(r.browse_name || %QualifiedName{ns: 0, name: nil}) <>
    encode_localized_text(r.display_name || %LocalizedText{}) <>
    encode_uint32(r.node_class) <>
    encode_expanded_node_id(r.type_definition || NodeId.ns0(0))
  end

  defp decode_ref_desc(data) do
    with {ref_tid,  r1} <- decode_node_id(data),
         {is_fwd,   r2} <- decode_boolean(r1),
         {{nid,_,_},r3} <- decode_expanded_node_id(r2),
         {bn,       r4} <- decode_qualified_name(r3),
         {dn,       r5} <- decode_localized_text(r4),
         {ncls,     r6} <- decode_uint32(r5),
         {{tdef,_,_},r7}<- decode_expanded_node_id(r6) do
      {%ReferenceDescription{
        reference_type_id: ref_tid, is_forward: is_fwd, node_id: nid,
        browse_name: bn, display_name: dn, node_class: ncls, type_definition: tdef
      }, r7}
    end
  end

  defp encode_browse_result(%BrowseResult{} = r) do
    encode_status_code(r.status_code) <>
    encode_byte_string(r.continuation_point) <>
    encode_array(r.references || [], &encode_ref_desc/1)
  end

  defp decode_browse_result(data) do
    with {sc,    r1} <- decode_status_code(data),
         {cp,    r2} <- decode_byte_string(r1),
         {refs,  r3} <- decode_array(r2, &decode_ref_desc/1) do
      {%BrowseResult{status_code: sc, continuation_point: cp, references: refs || []}, r3}
    end
  end

  defp do_encode(:browse_req, %BrowseRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_view_desc(r.view || %ViewDescription{}) <>
    encode_uint32(r.max_references_per_node) <>
    encode_array(r.nodes_to_browse || [], &encode_browse_desc/1)
  end

  defp do_decode(:browse_req, data) do
    with {hdr,   r1} <- decode_request_header(data),
         {view,  r2} <- decode_view_desc(r1),
         {maxr,  r3} <- decode_uint32(r2),
         {nodes, r4} <- decode_array(r3, &decode_browse_desc/1) do
      {:ok, %BrowseRequest{
        request_header: hdr, view: view,
        max_references_per_node: maxr, nodes_to_browse: nodes || []
      }, r4}
    end
  end

  defp do_encode(:browse_res, %BrowseResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_array(r.results || [], &encode_browse_result/1) <>
    encode_array(r.diagnostic_infos || [], &encode_diagnostic_info/1)
  end

  defp do_decode(:browse_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {res,   r2} <- decode_array(r1, &decode_browse_result/1),
         {diags, r3} <- decode_array(r2, &decode_diagnostic_info/1) do
      {:ok, %BrowseResponse{
        response_header: hdr, results: res || [], diagnostic_infos: diags || []
      }, r3}
    end
  end

  # BrowseNext
  defp do_encode(:browse_next_req, %{request_header: hdr, release_continuation_points: rel, continuation_points: cps}) do
    encode_request_header(hdr || %RequestHeader{}) <>
    encode_boolean(rel) <>
    encode_array(cps || [], &encode_byte_string/1)
  end
  defp do_decode(:browse_next_req, data) do
    with {hdr, r1} <- decode_request_header(data),
         {rel, r2} <- decode_boolean(r1),
         {cps, r3} <- decode_array(r2, &decode_byte_string/1) do
      {:ok, %{request_header: hdr, release_continuation_points: rel, continuation_points: cps || []}, r3}
    end
  end

  defp do_encode(:browse_next_res, %{response_header: hdr, results: res, diagnostic_infos: diags}) do
    encode_response_header(hdr || %ResponseHeader{}) <>
    encode_array(res || [], &encode_browse_result/1) <>
    encode_array(diags || [], &encode_diagnostic_info/1)
  end
  defp do_decode(:browse_next_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {res,   r2} <- decode_array(r1, &decode_browse_result/1),
         {diags, r3} <- decode_array(r2, &decode_diagnostic_info/1) do
      {:ok, %{response_header: hdr, results: res || [], diagnostic_infos: diags || []}, r3}
    end
  end

  # ── Read ──────────────────────────────────────────────────────────────────────
  # TimestampsToReturn: 0=Source, 1=Server, 2=Both, 3=Neither

  defmodule ReadValueId do
    defstruct [node_id: nil, attribute_id: 13, index_range: nil, data_encoding: nil]
    # attribute_id 13 = Value (most common)
  end

  defmodule ReadRequest do
    defstruct [request_header: nil, max_age: 0.0, timestamps_to_return: 2, nodes_to_read: []]
  end

  defmodule ReadResponse do
    defstruct [response_header: nil, results: [], diagnostic_infos: []]
  end

  defp encode_read_value_id(%ReadValueId{} = r) do
    encode_node_id(r.node_id || NodeId.ns0(0)) <>
    encode_uint32(r.attribute_id) <>
    encode_string(r.index_range) <>
    encode_qualified_name(r.data_encoding || %QualifiedName{ns: 0, name: nil})
  end

  defp decode_read_value_id(data) do
    with {nid,     r1} <- decode_node_id(data),
         {attr_id, r2} <- decode_uint32(r1),
         {idx_rng, r3} <- decode_string(r2),
         {enc,     r4} <- decode_qualified_name(r3) do
      {%ReadValueId{
        node_id: nid, attribute_id: attr_id,
        index_range: idx_rng, data_encoding: enc
      }, r4}
    end
  end

  defp do_encode(:read_req, %ReadRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_double(r.max_age) <>
    encode_uint32(r.timestamps_to_return) <>
    encode_array(r.nodes_to_read || [], &encode_read_value_id/1)
  end

  defp do_decode(:read_req, data) do
    with {hdr,   r1} <- decode_request_header(data),
         {age,   r2} <- decode_double(r1),
         {tsr,   r3} <- decode_uint32(r2),
         {nodes, r4} <- decode_array(r3, &decode_read_value_id/1) do
      {:ok, %ReadRequest{
        request_header: hdr, max_age: age,
        timestamps_to_return: tsr, nodes_to_read: nodes || []
      }, r4}
    end
  end

  defp do_encode(:read_res, %ReadResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_array(r.results || [], &encode_data_value/1) <>
    encode_array(r.diagnostic_infos || [], &encode_diagnostic_info/1)
  end

  defp do_decode(:read_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {res,   r2} <- decode_array(r1, &decode_data_value/1),
         {diags, r3} <- decode_array(r2, &decode_diagnostic_info/1) do
      {:ok, %ReadResponse{
        response_header: hdr, results: res || [], diagnostic_infos: diags || []
      }, r3}
    end
  end

  # ── Write ─────────────────────────────────────────────────────────────────────

  defmodule WriteValue do
    defstruct [node_id: nil, attribute_id: 13, index_range: nil, value: nil]
  end

  defmodule WriteRequest do
    defstruct [request_header: nil, nodes_to_write: []]
  end

  defmodule WriteResponse do
    defstruct [response_header: nil, results: [], diagnostic_infos: []]
  end

  defp encode_write_value(%WriteValue{} = w) do
    encode_node_id(w.node_id || NodeId.ns0(0)) <>
    encode_uint32(w.attribute_id) <>
    encode_string(w.index_range) <>
    encode_data_value(w.value || %DataValue{})
  end

  defp decode_write_value(data) do
    with {nid,     r1} <- decode_node_id(data),
         {attr_id, r2} <- decode_uint32(r1),
         {idx_rng, r3} <- decode_string(r2),
         {dv,      r4} <- decode_data_value(r3) do
      {%WriteValue{node_id: nid, attribute_id: attr_id, index_range: idx_rng, value: dv}, r4}
    end
  end

  defp do_encode(:write_req, %WriteRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_array(r.nodes_to_write || [], &encode_write_value/1)
  end

  defp do_decode(:write_req, data) do
    with {hdr,   r1} <- decode_request_header(data),
         {nodes, r2} <- decode_array(r1, &decode_write_value/1) do
      {:ok, %WriteRequest{request_header: hdr, nodes_to_write: nodes || []}, r2}
    end
  end

  defp do_encode(:write_res, %WriteResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_array(r.results || [], &encode_status_code/1) <>
    encode_array(r.diagnostic_infos || [], &encode_diagnostic_info/1)
  end

  defp do_decode(:write_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {res,   r2} <- decode_array(r1, &decode_status_code/1),
         {diags, r3} <- decode_array(r2, &decode_diagnostic_info/1) do
      {:ok, %WriteResponse{
        response_header: hdr, results: res || [], diagnostic_infos: diags || []
      }, r3}
    end
  end

  # ── CreateSubscription ────────────────────────────────────────────────────────

  defmodule CreateSubscriptionRequest do
    defstruct [
      request_header:               nil,
      requested_publishing_interval: 500.0,   # ms
      requested_lifetime_count:     10,
      requested_max_keep_alive_count: 3,
      max_notifications_per_publish: 0,
      publishing_enabled:           true,
      priority:                     0
    ]
  end

  defmodule CreateSubscriptionResponse do
    defstruct [
      response_header:              nil,
      subscription_id:              0,
      revised_publishing_interval:  500.0,
      revised_lifetime_count:       10,
      revised_max_keep_alive_count: 3
    ]
  end

  defp do_encode(:create_subscription_req, %CreateSubscriptionRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_double(r.requested_publishing_interval) <>
    encode_uint32(r.requested_lifetime_count) <>
    encode_uint32(r.requested_max_keep_alive_count) <>
    encode_uint32(r.max_notifications_per_publish) <>
    encode_boolean(r.publishing_enabled) <>
    encode_byte(r.priority)
  end

  defp do_decode(:create_subscription_req, data) do
    with {hdr,   r1} <- decode_request_header(data),
         {pi,    r2} <- decode_double(r1),
         {lc,    r3} <- decode_uint32(r2),
         {ka,    r4} <- decode_uint32(r3),
         {maxn,  r5} <- decode_uint32(r4),
         {pub,   r6} <- decode_boolean(r5),
         {prio,  r7} <- decode_byte(r6) do
      {:ok, %CreateSubscriptionRequest{
        request_header: hdr, requested_publishing_interval: pi,
        requested_lifetime_count: lc, requested_max_keep_alive_count: ka,
        max_notifications_per_publish: maxn, publishing_enabled: pub, priority: prio
      }, r7}
    end
  end

  defp do_encode(:create_subscription_res, %CreateSubscriptionResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_uint32(r.subscription_id) <>
    encode_double(r.revised_publishing_interval) <>
    encode_uint32(r.revised_lifetime_count) <>
    encode_uint32(r.revised_max_keep_alive_count)
  end

  defp do_decode(:create_subscription_res, data) do
    with {hdr, r1} <- decode_response_header(data),
         {sid, r2} <- decode_uint32(r1),
         {pi,  r3} <- decode_double(r2),
         {lc,  r4} <- decode_uint32(r3),
         {ka,  r5} <- decode_uint32(r4) do
      {:ok, %CreateSubscriptionResponse{
        response_header: hdr, subscription_id: sid,
        revised_publishing_interval: pi, revised_lifetime_count: lc,
        revised_max_keep_alive_count: ka
      }, r5}
    end
  end

  # ── CreateMonitoredItems ──────────────────────────────────────────────────────

  defmodule MonitoringParameters do
    defstruct [
      client_handle:        0,
      sampling_interval:    -1.0,   # -1 = use subscription interval
      filter:               nil,    # ExtensionObject (null = no filter)
      queue_size:           1,
      discard_oldest:       true
    ]
  end

  defmodule MonitoredItemCreateRequest do
    defstruct [
      item_to_monitor:      nil,    # %ReadValueId{}
      monitoring_mode:      1,      # 0=Disabled,1=Sampling,2=Reporting
      requested_parameters: nil     # %MonitoringParameters{}
    ]
  end

  defmodule MonitoredItemCreateResult do
    defstruct [
      status_code:                  0,
      monitored_item_id:            0,
      revised_sampling_interval:    500.0,
      revised_queue_size:           1,
      filter_result:                nil
    ]
  end

  defmodule CreateMonitoredItemsRequest do
    defstruct [
      request_header:       nil,
      subscription_id:      0,
      timestamps_to_return: 2,
      items_to_create:      []
    ]
  end

  defmodule CreateMonitoredItemsResponse do
    defstruct [response_header: nil, results: [], diagnostic_infos: []]
  end

  defp encode_monitoring_params(%MonitoringParameters{} = p) do
    encode_uint32(p.client_handle) <>
    encode_double(p.sampling_interval) <>
    encode_extension_object(p.filter || %ExtensionObject{}) <>
    encode_uint32(p.queue_size) <>
    encode_boolean(p.discard_oldest)
  end

  defp decode_monitoring_params(data) do
    with {handle, r1} <- decode_uint32(data),
         {si,     r2} <- decode_double(r1),
         {filter, r3} <- decode_extension_object(r2),
         {qs,     r4} <- decode_uint32(r3),
         {disc,   r5} <- decode_boolean(r4) do
      {%MonitoringParameters{
        client_handle: handle, sampling_interval: si,
        filter: filter, queue_size: qs, discard_oldest: disc
      }, r5}
    end
  end

  defp encode_monitored_item_create_req(%MonitoredItemCreateRequest{} = r) do
    encode_read_value_id(r.item_to_monitor || %ReadValueId{}) <>
    encode_uint32(r.monitoring_mode) <>
    encode_monitoring_params(r.requested_parameters || %MonitoringParameters{})
  end

  defp decode_monitored_item_create_req(data) do
    with {rvid,   r1} <- decode_read_value_id(data),
         {mode,   r2} <- decode_uint32(r1),
         {params, r3} <- decode_monitoring_params(r2) do
      {%MonitoredItemCreateRequest{
        item_to_monitor: rvid, monitoring_mode: mode, requested_parameters: params
      }, r3}
    end
  end

  defp encode_monitored_item_create_result(%MonitoredItemCreateResult{} = r) do
    encode_status_code(r.status_code) <>
    encode_uint32(r.monitored_item_id) <>
    encode_double(r.revised_sampling_interval) <>
    encode_uint32(r.revised_queue_size) <>
    encode_extension_object(r.filter_result || %ExtensionObject{})
  end

  defp decode_monitored_item_create_result(data) do
    with {sc,    r1} <- decode_status_code(data),
         {mid,   r2} <- decode_uint32(r1),
         {si,    r3} <- decode_double(r2),
         {qs,    r4} <- decode_uint32(r3),
         {filt,  r5} <- decode_extension_object(r4) do
      {%MonitoredItemCreateResult{
        status_code: sc, monitored_item_id: mid,
        revised_sampling_interval: si, revised_queue_size: qs, filter_result: filt
      }, r5}
    end
  end

  defp do_encode(:create_monitored_items_req, %CreateMonitoredItemsRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_uint32(r.subscription_id) <>
    encode_uint32(r.timestamps_to_return) <>
    encode_array(r.items_to_create || [], &encode_monitored_item_create_req/1)
  end

  defp do_decode(:create_monitored_items_req, data) do
    with {hdr,   r1} <- decode_request_header(data),
         {sid,   r2} <- decode_uint32(r1),
         {tsr,   r3} <- decode_uint32(r2),
         {items, r4} <- decode_array(r3, &decode_monitored_item_create_req/1) do
      {:ok, %CreateMonitoredItemsRequest{
        request_header: hdr, subscription_id: sid,
        timestamps_to_return: tsr, items_to_create: items || []
      }, r4}
    end
  end

  defp do_encode(:create_monitored_items_res, %CreateMonitoredItemsResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_array(r.results || [], &encode_monitored_item_create_result/1) <>
    encode_array(r.diagnostic_infos || [], &encode_diagnostic_info/1)
  end

  defp do_decode(:create_monitored_items_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {res,   r2} <- decode_array(r1, &decode_monitored_item_create_result/1),
         {diags, r3} <- decode_array(r2, &decode_diagnostic_info/1) do
      {:ok, %CreateMonitoredItemsResponse{
        response_header: hdr, results: res || [], diagnostic_infos: diags || []
      }, r3}
    end
  end

  # ── DeleteMonitoredItems ──────────────────────────────────────────────────────

  defp do_encode(:delete_monitored_items_req, %{request_header: hdr, subscription_id: sid, monitored_item_ids: ids}) do
    encode_request_header(hdr || %RequestHeader{}) <>
    encode_uint32(sid) <>
    encode_array(ids || [], &encode_uint32/1)
  end
  defp do_decode(:delete_monitored_items_req, data) do
    with {hdr, r1} <- decode_request_header(data),
         {sid, r2} <- decode_uint32(r1),
         {ids, r3} <- decode_array(r2, &decode_uint32/1) do
      {:ok, %{request_header: hdr, subscription_id: sid, monitored_item_ids: ids || []}, r3}
    end
  end

  defp do_encode(:delete_monitored_items_res, %{response_header: hdr, results: res, diagnostic_infos: diags}) do
    encode_response_header(hdr || %ResponseHeader{}) <>
    encode_array(res || [], &encode_status_code/1) <>
    encode_array(diags || [], &encode_diagnostic_info/1)
  end
  defp do_decode(:delete_monitored_items_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {res,   r2} <- decode_array(r1, &decode_status_code/1),
         {diags, r3} <- decode_array(r2, &decode_diagnostic_info/1) do
      {:ok, %{response_header: hdr, results: res || [], diagnostic_infos: diags || []}, r3}
    end
  end

  # ── Publish ───────────────────────────────────────────────────────────────────

  defmodule SubscriptionAcknowledgement do
    defstruct [:subscription_id, :sequence_number]
  end

  defmodule PublishRequest do
    defstruct [request_header: nil, subscription_acknowledgements: []]
  end

  defmodule DataChangeNotification do
    defstruct [monitored_items: [], diagnostic_infos: []]
  end

  defmodule MonitoredItemNotification do
    defstruct [:client_handle, :value]  # value is %DataValue{}
  end

  defmodule NotificationMessage do
    defstruct [
      sequence_number:      0,
      publish_time:         nil,
      notification_data:    []   # [%ExtensionObject{}] wrapping DataChangeNotification etc.
    ]
  end

  defmodule PublishResponse do
    defstruct [
      response_header:            nil,
      subscription_id:            0,
      available_sequence_numbers: [],
      more_notifications:         false,
      notification_message:       nil,
      results:                    [],
      diagnostic_infos:           []
    ]
  end

  defp encode_sub_ack(%SubscriptionAcknowledgement{} = a) do
    encode_uint32(a.subscription_id) <> encode_uint32(a.sequence_number)
  end

  defp decode_sub_ack(data) do
    with {sid, r1} <- decode_uint32(data),
         {seq, r2} <- decode_uint32(r1) do
      {%SubscriptionAcknowledgement{subscription_id: sid, sequence_number: seq}, r2}
    end
  end

  defp encode_monitored_item_notification(%MonitoredItemNotification{} = n) do
    encode_uint32(n.client_handle) <> encode_data_value(n.value || %DataValue{})
  end

  defp decode_monitored_item_notification(data) do
    with {handle, r1} <- decode_uint32(data),
         {dv,     r2} <- decode_data_value(r1) do
      {%MonitoredItemNotification{client_handle: handle, value: dv}, r2}
    end
  end

  # DataChangeNotification encoded as ExtensionObject body
  @data_change_notification_type_id 811

  def encode_data_change_notification(%DataChangeNotification{} = n) do
    body =
      encode_array(n.monitored_items || [], &encode_monitored_item_notification/1) <>
      encode_array(n.diagnostic_infos || [], &encode_diagnostic_info/1)
    type_id = %NodeId{ns: 0, type: :numeric, id: @data_change_notification_type_id}
    %ExtensionObject{type_id: type_id, encoding: :binary, body: body}
  end

  def decode_data_change_notification(%ExtensionObject{body: body}) when is_binary(body) do
    with {items, r1} <- decode_array(body, &decode_monitored_item_notification/1),
         {diags, _}  <- decode_array(r1, &decode_diagnostic_info/1) do
      {:ok, %DataChangeNotification{
        monitored_items: items || [], diagnostic_infos: diags || []
      }}
    end
  end

  defp encode_notification_message(%NotificationMessage{} = m) do
    encode_uint32(m.sequence_number) <>
    encode_datetime(m.publish_time) <>
    encode_array(m.notification_data || [], &encode_extension_object/1)
  end

  defp decode_notification_message(data) do
    with {seq,  r1} <- decode_uint32(data),
         {pts,  r2} <- decode_datetime(r1),
         {ndata,r3} <- decode_array(r2, &decode_extension_object/1) do
      {%NotificationMessage{
        sequence_number: seq, publish_time: pts, notification_data: ndata || []
      }, r3}
    end
  end

  defp do_encode(:publish_req, %PublishRequest{} = r) do
    encode_request_header(r.request_header || %RequestHeader{}) <>
    encode_array(r.subscription_acknowledgements || [], &encode_sub_ack/1)
  end

  defp do_decode(:publish_req, data) do
    with {hdr,  r1} <- decode_request_header(data),
         {acks, r2} <- decode_array(r1, &decode_sub_ack/1) do
      {:ok, %PublishRequest{
        request_header: hdr, subscription_acknowledgements: acks || []
      }, r2}
    end
  end

  defp do_encode(:publish_res, %PublishResponse{} = r) do
    encode_response_header(r.response_header || %ResponseHeader{}) <>
    encode_uint32(r.subscription_id) <>
    encode_array(r.available_sequence_numbers || [], &encode_uint32/1) <>
    encode_boolean(r.more_notifications) <>
    encode_notification_message(r.notification_message || %NotificationMessage{}) <>
    encode_array(r.results || [], &encode_status_code/1) <>
    encode_array(r.diagnostic_infos || [], &encode_diagnostic_info/1)
  end

  defp do_decode(:publish_res, data) do
    with {hdr,    r1} <- decode_response_header(data),
         {sid,    r2} <- decode_uint32(r1),
         {avail,  r3} <- decode_array(r2, &decode_uint32/1),
         {more,   r4} <- decode_boolean(r3),
         {notif,  r5} <- decode_notification_message(r4),
         {res,    r6} <- decode_array(r5, &decode_status_code/1),
         {diags,  r7} <- decode_array(r6, &decode_diagnostic_info/1) do
      {:ok, %PublishResponse{
        response_header: hdr, subscription_id: sid,
        available_sequence_numbers: avail || [], more_notifications: more,
        notification_message: notif, results: res || [], diagnostic_infos: diags || []
      }, r7}
    end
  end

  # ── DeleteSubscriptions ───────────────────────────────────────────────────────

  defp do_encode(:delete_subscriptions_req, %{request_header: hdr, subscription_ids: ids}) do
    encode_request_header(hdr || %RequestHeader{}) <>
    encode_array(ids || [], &encode_uint32/1)
  end
  defp do_decode(:delete_subscriptions_req, data) do
    with {hdr, r1} <- decode_request_header(data),
         {ids, r2} <- decode_array(r1, &decode_uint32/1) do
      {:ok, %{request_header: hdr, subscription_ids: ids || []}, r2}
    end
  end

  defp do_encode(:delete_subscriptions_res, %{response_header: hdr, results: res, diagnostic_infos: diags}) do
    encode_response_header(hdr || %ResponseHeader{}) <>
    encode_array(res || [], &encode_status_code/1) <>
    encode_array(diags || [], &encode_diagnostic_info/1)
  end
  defp do_decode(:delete_subscriptions_res, data) do
    with {hdr,   r1} <- decode_response_header(data),
         {res,   r2} <- decode_array(r1, &decode_status_code/1),
         {diags, r3} <- decode_array(r2, &decode_diagnostic_info/1) do
      {:ok, %{response_header: hdr, results: res || [], diagnostic_infos: diags || []}, r3}
    end
  end

  # ── ServiceFault ──────────────────────────────────────────────────────────────

  defp do_encode(:service_fault, %{response_header: hdr}) do
    encode_response_header(hdr || %ResponseHeader{})
  end
  defp do_decode(:service_fault, data) do
    with {hdr, rest} <- decode_response_header(data) do
      {:ok, %{response_header: hdr}, rest}
    end
  end

  # ── Catch-all ─────────────────────────────────────────────────────────────────

  defp do_encode(service, _params), do: {:error, {:unknown_service, service}}
  defp do_decode(service, _data),   do: {:error, {:unknown_service, service}}

  # ── Helpers ───────────────────────────────────────────────────────────────────

  # AnonymousIdentityToken: ExtensionObject wrapping a null body with type i=321
  @anonymous_identity_token_type_id 321

  def anonymous_identity_token do
    # PolicyId is a String (empty = any policy)
    body = encode_string("")
    %ExtensionObject{
      type_id: %NodeId{ns: 0, type: :numeric, id: @anonymous_identity_token_type_id},
      encoding: :binary,
      body: body
    }
  end

  def username_identity_token(policy_id, username, password, security_policy_uri \\ nil) do
    # type id 324 = UserNameIdentityToken_Encoding_DefaultBinary
    body =
      encode_string(policy_id) <>
      encode_string(username) <>
      encode_byte_string(password) <>
      encode_string(security_policy_uri)
    %ExtensionObject{
      type_id: %NodeId{ns: 0, type: :numeric, id: 324},
      encoding: :binary,
      body: body
    }
  end

  # Build a minimal good ResponseHeader for a given request handle
  def ok_response_header(request_handle) do
    %ResponseHeader{
      timestamp: DateTime.utc_now(),
      request_handle: request_handle,
      service_result: 0,
      service_diagnostics: nil,
      string_table: [],
      additional_header: nil
    }
  end

  # Build a fault ResponseHeader
  def fault_response_header(request_handle, status_code) do
    %ResponseHeader{
      timestamp: DateTime.utc_now(),
      request_handle: request_handle,
      service_result: status_code,
      service_diagnostics: nil,
      string_table: [],
      additional_header: nil
    }
  end
end
