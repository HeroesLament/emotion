defmodule EMotion.Controller.Profile do
  @moduledoc """
  A saved controller: where it is, who to log in as, and nothing secret.

  Profiles live in a JSON file under the user's config directory. What is *not*
  in them is the password — the point of the token exchange is that a password
  is used once and a revocable bearer token is carried afterwards, so storing
  the password would give back exactly what the design gave up.

  Tokens are kept beside the profiles in a separate file with mode 0600, keyed
  by profile name, so a profile file can be shared, copied between machines or
  committed to a cell's configuration without carrying a credential.

  ## No auto-connect

  Nothing here dials anything. A design tool that reaches for a machine the
  moment it opens is one you cannot safely open next to a machine, so
  connecting is always something someone chose to do.
  """

  @enforce_keys [:name, :host]
  defstruct [
    :name,
    :host,
    :description,
    port: 4001,
    username: "operator",
    robot_id: :arm_a,
    rate_hz: 20.0
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          host: String.t(),
          description: String.t() | nil,
          port: :inet.port_number(),
          username: String.t(),
          robot_id: atom(),
          rate_hz: float()
        }

  @doc "Directory holding profiles and tokens."
  @spec config_dir() :: String.t()
  def config_dir do
    base =
      System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.user_home!() || ".", ".config")

    Path.join(base, "emotion")
  end

  @doc "The profiles file."
  @spec path() :: String.t()
  def path, do: Path.join(config_dir(), "controllers.json")

  @doc """
  Every saved profile, by name.

  A missing or unreadable file is an empty list rather than an error: having no
  controllers configured is the normal state for offline programming, and the
  studio must open regardless.
  """
  @spec load(String.t()) :: [t()]
  def load(file \\ path()) do
    with {:ok, raw} <- File.read(file),
         {:ok, decoded} <- decode(raw) do
      decoded |> Enum.map(&from_map/1) |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  @doc "Writes profiles back, creating the directory if needed."
  @spec save([t()], String.t()) :: :ok
  def save(profiles, file \\ path()) do
    File.mkdir_p!(Path.dirname(file))

    body =
      profiles
      |> Enum.map(&to_map/1)
      |> :json.encode()
      |> IO.iodata_to_binary()

    File.write!(file, body)
  end

  @doc "Finds a profile by name."
  @spec fetch([t()], String.t()) :: {:ok, t()} | :error
  def fetch(profiles, name) do
    case Enum.find(profiles, &(&1.name == name)) do
      nil -> :error
      profile -> {:ok, profile}
    end
  end

  # ── Tokens ────────────────────────────────────────────────────────────────

  @doc "Where the token for a profile is kept."
  @spec token_path(t() | String.t()) :: String.t()
  def token_path(%__MODULE__{name: name}), do: token_path(name)
  def token_path(name) when is_binary(name), do: Path.join([config_dir(), "tokens", name])

  @doc "The stored token for a profile, if it has one."
  @spec token(t() | String.t()) :: {:ok, String.t()} | :error
  def token(profile) do
    case File.read(token_path(profile)) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, _} -> :error
    end
  end

  @doc "Stores a token, readable only by its owner."
  @spec put_token(t() | String.t(), String.t()) :: :ok
  def put_token(profile, token) do
    file = token_path(profile)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, token)
    File.chmod!(file, 0o600)
  end

  @doc """
  Forgets a stored token.

  Local only — it does not tell the controller, which keeps issuing it until
  someone revokes it there. `mix exmo.account revoke` is the other half.
  """
  @spec drop_token(t() | String.t()) :: :ok
  def drop_token(profile) do
    _ = File.rm(token_path(profile))
    :ok
  end

  # ── Serialisation ─────────────────────────────────────────────────────────

  defp decode(raw) do
    case :json.decode(raw) do
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp to_map(%__MODULE__{} = p) do
    %{
      "name" => p.name,
      "host" => p.host,
      "port" => p.port,
      "username" => p.username,
      "robotId" => Atom.to_string(p.robot_id),
      "rateHz" => p.rate_hz
    }
    |> put_optional("description", p.description)
  end

  # Absent rather than null. Erlang's JSON encoder writes the atom `nil` as the
  # string "nil", so a profile with no description round-tripped as one
  # described as "nil". Omitting the key is also what a hand-edited file will
  # look like.
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp from_map(%{"name" => name, "host" => host} = m)
       when is_binary(name) and is_binary(host) do
    %__MODULE__{
      name: name,
      host: host,
      port: Map.get(m, "port", 4001),
      username: Map.get(m, "username", "operator"),
      description: Map.get(m, "description"),
      # A robot id from a file must not create an atom — that is unbounded
      # allocation driven by a file the studio did not write.
      robot_id: robot_id(Map.get(m, "robotId")),
      rate_hz: Map.get(m, "rateHz", 20.0) * 1.0
    }
  end

  defp from_map(_other), do: nil

  defp robot_id(nil), do: :arm_a

  defp robot_id(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :arm_a
  end
end
