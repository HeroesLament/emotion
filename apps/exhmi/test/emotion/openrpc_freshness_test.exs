defmodule EMotion.OpenRPCFreshnessTest do
  use ExUnit.Case, async: true

  alias EMotion.InformationModel
  alias EMotion.Projection.JSONRPC.OpenRPC

  @moduledoc """
  The committed protocol document matches the model it was generated from.

  `mix exmo.openrpc --check` has done this since the task was written, and
  nothing ran it, so a description that changed in the model sat contradicted by
  the published document until someone happened to regenerate. Which is worse
  than no document: a client reading `protocol/emotion-protocol.openrpc.json` has
  no way to know it is reading a snapshot of a build that no longer exists, and
  the file says GENERATED at the top, which reads as a promise that it is current.

  It also cannot be caught by reading. The generator only serialises a method's
  description, not its arguments, so editing an argument leaves the document
  byte-identical and editing the description does not — from the outside those
  look the same, and only regenerating tells them apart.

  So this is the check, run by the suite rather than by remembering.
  """

  @path "../../../../protocol/emotion-protocol.openrpc.json"

  test "protocol/emotion-protocol.openrpc.json is not stale" do
    {:ok, model} = InformationModel.compiled_model()
    {:ok, document} = OpenRPC.document(model)
    generated = OpenRPC.encode(document)

    path = Path.expand(@path, __DIR__)

    assert File.exists?(path), "#{path} is missing — run `mix exmo.openrpc`"

    committed = File.read!(path)

    assert committed == generated, """
    The committed OpenRPC document no longer matches the Information Model.

    Run:

        mix exmo.openrpc

    and commit the result. Note the controller must be stopped first — it holds
    the OPC UA port the task needs to start the model on.
    """
  end
end
