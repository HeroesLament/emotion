defmodule EMotion.Workbench.Command do
  @moduledoc """
  Something a workbench can do, declared rather than wired.

      %Command{id: :add_seam, label: "Add Seam", group: :path, shortcut: "Ctrl+E"}

  The shell renders these into a toolbar and a menu, and sends the workbench a
  `{:command, id}` event when one is chosen. A workbench therefore does not
  build its own toolbar, which is what keeps two workbenches from looking like
  two applications.

  `enabled?` is a function of the context rather than a flag, because whether
  "Simulate" can run depends on the cell — is a robot loaded, is a path
  selected — and a workbench that had to remember to recompute a flag on every
  change would get it wrong. Evaluated during `view/1`, so it must be cheap
  and must not call another process.
  """

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          group: atom(),
          description: String.t() | nil,
          shortcut: String.t() | nil,
          enabled?: (EMotion.Workbench.context() -> boolean())
        }

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    :description,
    :shortcut,
    group: :general,
    enabled?: &__MODULE__.always/1
  ]

  @doc false
  def always(_context), do: true

  @doc """
  Whether a command is available in this context.

  Any error from an `enabled?` function is treated as "not available" rather
  than allowed to escape — it runs inside `view/1`, and a third-party
  workbench with a buggy predicate should grey out its own button, not take
  the window down.
  """
  @spec enabled?(t(), EMotion.Workbench.context()) :: boolean()
  def enabled?(%__MODULE__{enabled?: predicate}, context) do
    predicate.(context) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc "Commands grouped for rendering, preserving declaration order within a group."
  @spec by_group([t()]) :: [{atom(), [t()]}]
  def by_group(commands) do
    commands
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(fn {group, _} -> group end)
  end
end
