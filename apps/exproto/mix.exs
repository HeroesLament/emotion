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

      # The simulated drives the controller serves. ExProto.Source.Exdrive binds
      # the node table to them.
      {:exdrive, in_umbrella: true},

      # Transport. Bandit rather than Cowboy: pure Elixir, smaller on a Nerves
      # image, and the WebSock specification is the supported way to speak
      # WebSocket without dragging Phoenix in.
      {:bandit, "~> 1.5"},
      {:websock_adapter, "~> 0.5"},

      # Self-signed certificate generation in pure Elixir. The alternative is
      # shelling out to openssl, which a Nerves image should not have to carry.
      {:x509, "~> 0.8"},

      # The client, as its own application so a client can be had without a
      # controller — Studio path-depends on exlink alone. The tests here drive
      # it against this server, which is what keeps the two halves honest.
      {:exlink, in_umbrella: true},

      # Still direct dependencies: the transport tests make raw HTTP requests
      # that are not sessions — an upgrade with no credential, a plaintext
      # probe — which the client has no reason to expose.
      {:mint_web_socket, "~> 1.0"},
      {:castore, "~> 1.0"}
    ]
  end
end
