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
    :ok
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
