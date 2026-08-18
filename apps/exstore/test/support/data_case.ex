defmodule ExStore.DataCase do
  @moduledoc """
  Test case with a sandboxed Repo.

  Serial, and not as a workaround — the argument is `ExAuth.DataCase`'s and it
  is unchanged by the database having grown tables. SQLite permits one write
  transaction at a time and the sandbox holds one open for the whole of each
  test, so two async writers do not contend for a moment and retry: one sits on
  the lock and the other gets SQLITE_BUSY, which `busy_timeout` cannot help
  with because there is nothing to wait out.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import ExStore.DataCase

      alias ExStore.Repo
    end
  end

  setup _tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ExStore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    empty()
    :ok
  end

  @doc """
  Empties the database, inside the test's own transaction.

  These tests make statements about the whole store — "nothing is commissioned
  yet", "there is exactly one robot" — and the file they run against is shared
  with sibling apps whose tests are not sandboxed, because the processes they
  exercise are not descendants of the test process. One leaked row over there
  fails a handful of assertions over here, a run later, for no visible reason.

  It rolls back with everything else, so it costs nothing and cleans up after
  anybody.
  """
  def empty do
    for schema <- [
          ExStore.Program.StatementRef,
          ExStore.Program.Statement,
          ExStore.Program.Program,
          ExStore.Cell.Point,
          ExStore.Cell.JointSetting,
          ExStore.Cell.Mastering,
          ExStore.Cell.Robot,
          ExStore.Geometry.Tool
        ] do
      ExStore.Repo.delete_all(schema)
    end

    # Frames reference frames and refuse to orphan a child, so they go leaves
    # first rather than all at once.
    empty_frames()
  end

  defp empty_frames(passes \\ 8) do
    import Ecto.Query

    leaves =
      ExStore.Repo.all(
        from(f in ExStore.Geometry.Frame,
          where: f.id not in subquery(
            from(c in ExStore.Geometry.Frame, where: not is_nil(c.parent_id), select: c.parent_id)
          )
        )
      )

    cond do
      leaves == [] -> :ok
      passes == 0 -> :ok
      true ->
        for leaf <- leaves, do: ExStore.Repo.delete(leaf)
        empty_frames(passes - 1)
    end
  end

  @doc "A frame, with a unique name and whatever attributes are worth stating."
  def frame_fixture(attrs \\ %{}) do
    {:ok, frame} =
      attrs
      |> Enum.into(%{name: "frame#{System.unique_integer([:positive])}"})
      |> ExStore.Frames.create()

    frame
  end

  @doc "A tool, likewise."
  def tool_fixture(attrs \\ %{}) do
    {:ok, tool} =
      attrs
      |> Enum.into(%{name: "tool#{System.unique_integer([:positive])}"})
      |> ExStore.Tools.create()

    tool
  end
end
