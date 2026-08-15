defmodule ExAuth.AccountsTest do
  use ExAuth.DataCase, async: false

  alias ExAuth.Accounts

  describe "create/1" do
    test "normalises the username" do
      account = account_fixture(%{username: "  Alice  "})
      assert account.username == "alice"
    end

    test "rejects a duplicate username regardless of case" do
      account_fixture(%{username: "bob"})

      assert {:error, changeset} =
               Accounts.create(%{username: "BOB", password: valid_password(), role: :operator})

      assert "has already been taken" in errors_on(changeset).username
    end

    test "rejects a short password" do
      assert {:error, changeset} =
               Accounts.create(%{username: "carol", password: "short", role: :operator})

      assert changeset.errors[:password]
    end

    test "rejects a username with characters that would confuse a log line" do
      for bad <- ["has space", "colon:name", "-leading", "tab\tname"] do
        assert {:error, changeset} =
                 Accounts.create(%{username: bad, password: valid_password(), role: :operator})

        assert changeset.errors[:username], "expected #{inspect(bad)} to be rejected"
      end
    end

    test "rejects an unknown role" do
      assert {:error, changeset} =
               Accounts.create(%{username: "dave", password: valid_password(), role: :wizard})

      assert changeset.errors[:role]
    end

    test "never stores the password in recoverable form" do
      account = account_fixture(%{username: "erin"})

      refute account.password
      assert account.password_hash =~ "$argon2id$"
      refute account.password_hash =~ valid_password()
    end
  end

  describe "verify_password/2" do
    setup do
      %{account: account_fixture(%{username: "frank"})}
    end

    test "accepts the right password", %{account: account} do
      assert {:ok, found} = Accounts.verify_password("frank", valid_password())
      assert found.id == account.id
    end

    test "is case-insensitive on the username, not the password" do
      assert {:ok, _} = Accounts.verify_password("FRANK", valid_password())
      assert {:error, :bad_credentials} = Accounts.verify_password("frank", "CORRECT-HORSE-BATTERY-STAPLE")
    end

    test "rejects the wrong password" do
      assert {:error, :bad_credentials} = Accounts.verify_password("frank", "wrong-password-here")
    end

    test "an unknown user is :bad_credentials, not a distinct answer" do
      assert {:error, :bad_credentials} = Accounts.verify_password("nobody", valid_password())
    end

    test "a disabled account fails only after the password is checked", %{account: account} do
      {:ok, _} = Accounts.disable(account)

      # Right password on a disabled account: the caller learns it is disabled.
      assert {:error, :disabled} = Accounts.verify_password("frank", valid_password())

      # Wrong password on a disabled account must NOT reveal that the account
      # exists at all, so it reports the ordinary failure.
      assert {:error, :bad_credentials} = Accounts.verify_password("frank", "wrong-password-here")
    end

    test "survives non-binary input without raising" do
      assert {:error, :bad_credentials} = Accounts.verify_password(nil, nil)
      assert {:error, :bad_credentials} = Accounts.verify_password("frank", 12_345)
    end
  end

  describe "disable/1" do
    test "revokes tokens as well as the password" do
      account = account_fixture(%{username: "grace"})
      {:ok, raw, _token} = ExAuth.Tokens.issue(account, "pendant")

      assert {:ok, _} = ExAuth.authenticate(raw)
      {:ok, _} = Accounts.disable(account)

      # The point of the test: a disabled account whose tokens still work is
      # not disabled.
      assert {:error, :revoked} = ExAuth.authenticate(raw)
    end
  end

  describe "change_password/2" do
    test "clears the must-change flag" do
      {:ok, account} =
        Accounts.create(%{
          username: "heidi",
          password: valid_password(),
          role: :operator,
          must_change_password: true
        })

      assert account.must_change_password
      {:ok, updated} = Accounts.change_password(account, "a-brand-new-password")
      refute updated.must_change_password
      assert {:ok, _} = Accounts.verify_password("heidi", "a-brand-new-password")
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end
end
