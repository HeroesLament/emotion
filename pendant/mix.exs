defmodule EMotion.Pendant.MixProject do
  use Mix.Project

  # Standalone AtomVM project for the PiBot CNC Pendant V4.2 hardware.
  # NOT an umbrella app and not part of the studio: it targets AtomVM on an
  # ESP32-WROOM-32E, has its own deps and lockfile, and packs to a .avm via
  # ExAtomVM. Same arrangement as studio/: it sits beside the umbrella, and
  # nothing in apps/ may depend on it.

  def project do
    [
      app: :emotion_pendant,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: [
        start: EMotion.Pendant,
        # main.avm partition of AtomVM-esp32-elixir-v0.7.0-beta.0 (read from
        # the image's partition table). Recheck when changing VM images.
        flash_offset: 0x250000
      ]
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:exatomvm, git: "https://github.com/atomvm/ExAtomVM/"},

      # Safety layer for the pendant-to-controller link: openSAFETY frame
      # codec, later SPDO producer and SCT. Pure Elixir, AtomVM subset.
      {:opensafety_ex, path: "../../opensafety_ex"}
    ]
  end
end
