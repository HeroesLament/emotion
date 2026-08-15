defmodule ExProto.Dispatch do
  @moduledoc """
  JSON-RPC 2.0 envelope handling: correlation, notifications, batches, errors.

  Pure. A decoded request and a session go in; a response and a new session
  come out. Nothing here touches a socket, a clock, or a process, which is why
  the entire protocol can be exercised in a test suite that runs in
  milliseconds — the same reason `dt` is an argument to a drive and the SDF
  maths lives in a crate with no GPU dependency.

  ## What this layer owes the spec

  A notification — a request with no `id` — gets no response, ever, including
  when it fails. That is the part implementations most often get wrong, because
  returning an error feels helpful; it is not, it is a message the client has
  no way to correlate and will either ignore or mistake for a reply to
  something else.

  A batch returns an array containing only the members that were requests, and
  an empty array of responses is sent as nothing at all rather than as `[]`.
  An empty batch is itself an invalid request.

  ## Method routing

  Methods are named in the generated OpenRPC document and implemented in
  `ExProto.Nodes`. There is no dynamic dispatch by string into module names,
  because a protocol whose method table is computed is a protocol where a typo
  in a client becomes a call into something unintended.
  """

  alias ExProto.{Nodes, Session}

  # Standard JSON-RPC 2.0 codes.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  @doc """
  Decodes a JSON payload and handles it.

  The transport's entry point. Separate from `handle/2` so that a malformed
  payload produces a spec-shaped parse error with a null id rather than an
  exception the transport has to interpret.
  """
  @spec handle_payload(binary(), Session.t()) :: {:reply, map() | list()} | :noreply | {:reply, map() | list(), Session.t()}
  def handle_payload(payload, session) when is_binary(payload) do
    case decode(payload) do
      {:ok, request} ->
        handle(request, session)

      :error ->
        {:reply, error_response(nil, @parse_error, "Parse error"), session}
    end
  end

  @doc """
  Handles one decoded request, or a batch.

  Returns `{:reply, response, session}` or `{:noreply, session}` — the latter
  for a notification, or for a batch that contained only notifications.
  """
  @spec handle(term(), Session.t()) :: {:reply, map() | list(), Session.t()} | {:noreply, Session.t()}
  def handle(requests, session) when is_list(requests) do
    if requests == [] do
      # "If the batch rpc call itself fails to be recognized [...] as an Array
      # with at least one value, the response [...] MUST be a single Response
      # object."
      {:reply, error_response(nil, @invalid_request, "Invalid Request"), session}
    end
    |> case do
      {:reply, _, _} = reply ->
        reply

      _ ->
        {responses, session} =
          Enum.reduce(requests, {[], session}, fn request, {acc, session} ->
            case handle(request, session) do
              {:reply, response, session} -> {[response | acc], session}
              {:noreply, session} -> {acc, session}
            end
          end)

        case Enum.reverse(responses) do
          # A batch of nothing but notifications gets nothing back, not `[]`.
          [] -> {:noreply, session}
          list -> {:reply, list, session}
        end
    end
  end

  def handle(%{"jsonrpc" => "2.0", "method" => method} = request, session)
      when is_binary(method) do
    id = Map.get(request, "id", :absent)
    params = Map.get(request, "params", %{})

    cond do
      not valid_id?(id) ->
        {:reply, error_response(nil, @invalid_request, "Invalid Request"), session}

      not is_map(params) ->
        # by-name only, per every method's paramStructure in the document.
        respond(id, {:error, @invalid_params, "Invalid params: expected an object"}, session)

      true ->
        {result, session} = route(method, params, session)
        respond(id, result, session)
    end
  end

  def handle(request, session) when is_map(request) do
    id = if valid_id?(Map.get(request, "id", :absent)), do: Map.get(request, "id"), else: nil
    {:reply, error_response(id, @invalid_request, "Invalid Request"), session}
  end

  def handle(_request, session) do
    {:reply, error_response(nil, @invalid_request, "Invalid Request"), session}
  end

  # ── Routing ───────────────────────────────────────────────────────────────

  defp route("initialize", params, session), do: Nodes.initialize(params, session)
  defp route("notifications/initialized", _params, session), do: {:ok, %{}, session} |> ok()
  defp route("nodes/browse", params, session), do: Nodes.browse(params, session)
  defp route("nodes/read", params, session), do: Nodes.read(params, session)
  defp route("nodes/write", params, session), do: Nodes.write(params, session)
  defp route("nodes/subscribe", params, session), do: Nodes.subscribe(params, session)
  defp route("nodes/unsubscribe", params, session), do: Nodes.unsubscribe(params, session)

  defp route(method, _params, session) do
    {{:error, @method_not_found, "Method not found: #{method}"}, session}
  end

  defp ok({:ok, result, session}), do: {{:ok, result}, session}

  # ── Responding ────────────────────────────────────────────────────────────

  # A notification gets nothing back, whatever happened. Returning an error to
  # a message with no id hands the client a response it cannot correlate.
  defp respond(:absent, _result, session), do: {:noreply, session}

  defp respond(id, {:ok, result}, session) do
    {:reply, %{"jsonrpc" => "2.0", "id" => id, "result" => result}, session}
  end

  defp respond(id, {:error, code, message}, session) do
    {:reply, error_response(id, code, message), session}
  end

  defp respond(id, {:error, code, message, data}, session) do
    {:reply, error_response(id, code, message, data), session}
  end

  @doc false
  def error_response(id, code, message, data \\ nil) do
    error =
      %{"code" => code, "message" => message}
      |> then(fn e -> if is_nil(data), do: e, else: Map.put(e, "data", data) end)

    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  @doc false
  def internal_error_code, do: @internal_error

  # ── Helpers ───────────────────────────────────────────────────────────────

  # The spec allows a string, a number, or null, and discourages null because
  # it collides with the id used for errors that have no request to blame.
  defp valid_id?(:absent), do: true
  defp valid_id?(id) when is_binary(id) or is_integer(id), do: true
  defp valid_id?(id) when is_float(id), do: true
  defp valid_id?(nil), do: true
  defp valid_id?(_), do: false

  defp decode(payload) do
    {decoded, _acc, rest} = :json.decode(payload, :ok, %{})

    if String.trim(rest) == "" do
      {:ok, decoded}
    else
      :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
