defmodule EMotion.Program.Kind do
  @moduledoc """
  One statement kind: a name, typed parameters, and whether it moves the arm.

  Built-in kinds register through this same door extensions will use. That is
  the whole reason it exists on day one — `PROGRAMS.md` §4: building a registry
  later, once six kinds are hard-coded across a projection, a source, an
  executor and an editor, is the expensive version of this. Building it now,
  when every entry is built in, costs almost nothing.

  ## Parameters carry physical dimension

  `:velocity`, `:length`, `:angle`, `:duration` are not `:float` with a comment.
  A block editor that knows a socket wants a velocity can offer units; one that
  knows it wants a `:point` can offer the points that exist and refuse
  everything else. And `:point`, `:frame`, `:tool` and `:program` are the types
  that become foreign keys rather than numbers in JSON.
  """

  @reference_types [:point, :frame, :tool, :program]
  @literal_types [:velocity, :length, :angle, :duration, :number, :boolean, :text]

  defstruct [:name, :label, :description, params: [], motion?: false]

  @type param :: %{
          required(:name) => String.t(),
          required(:type) => atom(),
          optional(:required) => boolean(),
          optional(:default) => term(),
          optional(:description) => String.t()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          description: String.t() | nil,
          params: [param()],
          motion?: boolean()
        }

  def reference_types, do: @reference_types
  def literal_types, do: @literal_types

  @doc "Whether this parameter becomes a row in `statement_refs` or a literal."
  def reference?(%{type: type}), do: type in @reference_types

  @doc "The parameter by socket name, or nil."
  def param(%__MODULE__{params: params}, name), do: Enum.find(params, &(&1.name == name))
end
