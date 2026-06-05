defmodule ExGCode.MixProject do
  use Mix.Project

  def project do
    [
      app:     :exgcode,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir:  "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExGCode.Application, []},
    ]
  end

  defp deps do
    [
      {:exmove, in_umbrella: true},

    ]
  end
end
