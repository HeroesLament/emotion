defmodule ExMove.Chain do
  @moduledoc """
  An ordered kinematic chain from base to tip.

  `joints` is base → tip order. Index 0 = first joint from base.
  `axis_ids` maps list index → Exdrive axis_id atom, e.g. [:j1, :j2, ...].
  `tool` is the TCP offset frame from the flange — what somebody bolted on.
  `flange` is the offset from the last actuated joint to where a tool bolts on,
  and it comes from the mechanism rather than from a changeover: a URDF that
  ends in a run of fixed joints is describing exactly this. The two are
  separate because they are owned by different people. `EMotion.Cell` composes
  them into the transform the solver takes.

  The engine works entirely in terms of joint indices. The axis_id mapping
  is only used at the Exdrive boundary when pushing setpoints.
  """

  alias ExMove.Frame

  @enforce_keys [:name, :joints, :axis_ids]
  defstruct [
    name:     nil,   # atom — :arctos
    joints:   [],    # [%Joint{}, ...]  base → tip
    axis_ids: [],    # [:j1, :j2, ...]  parallel to joints
    tool:     %Frame{},  # what is fitted, from the flange
    flange:   %Frame{},  # last actuated joint → tool mounting face, from the URDF
  ]

  @doc "Number of degrees of freedom (non-fixed joints)"
  def dof(%__MODULE__{joints: joints}) do
    Enum.count(joints, &(&1.type != :fixed))
  end

  @doc "Get the axis_id for joint at index i"
  def axis_id(%__MODULE__{axis_ids: ids}, i), do: Enum.at(ids, i)

  @doc "Get joint by axis_id"
  def joint_for(%__MODULE__{joints: joints, axis_ids: ids}, axis_id) do
    case Enum.find_index(ids, &(&1 == axis_id)) do
      nil -> nil
      i   -> Enum.at(joints, i)
    end
  end

  @doc """
  Attaches the drives this chain's joints are wired to, base to tip.

  Separate from parsing on purpose: a URDF describes a mechanism and has never
  seen the installation it will run in, so which drive turns joint 3 is not
  something a document exported from CAD is entitled to decide. Whoever knows
  the wiring says so here.
  """
  def wire(%__MODULE__{joints: joints} = chain, axis_ids) when is_list(axis_ids) do
    if length(axis_ids) == length(joints) do
      %{chain | axis_ids: axis_ids}
    else
      raise ArgumentError,
            "chain #{inspect(chain.name)} has #{length(joints)} joints and was given " <>
              "#{length(axis_ids)} axis ids"
    end
  end

  @doc """
  Zip joints with their axis_ids.

  Raises when they do not line up, rather than zipping to the shorter of the
  two. `Enum.zip/2` on an unwired chain returns an empty list, which reads as
  "no joints to command" and is indistinguishable from success right up until
  nothing moves.
  """
  def joint_pairs(%__MODULE__{joints: joints, axis_ids: ids} = chain) do
    if length(ids) != length(joints) do
      raise ArgumentError,
            "chain #{inspect(chain.name)} has #{length(joints)} joints and " <>
              "#{length(ids)} axis ids; it has not been wired to any drives"
    end

    Enum.zip(ids, joints)
  end
end
