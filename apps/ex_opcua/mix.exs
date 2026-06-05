defmodule ExOpcUA.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/your-org/ex_opcua"

  def project do
    [
      app: :ex_opcua,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExOpcUA.Application, []}
    ]
  end

  defp deps do
    [
      # No runtime deps — pure Elixir/OTP
      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A pure Elixir OPC UA client and server stack — no C, no ports, no NIFs."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "ExOpcUA",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
