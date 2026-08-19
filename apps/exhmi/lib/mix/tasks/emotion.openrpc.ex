defmodule Mix.Tasks.Emotion.Openrpc do
  @shortdoc "Generates the OpenRPC document from the Information Model"

  @moduledoc """
  Writes the controller's OpenRPC document from the E-Motion Information Model.

      mix emotion.openrpc            # write the document
      mix emotion.openrpc --check    # exit non-zero if the committed file is stale
      mix emotion.openrpc --stdout   # print instead of writing

  ## Why generated

  The OPC UA projection already derives from this model. A second, hand-written
  description of the same controller agrees with the first right up until it
  doesn't, and the divergence is discovered by a client rather than by a test.

  `--check` is the CI form. It regenerates in memory and compares, so a model
  change that nobody regenerated for fails the build instead of shipping a
  document that describes a controller that no longer exists.

  ## Output is canonical

  Keys are sorted, so regenerating an unchanged model produces a byte-identical
  file. Without that, `--check` reports noise and every commit carries a
  reshuffled diff.
  """

  use Mix.Task

  alias EMotion.InformationModel
  alias EMotion.Projection.JSONRPC.OpenRPC

  @default_path "protocol/emotion-protocol.openrpc.json"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _} =
      OptionParser.parse(args, switches: [check: :boolean, stdout: :boolean, path: :string])

    Mix.Task.run("app.start")

    json = build!()
    path = Path.expand(opts[:path] || default_path())

    cond do
      opts[:stdout] -> IO.puts(json)
      opts[:check] -> check!(path, json)
      true -> write!(path, json)
    end
  end

  defp build! do
    with {:ok, model} <- InformationModel.compiled_model(),
         {:ok, document} <- OpenRPC.document(model) do
      OpenRPC.encode(document)
    else
      {:error, reason} ->
        Mix.raise("could not build the OpenRPC document: #{inspect(reason)}")
    end
  end

  defp write!(path, json) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json)

    Mix.shell().info([
      :green,
      "* generated ",
      :reset,
      Path.relative_to_cwd(path),
      " (#{byte_size(json)} bytes)"
    ])
  end

  defp check!(path, json) do
    case File.read(path) do
      {:ok, ^json} ->
        Mix.shell().info([:green, "* up to date ", :reset, Path.relative_to_cwd(path)])

      {:ok, _stale} ->
        Mix.raise("""
        #{Path.relative_to_cwd(path)} is stale.

        The Information Model has changed since it was generated. Run:

            mix emotion.openrpc

        and commit the result.
        """)

      {:error, :enoent} ->
        Mix.raise("""
        #{Path.relative_to_cwd(path)} does not exist.

        Run `mix emotion.openrpc` and commit the result.
        """)
    end
  end

  # The umbrella root, so the document lands beside the design docs rather than
  # inside whichever app happens to generate it. Neither the Studio nor the
  # controller owns the contract.
  defp default_path do
    Path.join(umbrella_root(), @default_path)
  end

  defp umbrella_root do
    case Mix.Project.config()[:apps_path] do
      nil -> Path.join(File.cwd!(), "../..")
      _ -> File.cwd!()
    end
  end
end
