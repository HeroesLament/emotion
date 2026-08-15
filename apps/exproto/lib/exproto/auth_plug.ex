defmodule ExProto.AuthPlug do
  @moduledoc """
  Extracts and verifies a bearer token from a request.

  ## Two ways to present a token, and one that is missing on purpose

  `Authorization: Bearer emo_...` is the correct way and is what E-Motion Studio,
  `curl` and any non-browser client uses.

  `Sec-WebSocket-Protocol: emotion.v1, emo_...` exists because the browser
  WebSocket API cannot set request headers — there is no argument for them in
  the constructor, and there never has been. The subprotocol field is the only
  client-controlled header a browser will send on an upgrade, so it is what
  every browser-facing WebSocket service ends up using. The server echoes back
  `emotion.v1` alone, never the token.

  A `?token=` query parameter is deliberately **not** supported. Query strings
  land in access logs, in `Referer` headers, in browser history and in any
  proxy along the way, and a credential that ends up in all four places is a
  credential that will eventually be found in one of them.
  """

  @subprotocol "emotion.v1"

  @doc """
  The token presented on this connection, if any.
  """
  @spec extract_token(Plug.Conn.t()) :: {:ok, String.t()} | :error
  def extract_token(conn) do
    with :error <- from_authorization(conn) do
      from_subprotocol(conn)
    end
  end

  @doc """
  Verifies whichever token was presented and returns the principal.
  """
  @spec authenticate(Plug.Conn.t()) :: {:ok, ExAuth.Principal.t()} | {:error, atom()}
  def authenticate(conn) do
    case extract_token(conn) do
      {:ok, token} -> ExAuth.authenticate(token)
      :error -> {:error, :missing_credential}
    end
  end

  @doc "The subprotocol name this build answers to."
  def subprotocol, do: @subprotocol

  defp from_authorization(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> Enum.find_value(:error, fn value ->
      case String.split(value, " ", parts: 2) do
        # Case-insensitive on the scheme: RFC 9110 says it is, and a client
        # sending "bearer" is not wrong.
        [scheme, token] ->
          if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}

        _ ->
          nil
      end
    end)
  end

  defp from_subprotocol(conn) do
    conn
    |> Plug.Conn.get_req_header("sec-websocket-protocol")
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(:error, fn value ->
      if value != @subprotocol and ExAuth.Tokens.well_formed?(value), do: {:ok, value}
    end)
  end
end
