defmodule Exproto.MixProject do
  use Mix.Project

  def project do
    [
      app: :exproto,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # No supervision tree of its own. The endpoint is a child spec a host
  # application places, so a controller decides its own port and certificate
  # rather than having them decided by a library being loaded.
  def application do
    [extra_applications: [:logger, :ssl, :public_key, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The node table and the protocol document both come from the model.
      {:exhmi, in_umbrella: true},

      # The credential authority. Authentication happens at the upgrade in
      # ExProto.Router; grants are checked against the model in ExProto.Nodes.
      {:exauth, in_umbrella: true},

      # Transport. Bandit rather than Cowboy: pure Elixir, smaller on a Nerves
      # image, and the WebSock specification is the supported way to speak
      # WebSocket without dragging Phoenix in.
      {:bandit, "~> 1.5"},
      {:websock_adapter, "~> 0.5"},

      # Self-signed certificate generation in pure Elixir. The alternative is
      # shelling out to openssl, which a Nerves image should not have to carry.
      {:x509, "~> 0.8"},

      # A real WebSocket client, so the end-to-end tests speak TLS to the actual
      # listener rather than asserting against a mock of it.
      {:mint_web_socket, "~> 1.0", only: :test},
      {:castore, "~> 1.0", only: :test}
    ]
  end
end
