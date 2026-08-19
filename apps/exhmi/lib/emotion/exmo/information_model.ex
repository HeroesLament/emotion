defmodule EMotion.InformationModel do
  @moduledoc """
  Public entrypoint for the ExMo Information Model.

  All external interfaces (OPC-UA, REST, WebSocket, HMI) should derive
  their representations from this model rather than maintaining their own
  parallel node definitions.

  ## Usage

      {:ok, model} = EMotion.InformationModel.compiled_model()
      {:ok, nodes} = EMotion.Projection.OPCUA.project(model)
      IO.inspect(nodes, pretty: true, limit: :infinity)
  """

  alias EMotion.Schema.{Compiler, Registry}

  @doc "Returns the raw (uncompiled) model from the registry."
  @spec model() :: EMotion.Schema.Model.t()
  def model do
    Registry.base_model()
  end

  @doc """
  Returns the compiled model with normalized paths and validated structure.

  Prefer this over `model/0` for production use and projection.
  """
  @spec compiled_model() :: {:ok, EMotion.Schema.Model.t()} | {:error, [String.t()]}
  def compiled_model do
    model()
    |> Compiler.compile()
  end
end
