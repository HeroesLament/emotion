defmodule EMotion.Controllers do
  @moduledoc """
  The Controllers tab: the saved controllers, and the one you are connected to.

  A factory has several cells and one engineer workstation, so the studio holds
  a list of controllers and a connection to exactly one of them. Which one is a
  choice someone makes; nothing here connects on its own.

  ## Split from the shell on purpose

  Everything in this module is a pure function of a small state struct — the
  view is data, and every action returns `{state, effects}` rather than doing
  anything. That means the whole tab, including which buttons are enabled when
  and what a dialog is asked to collect, is testable with no window open. The
  shell performs the effects.

  ## One connection at a time

  Not a simplification: controllers in a cell elect a master and the master's
  information model aggregates the cell, so a client talks to one endpoint. If
  a second is ever genuinely needed it is a second `EMotion.Link` under a
  different name, not a change here.
  """

  alias EMotion.Controller.Profile

  defstruct profiles: [],
            selected: nil,
            connection: :disconnected,
            connected_to: nil,
            status: "No controller connected"

  @type connection :: :disconnected | :connecting | {:connected, map()}

  @type t :: %__MODULE__{
          profiles: [Profile.t()],
          selected: String.t() | nil,
          connection: connection(),
          connected_to: String.t() | nil,
          status: String.t()
        }

  @typedoc """
  Something the shell should do. Every one of these touches the world, which is
  exactly why they are returned rather than performed.
  """
  @type effect ::
          {:dialog, atom(), keyword()}
          | {:connect, Profile.t(), keyword()}
          | :disconnect
          | {:save, [Profile.t()]}

  # ── Construction ──────────────────────────────────────────────────────────

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    profiles = Keyword.get_lazy(opts, :profiles, &Profile.load/0)
    %__MODULE__{profiles: profiles, selected: first_name(profiles)}
  end

  defp first_name([]), do: nil
  defp first_name([%Profile{name: name} | _]), do: name

  @spec selected(t()) :: Profile.t() | nil
  def selected(%__MODULE__{selected: nil}), do: nil

  def selected(%__MODULE__{profiles: profiles, selected: name}) do
    case Profile.fetch(profiles, name) do
      {:ok, profile} -> profile
      :error -> nil
    end
  end

  @doc """
  How each controller reads in the list.

  The connected one is marked, because a list of five cells where the live one
  looks like the other four is a list you can act on by mistake.
  """
  @spec labels(t()) :: [String.t()]
  def labels(%__MODULE__{} = state) do
    Enum.map(state.profiles, fn profile ->
      marker = if connected_to?(state, profile.name), do: "● ", else: "   "
      "#{marker}#{profile.name}   #{profile.host}:#{profile.port}"
    end)
  end

  @spec connected?(t()) :: boolean()
  def connected?(%__MODULE__{connection: {:connected, _}}), do: true
  def connected?(_state), do: false

  defp connected_to?(state, name), do: connected?(state) and state.connected_to == name

  @doc """
  Whether each button can be pressed, given what is selected and connected.

  Returned as data so the view is a rendering of this rather than a second
  place the rules are written.
  """
  @spec enabled(t()) :: %{atom() => boolean()}
  def enabled(%__MODULE__{} = state) do
    has_selection = selected(state) != nil
    live = connected?(state)

    %{
      add: true,
      edit: has_selection and not live,
      remove: has_selection and not connected_to?(state, state.selected),
      properties: has_selection,
      # Connecting somewhere else while connected is not offered. Disconnect is
      # a deliberate act, and a button that silently drops a live link to a
      # moving machine to make a new one is not a button.
      connect: has_selection and not live,
      disconnect: live
    }
  end

  # ── Selection ─────────────────────────────────────────────────────────────

  @spec select(t(), non_neg_integer()) :: t()
  def select(%__MODULE__{} = state, index) do
    case Enum.at(state.profiles, index) do
      nil -> state
      profile -> %{state | selected: profile.name}
    end
  end

  # ── Actions ───────────────────────────────────────────────────────────────

  @doc """
  Handles a button, returning the new state and what the shell should do.
  """
  @spec action(t(), atom()) :: {t(), [effect()]}
  def action(state, :add) do
    {state, [{:dialog, :controller_add, title: "Add Controller", fields: fields(nil)}]}
  end

  def action(state, :edit) do
    case selected(state) do
      nil ->
        {state, []}

      profile ->
        {state, [{:dialog, :controller_edit, title: "Edit #{profile.name}", fields: fields(profile)}]}
    end
  end

  def action(state, :remove) do
    case selected(state) do
      nil ->
        {state, []}

      profile ->
        profiles = Profile.delete(state.profiles, profile.name)

        {%{state | profiles: profiles, selected: first_name(profiles)},
         [{:save, profiles}]}
    end
  end

  def action(state, :properties) do
    case selected(state) do
      nil ->
        {state, []}

      profile ->
        {state,
         [{:dialog, :controller_properties,
           title: "#{profile.name} — Properties", fields: property_fields(profile)}]}
    end
  end

  def action(state, :connect) do
    case selected(state) do
      nil ->
        {state, []}

      profile ->
        case Profile.token(profile) do
          # A token from a previous session: connect without asking again. That
          # is the whole point of exchanging the password for one.
          {:ok, _token} ->
            {%{state | connection: :connecting, status: "Connecting to #{profile.name}…"},
             [{:connect, profile, []}]}

          :error ->
            {state,
             [{:dialog, :controller_password,
               title: "Log in to #{profile.name}",
               fields: [
                 {:username, :static, label: "Username", value: profile.username},
                 {:password, :password, label: "Password", value: ""}
               ]}]}
        end
    end
  end

  def action(state, :disconnect) do
    {%{state | connection: :disconnected, connected_to: nil, status: "Disconnected"},
     [:disconnect]}
  end

  def action(state, _unknown), do: {state, []}

  # ── Dialog results ────────────────────────────────────────────────────────

  @spec dialog(t(), atom(), :cancel | {:ok, map()}) :: {t(), [effect()]}
  def dialog(state, _id, :cancel), do: {state, []}

  def dialog(state, :controller_add, {:ok, values}) do
    upsert(state, values, nil)
  end

  def dialog(state, :controller_edit, {:ok, values}) do
    upsert(state, values, state.selected)
  end

  def dialog(state, :controller_password, {:ok, %{"password" => password}}) do
    case selected(state) do
      nil ->
        {state, []}

      profile ->
        {%{state | connection: :connecting, status: "Connecting to #{profile.name}…"},
         [{:connect, profile, password: password}]}
    end
  end

  # Trust actions live here rather than as buttons on the tab: they belong to
  # one controller, and a row of destructive buttons beside a list is how the
  # wrong machine gets its certificate forgotten.
  def dialog(state, :controller_properties, {:ok, values}) do
    profile = selected(state)

    if profile do
      case Map.get(values, "trust") do
        "Forget pinned certificate" ->
          ExLink.KnownHosts.forget(ExLink.known_hosts_path(), "#{profile.host}:#{profile.port}")
          {%{state | status: "Forgot the pinned certificate for #{profile.name}"}, []}

        "Clear stored token" ->
          Profile.drop_token(profile)
          {%{state | status: "Cleared the stored token for #{profile.name}"}, []}

        _ ->
          {state, []}
      end
    else
      {state, []}
    end
  end

  def dialog(state, _id, _result), do: {state, []}

  defp upsert(state, values, replacing) do
    with {:ok, profile} <- build(values) do
      profiles = Profile.put(state.profiles, profile, replacing)

      {%{state | profiles: profiles, selected: profile.name}, [{:save, profiles}]}
    else
      {:error, message} -> {%{state | status: message}, []}
    end
  end

  defp build(values) do
    name = values |> Map.get("name", "") |> String.trim()
    host = values |> Map.get("host", "") |> String.trim()

    cond do
      name == "" -> {:error, "A controller needs a name"}
      host == "" -> {:error, "A controller needs a host"}
      true ->
        {:ok,
         %Profile{
           name: name,
           host: host,
           port: Map.get(values, "port", 4001),
           username: values |> Map.get("username", "operator") |> String.trim(),
           description: blank_to_nil(Map.get(values, "description")),
           rate_hz: (Map.get(values, "rate") || 20) * 1.0
         }}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── Connection results ────────────────────────────────────────────────────

  @spec connected(t(), String.t(), map()) :: t()
  def connected(state, name, info) do
    %{
      state
      | connection: {:connected, info},
        connected_to: name,
        status: "Connected to #{name} — #{info["capabilities"]["nodes"]["count"]} nodes"
    }
  end

  @spec failed(t(), term()) :: t()
  def failed(state, reason) do
    %{state | connection: :disconnected, connected_to: nil, status: "Connection failed: #{describe(reason)}"}
  end

  @spec disconnected(t(), term()) :: t()
  def disconnected(state, reason) do
    %{state | connection: :disconnected, connected_to: nil, status: "Disconnected: #{describe(reason)}"}
  end

  defp describe(:no_credential), do: "no stored token, and no password given"
  defp describe(%{"message" => message}), do: message
  defp describe(reason) when is_binary(reason), do: reason |> String.split("\n") |> hd()
  defp describe(reason), do: inspect(reason)

  # ── Dialog field specs ────────────────────────────────────────────────────

  defp fields(nil) do
    [
      {:name, :text, label: "Name", value: ""},
      {:host, :text, label: "Host", value: ""},
      {:port, :spin, label: "Port", min: 1, max: 65_535, value: 4001},
      {:username, :text, label: "Username", value: "operator"},
      {:rate, :spin, label: "Update rate (Hz)", min: 1, max: 200, value: 20},
      {:description, :text, label: "Description", value: ""}
    ]
  end

  defp fields(%Profile{} = p) do
    [
      {:name, :text, label: "Name", value: p.name},
      {:host, :text, label: "Host", value: p.host},
      {:port, :spin, label: "Port", min: 1, max: 65_535, value: p.port},
      {:username, :text, label: "Username", value: p.username},
      {:rate, :spin, label: "Update rate (Hz)", min: 1, max: 200, value: round(p.rate_hz)},
      {:description, :text, label: "Description", value: p.description || ""}
    ]
  end

  defp property_fields(%Profile{} = p) do
    [
      {:host, :static, label: "Address", value: "#{p.host}:#{p.port}"},
      {:username, :static, label: "Account", value: p.username},
      # The reason pinning exists is that someone can compare this against what
      # the controller printed at boot. Until now that was impossible from the
      # GUI.
      {:fingerprint, :static, label: "Pinned certificate", value: fingerprint(p)},
      {:token, :static, label: "Stored token", value: token_state(p)},
      {:trust, :choice,
       label: "Trust action",
       choices: ["Leave alone", "Forget pinned certificate", "Clear stored token"],
       selected: 0}
    ]
  end

  defp fingerprint(%Profile{} = p) do
    ExLink.known_hosts_path()
    |> ExLink.KnownHosts.load()
    |> Map.get("#{p.host}:#{p.port}", "not pinned — will be learned on first connection")
  end

  defp token_state(%Profile{} = p) do
    case Profile.token(p) do
      {:ok, _} -> "yes — connecting will not ask for a password"
      :error -> "none — connecting will ask for a password"
    end
  end
end
