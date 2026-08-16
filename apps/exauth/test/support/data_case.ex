defmodule ExAuth.DataCase do
  @moduledoc """
  Test case with a sandboxed Repo and account helpers.

  ## These tests are serial, and that is not a workaround

  SQLite permits exactly one write transaction at a time, and the Ecto sandbox
  holds one open for the entire duration of each test. Two async tests that
  both write therefore do not contend for a moment and retry — one of them sits
  on the lock until it finishes, and the other gets SQLITE_BUSY. `busy_timeout`
  cannot help, because there is nothing to wait out.

  Setting `async: true` here produces a suite that passes about four runs in
  five, which is the worst possible outcome: too green to investigate, too red
  to trust. So this template ignores the `:async` tag and always takes the
  sandbox in shared mode. The whole suite runs in well under a second; there is
  nothing to buy back.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import ExAuth.DataCase

      alias ExStore.Repo
    end
  end

  setup _tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ExStore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    ExAuth.Throttle.reset_all()
    :ok
  end

  @doc "A valid password, long enough to pass validation."
  def valid_password, do: "correct-horse-battery-staple"

  @doc "Creates an account, raising on failure."
  def account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> Enum.into(%{
        username: "user#{System.unique_integer([:positive])}",
        password: valid_password(),
        role: :operator
      })
      |> ExAuth.Accounts.create()

    account
  end
end
