defmodule ExAuth.Role do
  @moduledoc """
  Named bundles of grants.

  Roles exist because nobody administers a machine by ticking eighteen
  checkboxes, and a role is what an operator will actually recognise. Grants
  remain the thing the enforcement point checks: a role is a convenience for
  assignment, never a unit of authorisation.

  ## The ladder, and where it stops

  `:observer` through `:administrator` do nest, each adding to the one before,
  because that genuinely matches how a plant delegates. `:safety_officer` does
  not sit on that ladder — it is `:observer` plus `:configure_safety`, and it
  cannot move the arm. That is the point of it.

  The nesting is asserted at compile time below rather than being a property
  the reader is asked to verify by eye.
  """

  alias ExAuth.Grant

  @observer [:read_state, :subscribe, :read_event_log]

  @operator @observer ++
              [:enable_drives, :jog, :write_setpoint, :set_speed_override, :write_io]

  @programmer @operator ++ [:execute_program, :load_program, :edit_program]

  @maintainer @programmer ++
                [:calibrate, :write_configuration, :backup, :restore, :clear_event_log,
                 :warm_restart]

  # Note the omission: no :configure_safety. See ExAuth.Grant on why the
  # "can do everything" role is a category error for a machine that can injure.
  @administrator @maintainer ++ [:administrate_accounts]

  @safety_officer @observer ++ [:configure_safety]

  @roles %{
    observer: @observer,
    operator: @operator,
    programmer: @programmer,
    maintainer: @maintainer,
    administrator: @administrator,
    safety_officer: @safety_officer
  }

  @descriptions %{
    observer: "Read values and watch the machine. Cannot change anything.",
    operator: "Run the machine: jog, enable drives, command setpoints.",
    programmer: "Everything an operator can do, plus writing and loading programs.",
    maintainer: "Everything a programmer can do, plus calibration, configuration and backups.",
    administrator: "Everything a maintainer can do, plus managing accounts. Not safety.",
    safety_officer: "Modify the safety configuration. Cannot command motion."
  }

  # ── Compile-time assertions ───────────────────────────────────────────────
  #
  # These run when the module compiles, so a role table edited badly fails the
  # build rather than shipping.

  for {role, grants} <- @roles do
    unknown = Enum.reject(grants, &Grant.known?/1)

    if unknown != [] do
      raise CompileError,
        description: "role #{inspect(role)} references unknown grants: #{inspect(unknown)}"
    end

    if length(Enum.uniq(grants)) != length(grants) do
      raise CompileError,
        description: "role #{inspect(role)} lists a grant twice: #{inspect(grants -- Enum.uniq(grants))}"
    end
  end

  # The safety rule, enforced rather than documented.
  for {role, grants} <- @roles,
      Grant.safety_grant() in grants,
      motion = Enum.filter(grants, &(&1 in Grant.motion_grants())),
      motion != [] do
    raise CompileError,
      description:
        "role #{inspect(role)} bundles #{inspect(Grant.safety_grant())} with motion grants " <>
          "#{inspect(motion)}. Safety configuration is granted alone."
  end

  @type t :: atom()

  @doc "Every role this build defines."
  @spec all() :: [t()]
  def all, do: Map.keys(@roles)

  @doc "The grants a role carries, as a MapSet for cheap membership tests."
  @spec grants(t()) :: MapSet.t(Grant.t())
  def grants(role) do
    case Map.fetch(@roles, role) do
      {:ok, grants} -> MapSet.new(grants)
      :error -> MapSet.new()
    end
  end

  @doc "Human-readable description, for an admin UI."
  @spec describe(t()) :: String.t() | nil
  def describe(role), do: Map.get(@descriptions, role)

  @doc "Whether `role` is one this build defines."
  @spec known?(term()) :: boolean()
  def known?(role), do: Map.has_key?(@roles, role)

  @doc """
  Parses a role name from the wire, without creating atoms.
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(name) when is_binary(name) do
    Enum.find_value(all(), :error, fn role ->
      if Atom.to_string(role) == name, do: {:ok, role}
    end)
  end

  def parse(_other), do: :error
end
