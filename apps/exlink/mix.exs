defmodule ExLink.MixProject do
  use Mix.Project

  def project do
    [
      app: :exlink,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :ssl, :crypto, :public_key]]
  end

  # Nothing from the umbrella, and that is the whole point of the app existing.
  #
  # The client used to live in exproto, which depends on exhmi for the node
  # table and the protocol document. E-Motion Studio cannot take that
  # dependency: exhmi pulls in the OPC UA server and exauth pulls in SQLite and
  # Argon2 NIFs, so a desktop application would ship a database and a fieldbus
  # server in order to draw an arm. It also could not take it — `in_umbrella`
  # dependencies do not resolve from outside the umbrella.
  #
  # So the client is its own application with one dependency: a WebSocket.
  defp deps do
    [
      {:mint_web_socket, "~> 1.0"},
      {:castore, "~> 1.0"}
    ]
  end
end
