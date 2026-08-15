defmodule ExLink.KnownHosts do
  @moduledoc """
  Certificate fingerprints, remembered per controller.

  A controller mints its own certificate, so verifying it against a
  certificate authority is meaningless — there is no authority. What is
  meaningful is whether it is the *same* controller as last time.

  So the first connection records the certificate's SHA-256 against the host
  and port, and every connection after compares. The trust model is SSH's:
  weaker than PKI, because the first connection is unauthenticated and can be
  intercepted; much stronger than not looking.
  """

  @type entry :: {String.t(), String.t()}

  @doc """
  The default store location.

  Under the user's config directory rather than the working directory, because
  a desktop application started from a launcher has no meaningful cwd, and a
  trust store that moves depending on where you started from is one that
  silently re-learns fingerprints.
  """
  @spec default_path() :: String.t()
  def default_path do
    base =
      System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.user_home!() || ".", ".config")

    Path.join([base, "emotion", "known_hosts"])
  end

  @doc "Colon-separated uppercase SHA-256 — the form `openssl x509 -fingerprint -sha256` prints."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der) do
    :crypto.hash(:sha256, der)
    |> Base.encode16()
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &to_string/1)
  end

  @doc ~S(Every remembered host, as a map of "host:port" => fingerprint.)
  @spec load(String.t()) :: %{String.t() => String.t()}
  def load(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Map.new(fn line ->
          [host, print] = String.split(line, " ", parts: 2)
          {host, String.trim(print)}
        end)

      {:error, _} ->
        %{}
    end
  end

  @doc "Records a fingerprint for a host."
  @spec remember(String.t(), String.t(), String.t()) :: :ok
  def remember(path, key, print) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{key} #{print}\n", [:append])
  end

  @doc """
  Forgets a host, so the next connection re-learns it.

  What an operator runs after deliberately rotating a controller's
  certificate. Rewrites the file rather than appending, so the old line is
  actually gone.
  """
  @spec forget(String.t(), String.t()) :: :ok
  def forget(path, key) do
    remaining =
      path
      |> load()
      |> Map.delete(key)
      |> Enum.map_join("", fn {host, print} -> "#{host} #{print}\n" end)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, remaining)
  end

  @doc """
  Compares a live socket's certificate against what was remembered.

  `{:ok, :learned, print}` on first sight, `{:ok, :pinned, print}` when it
  matches, `{:error, {:fingerprint_changed, expected, got}}` when it does not.
  """
  @spec verify(port() | tuple(), String.t(), :inet.port_number(), keyword()) ::
          {:ok, :learned | :pinned, String.t()} | {:error, term()}
  def verify(socket, host, port, opts \\ []) do
    path = Keyword.get(opts, :known_hosts, default_path())

    with {:ok, der} <- :ssl.peercert(socket) do
      got = fingerprint(der)
      key = "#{host}:#{port}"

      case Map.get(load(path), key) do
        nil ->
          if Keyword.get(opts, :learn, true), do: remember(path, key, got)
          {:ok, :learned, got}

        ^got ->
          {:ok, :pinned, got}

        expected ->
          {:error, {:fingerprint_changed, expected, got}}
      end
    end
  end
end
