defmodule Metronome.MixProject do
  use Mix.Project

  def project do
    [
      app:             :metronome,
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
      mod: {Metronome.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

  # USB-only. The FPGA metronome owns all CAN/CANopen computation; this app
  # never speaks CAN, so there is deliberately no can_ex / CAN dependency here.
  defp deps do
    [
      {:usb, "0.2.1"}
    ]
  end
end
