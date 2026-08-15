defmodule ExAuth.ProvisionTest do
  use ExAuth.DataCase, async: false

  import ExUnit.CaptureLog

  alias ExAuth.Accounts.Account
  alias ExAuth.Provision

  # These tests are about what happens on a controller that has never been
  # provisioned, so they need an empty table — not a table that happens to be
  # empty. The delete runs inside the sandbox transaction and is rolled back,
  # so it establishes the precondition without destroying anything committed by
  # a sibling app's suite.
  setup do
    Repo.delete_all(Account)
    :ok
  end

  test "creates an administrator on an empty database and prints the password once" do
    log = capture_log(fn -> assert {:created, "admin", _pw} = Provision.ensure_administrator() end)

    assert log =~ "FIRST BOOT"
    assert log =~ "admin"
  end

  test "the generated password is not a constant" do
    # If this ever fails, someone has introduced a default credential. That is
    # CVE-2020-10287 on ABB's IRC5, and it is the single most exploited class
    # of bug in industrial robotics.
    passwords = for _ <- 1..50, do: Provision.generate_password()
    assert length(Enum.uniq(passwords)) == 50
  end

  test "the generated password avoids characters that get misread aloud" do
    for _ <- 1..20 do
      password = Provision.generate_password()
      refute password =~ ~r/[ILOU]/
      assert String.length(password) >= 20
    end
  end

  test "the generated password satisfies the account validation it will be used with" do
    password = Provision.generate_password()
    assert String.length(password) >= ExAuth.Accounts.Account.min_password_length()
  end

  test "is idempotent — a second boot does not create a second administrator" do
    capture_log(fn -> assert {:created, _, _} = Provision.ensure_administrator() end)
    assert :exists = Provision.ensure_administrator()
    assert ExAuth.Accounts.count() == 1
  end

  test "the administrator it creates must change its password" do
    capture_log(fn -> Provision.ensure_administrator() end)
    admin = ExAuth.Accounts.get_by_username("admin")

    assert admin.must_change_password
    assert admin.role == :administrator
  end

  test "the administrator cannot configure safety" do
    capture_log(fn -> Provision.ensure_administrator() end)
    admin = ExAuth.Accounts.get_by_username("admin")
    principal = ExAuth.Principal.new(admin)

    refute ExAuth.can?(principal, :configure_safety)
    assert ExAuth.can?(principal, :administrate_accounts)
  end

  test "the password it generates actually works to log in" do
    {:created, username, password} =
      capture_log_value(fn -> Provision.ensure_administrator() end)

    assert {:ok, principal, _token} = ExAuth.login(username, password)
    assert principal.role == :administrator
  end

  defp capture_log_value(fun) do
    result = :erlang.make_ref()
    Process.put(result, nil)
    capture_log(fn -> Process.put(result, fun.()) end)
    Process.get(result)
  end
end
