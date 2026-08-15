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
      # SQLite rather than a file: the credential store is small, but the audit
      # log this will grow next is append-heavy and time-range queried, and one
      # database beats a file store plus a hand-rolled log rotator.
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.17"},

      # Argon2id for passwords. A NIF, but a well-trodden one that cross-compiles
      # under the Nerves toolchain, and the thing it protects can move an arm.
      {:argon2_elixir, "~> 4.0"}
    ]
  end

  # No ecto.drop alias. `mix test` at the umbrella root runs every app in a
  # single BEAM against a single Repo process, so dropping the database here
  # destroys it underneath whichever sibling app is also using it. Isolation
  # comes from the sandbox and schema from the migrator; neither needs the file
  # to be new.
  defp aliases, do: []
end
