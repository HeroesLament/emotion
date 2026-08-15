defmodule Exhmi.MixProject do
  use Mix.Project

  def project do
    [
      app:             :exhmi,
      version:         "0.1.0",
      build_path:      "../../_build",
      config_path:     "../../config/config.exs",
      deps_path:       "../../deps",
      lockfile:        "../../mix.lock",
      elixir:          "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps:            deps(),
      elixirc_paths:   elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExHMI.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

  defp deps do
    [
      {:ex_opcua, in_umbrella: true},

      # For the grant vocabulary. The model declares which grant guards each
      # property, so the names have to come from somewhere both projections
      # agree on. exauth has no dependency back on exhmi, so this stays acyclic.
      {:exauth, in_umbrella: true}
    ]
  end
end
