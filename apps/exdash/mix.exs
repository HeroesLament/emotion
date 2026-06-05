defmodule Exdash.MixProject do
  use Mix.Project

  def project do
    [
      app: :exdash,
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
    [
      extra_applications: [:logger],
      mod: {Exdash.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_ratatui, "~> 0.4"},
      {:asciichart, "~> 1.2"},
      {:exdrive, in_umbrella: true}
    ]
  end
end
