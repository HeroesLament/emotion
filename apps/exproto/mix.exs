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
      deps: deps()
    ]
  end

  # No supervision tree yet, and none until there is a transport to supervise.
  # Dispatch is a pure function of a request and a session.
  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # The node table and the protocol document both come from the model.
      {:exhmi, in_umbrella: true}
    ]
  end
end
