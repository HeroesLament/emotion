defmodule Exdrive.Cia402 do
  @moduledoc """
  CiA 402 constants, status word encoding, and mode definitions.

  Control word (object 0x6040) and status word (object 0x6041) are 16-bit.

  IMPORTANT: Control word decoding is intentionally NOT done here.
  The same raw control word value means different things in different
  states. Decoding is handled per-state in Drive, by matching on the
  raw integer directly. This module provides status word encoding,
  mode constants, and object dictionary reference values only.

  Modes of Operation (object 0x6060):
    1  = Profile Position Mode       (PP)
    3  = Profile Velocity Mode       (PV)
    4  = Profile Torque Mode         (PT)
    6  = Homing Mode                 (HM)
    7  = Interpolated Position Mode  (IP)
    8  = Cyclic Sync Position Mode   (CSP)
    9  = Cyclic Sync Velocity Mode   (CSV)
    10 = Cyclic Sync Torque Mode     (CST)
  """

  # --- Status word values (object 0x6041) -----------------------------------
  # These are the masked status patterns per CiA 402 state machine.
  # Bits 0-3 and 5-6 carry state; other bits carry flags (warning, etc.)

  @status_not_ready_to_switch_on  0x0000
  @status_switch_on_disabled      0x0040
  @status_ready_to_switch_on      0x0021
  @status_switched_on             0x0023
  @status_operation_enabled       0x0027
  @status_fault                   0x0008
  @status_fault_reaction_active   0x000F
  @status_quick_stop_active       0x0017

  @doc "Encode a state atom into its CiA 402 status word value"
  def encode_status_word(:not_ready_to_switch_on),  do: @status_not_ready_to_switch_on
  def encode_status_word(:switch_on_disabled),      do: @status_switch_on_disabled
  def encode_status_word(:ready_to_switch_on),      do: @status_ready_to_switch_on
  def encode_status_word(:switched_on),             do: @status_switched_on
  def encode_status_word(:operation_enabled),       do: @status_operation_enabled
  def encode_status_word(:fault),                   do: @status_fault
  def encode_status_word(:fault_reaction_active),   do: @status_fault_reaction_active
  def encode_status_word(:quick_stop_active),       do: @status_quick_stop_active

  # --- Modes of operation (object 0x6060) -----------------------------------

  @modes %{
    profile_position:     1,
    profile_velocity:     3,
    profile_torque:       4,
    homing:               6,
    interpolated_position: 7,
    cyclic_sync_position: 8,
    cyclic_sync_velocity: 9,
    cyclic_sync_torque:   10,
  }

  @doc "Encode a mode atom to its object 0x6060 integer value"
  def encode_mode(mode), do: Map.fetch!(@modes, mode)

  @doc "Decode an object 0x6060 integer to a mode atom"
  def decode_mode(1),  do: :profile_position
  def decode_mode(3),  do: :profile_velocity
  def decode_mode(4),  do: :profile_torque
  def decode_mode(6),  do: :homing
  def decode_mode(7),  do: :interpolated_position
  def decode_mode(8),  do: :cyclic_sync_position
  def decode_mode(9),  do: :cyclic_sync_velocity
  def decode_mode(10), do: :cyclic_sync_torque
  def decode_mode(n),  do: {:unknown, n}

  @doc "All supported modes"
  def modes, do: Map.keys(@modes)

  # --- Object dictionary reference ------------------------------------------
  # Key CiA 402 object indices for documentation purposes

  @object_dictionary %{
    control_word:              0x6040,
    status_word:               0x6041,
    modes_of_operation:        0x6060,
    modes_of_operation_display: 0x6061,
    position_demand:           0x6062,
    position_actual:           0x6064,
    following_error_window:    0x6065,
    following_error_timeout:   0x6066,
    velocity_demand:           0x606B,
    velocity_actual:           0x606C,
    target_torque:             0x6071,
    torque_actual:             0x6077,
    target_position:           0x607A,
    profile_velocity:          0x6081,
    profile_acceleration:      0x6083,
    profile_deceleration:      0x6084,
    quick_stop_deceleration:   0x6085,
    homing_method:             0x6098,
    homing_speed:              0x6099,
    homing_acceleration:       0x609A,
    target_velocity:           0x60FF,
    supported_modes:           0x6502,
  }

  @doc "Look up an object dictionary index by name"
  def object(name), do: Map.fetch!(@object_dictionary, name)
end
