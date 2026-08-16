defmodule ExAuth.TokensTest do
  use ExAuth.DataCase, async: false

  alias ExAuth.{Accounts, Tokens}

  setup do
    %{account: account_fixture(%{username: "ivan", role: :operator})}
  end

  describe "issue/3" do
    test "returns a prefixed, well-formed token exactly once", %{account: account} do
      assert {:ok, raw, token} = Tokens.issue(account, "studio on the bench")

      assert String.starts_with?(raw, "emo_")
      assert Tokens.well_formed?(raw)

      # The stored row must not contain the credential.
      refute token.token_hash == raw
      refute String.contains?(token.token_hash, String.trim_leading(raw, "emo_"))
    end

    test "two tokens are never the same", %{account: account} do
      {:ok, a, _} = Tokens.issue(account, "one")
      {:ok, b, _} = Tokens.issue(account, "two")
      refute a == b
    end

    test "carries a label, because revocation needs to know which device", %{account: account} do
      {:ok, _raw, token} = Tokens.issue(account, "the tablet Dave lost")
      assert token.label == "the tablet Dave lost"
    end
  end

  describe "verify/1" do
    test "accepts a freshly issued token", %{account: account} do
      {:ok, raw, _} = Tokens.issue(account, "pendant")
      assert {:ok, found, _token} = Tokens.verify(raw)
      assert found.id == account.id
    end

    test "rejects a token that was never issued" do
      assert {:error, :bad_token} = Tokens.verify("emo_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))
    end

    test "rejects garbage without raising" do
      assert {:error, :bad_token} = Tokens.verify("not-a-token")
      assert {:error, :bad_token} = Tokens.verify("")
      assert {:error, :bad_token} = Tokens.verify(nil)
    end

    test "rejects a revoked token", %{account: account} do
      {:ok, raw, token} = Tokens.issue(account, "pendant")
      :ok = Tokens.revoke(token)
      assert {:error, :revoked} = Tokens.verify(raw)
    end

    test "rejects an expired token", %{account: account} do
      {:ok, raw, token} = Tokens.issue(account, "short-lived", expires_in: 60)
      expire!(token)
      assert {:error, :expired} = Tokens.verify(raw)
    end

    test "distinguishes expired from revoked", %{account: account} do
      # Not pedantry: an audit asking why a client stopped working needs to
      # tell "the token ran out" from "somebody took it away".
      {:ok, expired, expiring} = Tokens.issue(account, "a", expires_in: 60)
      expire!(expiring)
      {:ok, revoked, token} = Tokens.issue(account, "b")
      :ok = Tokens.revoke(token)

      assert {:error, :expired} = Tokens.verify(expired)
      assert {:error, :revoked} = Tokens.verify(revoked)
    end

    test "a token with no expiry stays usable", %{account: account} do
      {:ok, raw, token} = Tokens.issue(account, "paired pendant")
      assert is_nil(token.expires_at)
      assert {:ok, _, _} = Tokens.verify(raw)
    end

    test "rejects a token whose account was disabled after issue", %{account: account} do
      {:ok, raw, _} = Tokens.issue(account, "pendant")
      {:ok, _} = Accounts.disable(account)
      # disable/1 revokes, so :revoked is the honest answer here.
      assert {:error, :revoked} = Tokens.verify(raw)
    end
  end

  describe "revoke_all_for_account/1" do
    test "cuts every token at once", %{account: account} do
      raws = for n <- 1..3, do: (fn -> {:ok, raw, _} = Tokens.issue(account, "client #{n}"); raw end).()

      :ok = Tokens.revoke_all_for_account(account.id)

      for raw <- raws do
        assert {:error, :revoked} = Tokens.verify(raw)
      end
    end

    test "leaves another account's tokens alone", %{account: account} do
      other = account_fixture(%{username: "judy"})
      {:ok, mine, _} = Tokens.issue(account, "mine")
      {:ok, theirs, _} = Tokens.issue(other, "theirs")

      :ok = Tokens.revoke_all_for_account(account.id)

      assert {:error, :revoked} = Tokens.verify(mine)
      assert {:ok, _, _} = Tokens.verify(theirs)
    end
  end

  # issue/3 will not mint a token that is already dead, which is correct, so a
  # test that needs an expired one moves the clock on an ordinary token rather
  # than widening the API to accommodate the fixture.
  defp expire!(token) do
    token
    |> Ecto.Changeset.change(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    |> ExStore.Repo.update!()
  end
end
