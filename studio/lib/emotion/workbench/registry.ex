defmodule EMotion.Workbench.Registry do
  @moduledoc """
  Which workbenches exist.

  Discovered once at boot and cached in `:persistent_term`, because `view/1`
  reads this on every model change and a lookup that walks the code path at
  frame rate would be its own kind of stall.

  ## Discovery

  Every loaded application is scanned for modules implementing
  `EMotion.Workbench`. That means a third party ships a workbench by being a
  dependency — no registration call, no config entry, no plugin manifest.

      def deps do
        [{:welding_bench, "~> 0.1"}]
      end

  and it appears in the switcher.

  Configuration exists to override that, and does two jobs:

      config :emotion_studio,
        workbenches: [Cell.Workbench, Welding.Workbench],
        exclude_workbenches: [Experimental.Workbench]

  An explicit `:workbenches` list disables discovery entirely and fixes the
  order, which is what a shipped, locked-down machine wants. `:exclude` prunes
  from discovery while keeping it, which is what a developer wants.

  ## Why not a supervisor of workbench processes

  Because a workbench is not running. It is a module contributing pure
  functions, instantiated into state only when someone switches to it. A
  workbench that needs something running — a scanner driver, a welding
  controller — starts it under its own application's supervision tree, where
  it belongs, and reaches it through `EMotion.Job` like anything else.
  """

  @key {__MODULE__, :workbenches}

  @doc """
  Discovers workbenches and caches the result.

  Called once from the application's start. Safe to call again; it recomputes.
  """
  @spec refresh() :: [module()]
  def refresh do
    modules = discover()
    :persistent_term.put(@key, modules)
    modules
  end

  @doc "Every known workbench, in switcher order."
  @spec all() :: [module()]
  def all do
    case :persistent_term.get(@key, nil) do
      nil -> refresh()
      modules -> modules
    end
  end

  @doc """
  Looks a workbench up by module or by name.

      Registry.fetch(Welding.Workbench)
      Registry.fetch("Welding")

  Name lookup exists because that is what a saved cell references. Storing a
  module name in a document means renaming a module breaks every file that
  used it.
  """
  @spec fetch(module() | String.t()) :: {:ok, module()} | :error
  def fetch(module) when is_atom(module) do
    if module in all(), do: {:ok, module}, else: :error
  end

  def fetch(name) when is_binary(name) do
    case Enum.find(all(), fn module -> module.name() == name end) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @doc "The first workbench, used when nothing else says otherwise."
  @spec default() :: module() | nil
  def default, do: List.first(all())

  @doc """
  Name and description for each workbench, for rendering a switcher.

  Returns tuples rather than calling back into each module at render time, so
  a workbench whose `name/0` does something silly cannot slow the UI down.
  """
  @spec listing() :: [{module(), String.t(), String.t()}]
  def listing do
    Enum.map(all(), fn module ->
      {module, module.name(), describe(module)}
    end)
  end

  # ==========================================================================

  defp discover do
    case Application.get_env(:emotion_studio, :workbenches) do
      nil ->
        excluded = Application.get_env(:emotion_studio, :exclude_workbenches, [])

        scan()
        |> Enum.reject(&(&1 in excluded))
        # Alphabetical by display name, because discovery order is load order
        # and load order is not something a user can predict or rely on.
        |> Enum.sort_by(& &1.name())

      explicit when is_list(explicit) ->
        Enum.filter(explicit, &EMotion.Workbench.behaviour?/1)
    end
  end

  defp scan do
    for {app, _description, _vsn} <- Application.loaded_applications(),
        modules = modules_of(app),
        module <- modules,
        EMotion.Workbench.behaviour?(module),
        do: module
  end

  defp modules_of(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  defp describe(module) do
    if function_exported?(module, :description, 0), do: module.description(), else: ""
  end
end
