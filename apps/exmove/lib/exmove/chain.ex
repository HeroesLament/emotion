defmodule ExMove.Chain do
  @moduledoc """
  An ordered kinematic chain from base to tip.

  `joints` is base → tip order. Index 0 = first joint from base.
  `axis_ids` maps list index → Exdrive axis_id atom, e.g. [:j1, :j2, ...].
  `tool` is the TCP offset frame from the last joint's origin.

  The engine works entirely in terms of joint indices. The axis_id mapping
  is only used at the Exdrive boundary when pushing setpoints.
  """

  alias ExMove.Frame

  @enforce_keys [:name, :joints, :axis_ids]
  defstruct [
    name:     nil,   # atom — :arctos
    joints:   [],    # [%Joint{}, ...]  base → tip
    axis_ids: [],    # [:j1, :j2, ...]  parallel to joints
    tool:     %Frame{},  # TCP offset from last joint
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

  @doc "Zip joints with their axis_ids"
  def joint_pairs(%__MODULE__{joints: joints, axis_ids: ids}) do
    Enum.zip(ids, joints)
  end
end
