defmodule EMotion.MixProject do
  use Mix.Project

  def project do
    [
      app: :emotion_studio,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx],
      mod: {EMotion.Application, []}
    ]
  end

  # Deliberately outside apps/ and not an umbrella member.
  #
  # The umbrella is the runtime: drives, kinematics, fieldbus, G-code — things
  # that run on a controller, headless, next to hardware. The studio is a
  # desktop application that talks to those, and giving it a wx and OpenGL
  # dependency inside the umbrella would put a GUI toolkit in the dependency
  # graph of everything that ships to a machine with no display.
  #
  # It reaches into the umbrella by path rather than the other way round, so
  # the arrow points from the tool at the runtime and never back.
  defp deps do
    [
      {:exmove, path: "../apps/exmove"},
      {:cedar, path: "../../cedar"}
    ]
  end
end
