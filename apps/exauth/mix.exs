defmodule ExAuth.MixProject do
  use Mix.Project

  def project do
    [
      app: :exauth,
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
      extra_applications: [:logger, :crypto],
      mod: {ExAuth.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The controller's database. exauth defines schemas and changesets; the
      # Repo, the adapter and the migrations belong to whoever owns the file,
      # and that stopped being this app when frames and tools arrived.
      {:exstore, in_umbrella: true},

      # Ecto itself, for schemas, changesets and queries. The adapter is
      # exstore's business.
      {:ecto_sql, "~> 3.11"},

      # Argon2id for passwords. A NIF, but a well-trodden one that cross-compiles
      # under the Nerves toolchain, and the thing it protects can move an arm.
      {:argon2_elixir, "~> 4.0"}
    ]
  end

  # No ecto.drop alias; see exstore, which owns the database this would drop.
  defp aliases, do: []
end
