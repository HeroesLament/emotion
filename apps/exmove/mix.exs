defmodule Exmove.MixProject do
  use Mix.Project

  def project do
    [
      app: :exmove,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      rustler_crates: rustler_crates()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ExMove.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exdrive, in_umbrella: true},
      {:exdash, in_umbrella: true},
      {:rustler, "~> 0.37"},
    ]
  end

  defp rustler_crates do
    [
      exmove_ik: [
        path: "native/exmove_ik",
        mode: (if Mix.env() == :prod, do: :release, else: :debug)
      ]
    ]
  end
end
