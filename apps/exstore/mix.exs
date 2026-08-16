defmodule ExStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :exstore,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExStore.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.17"}
    ]
  end

  # No ecto.drop alias, for the reason exauth used to give: `mix test` at the
  # umbrella root runs every app in one BEAM against one Repo, so dropping the
  # database here destroys it underneath whichever sibling is also using it.
  defp aliases, do: []
end
