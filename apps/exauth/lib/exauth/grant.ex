defmodule ExAuth.Grant do
  @moduledoc """
  The vocabulary of things a principal may be permitted to do.

  ## Why discrete grants rather than a privilege level

  A ladder — observer below operator below administrator — cannot express the
  permissions this machine actually needs, because they are not ordered. A
  safety officer must configure the safety system and must not jog the arm. A
  line operator must jog the arm and must never touch calibration. On a ladder
  one of those is impossible to say.

  The shape here follows ABB's User Authorization System, which is the most
  thoroughly exercised grant list in industrial robotics: discrete named
  permissions, roles as bundles of them, and the enforcement point taking a
  grant rather than a role. Adopting a proven vocabulary also means an
  integrator who has configured UAS can read this one.

  ## The rule about safety

  `:configure_safety` is in no bundle that grants motion, and in particular it
  is NOT in `:administrator`. ABB does the same thing — their `FullAccess`
  grant deliberately excludes Safety Controller configuration — and the reason
  is that "the person who can do everything" is a category that should not
  exist for a machine that can injure someone. Changing a safety limit is a
  deliberate, separately authorised act, and when the key-switch hardware
  arrives this is the grant it gates.

  ## Grants are not safety

  A grant check prevents mistakes and casual access. It is not a protective
  measure and must never be load-bearing for anyone's physical safety; that is
  what the E-stop and the safety-rated circuit are for. See `protocol/DESIGN.md`
  on the functional/protective split.
  """

  @grants %{
    # ── Observation ─────────────────────────────────────────────────────────
    read_state: "Read observable values from the information model.",
    subscribe: "Open subscriptions and receive value notifications.",
    read_event_log: "Read the controller event and audit log.",

    # ── Motion ──────────────────────────────────────────────────────────────
    enable_drives: "Transition drives into and out of Operation Enabled.",
    jog: "Command manual motion from a pendant.",
    write_setpoint: "Write position, velocity or torque targets.",
    set_speed_override: "Change the global speed override.",
    write_io: "Write digital and analogue outputs.",

    # ── Programs ────────────────────────────────────────────────────────────
    execute_program: "Start, pause and stop a loaded program.",
    load_program: "Load and unload programs.",
    edit_program: "Create and modify program source.",

    # ── Maintenance ─────────────────────────────────────────────────────────
    calibrate: "Write calibration constants and joint offsets.",
    write_configuration: "Change controller configuration.",
    backup: "Take a controller backup.",
    restore: "Restore a controller backup.",
    clear_event_log: "Clear the event log.",
    warm_restart: "Restart the controller runtime.",

    # ── Administration ──────────────────────────────────────────────────────
    administrate_accounts: "Create, modify and disable accounts and tokens.",

    # ── Safety: granted alone, never inherited ──────────────────────────────
    configure_safety: "Modify the safety configuration."
  }

  @all Map.keys(@grants)

  @type t :: atom()

  @doc "Every grant this build knows about."
  @spec all() :: [t()]
  def all, do: @all

  @doc "Human-readable description of a grant, for an admin UI and the docs."
  @spec describe(t()) :: String.t() | nil
  def describe(grant), do: Map.get(@grants, grant)

  @doc "Whether `grant` is one this build defines."
  @spec known?(term()) :: boolean()
  def known?(grant), do: Map.has_key?(@grants, grant)

  @doc """
  The grant that must never be bundled with motion.

  Exposed as a function rather than left implicit so `ExAuth.Role` can assert
  the rule at compile time instead of relying on whoever edits the role table
  next remembering it.
  """
  @spec safety_grant() :: t()
  def safety_grant, do: :configure_safety

  @doc "Grants that command physical movement."
  @spec motion_grants() :: [t()]
  def motion_grants, do: [:enable_drives, :jog, :write_setpoint, :execute_program]

  @doc """
  Parses a grant from the wire.

  Never `String.to_atom/1` — that is unbounded atom creation driven by a remote
  peer. Only names this build already defines can be produced.
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(name) when is_binary(name) do
    Enum.find_value(@all, :error, fn grant ->
      if Atom.to_string(grant) == name, do: {:ok, grant}
    end)
  end

  def parse(_other), do: :error
end
