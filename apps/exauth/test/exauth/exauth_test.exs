defmodule ExAuthTest do
  use ExAuth.DataCase, async: false

  alias ExAuth.{Principal, Throttle}

  setup do
    %{account: account_fixture(%{username: "kim", role: :operator})}
  end

  describe "login/3" do
    test "exchanges a password for a token and a principal" do
      assert {:ok, %Principal{} = principal, raw} =
               ExAuth.login("kim", valid_password(), label: "studio")

      assert principal.username == "kim"
      assert principal.role == :operator
      assert String.starts_with?(raw, "emo_")
    end

    test "the token it returns authenticates" do
      {:ok, _, raw} = ExAuth.login("kim", valid_password())
      assert {:ok, principal} = ExAuth.authenticate(raw)
      assert principal.username == "kim"
    end

    test "a wrong password reports nothing useful" do
      assert {:error, :bad_credentials} = ExAuth.login("kim", "wrong-password-here")
    end

    test "an unknown user is indistinguishable from a wrong password" do
      assert {:error, :bad_credentials} = ExAuth.login("nobody", valid_password())
    end

    test "records the login time" do
      assert {:ok, _, _} = ExAuth.login("kim", valid_password())
      assert ExAuth.Accounts.get_by_username("kim").last_login_at
    end
  end

  describe "throttling" do
    test "locks out after repeated failures and says for how long" do
      for _ <- 1..5, do: ExAuth.login("kim", "wrong-password-here")

      assert {:error, {:throttled, seconds}} = ExAuth.login("kim", "wrong-password-here")
      assert seconds > 0
    end

    test "the lock applies to the correct password too" do
      # The whole point: an attacker who guesses right on attempt 20 must not
      # be let in just because the guess happened to be correct.
      for _ <- 1..6, do: ExAuth.login("kim", "wrong-password-here")
      assert {:error, {:throttled, _}} = ExAuth.login("kim", valid_password())
    end

    test "a success clears the counter" do
      for _ <- 1..3, do: ExAuth.login("kim", "wrong-password-here")
      assert {:ok, _, _} = ExAuth.login("kim", valid_password())

      # Back to a clean slate: three more failures must not trip the lock.
      for _ <- 1..3, do: ExAuth.login("kim", "wrong-password-here")
      assert {:error, :bad_credentials} = ExAuth.login("kim", "wrong-password-here")
    end

    test "the peer address is throttled as well as the username" do
      # Spraying many usernames from one address must also stall, or a
      # username-only counter is trivially walked around.
      for n <- 1..6 do
        ExAuth.login("user-#{n}", "wrong-password-here", peer: {192, 168, 1, 50})
      end

      assert {:error, {:throttled, _}} =
               ExAuth.login("kim", valid_password(), peer: {192, 168, 1, 50})

      # A different address is unaffected.
      assert {:ok, _, _} = ExAuth.login("kim", valid_password(), peer: {192, 168, 1, 51})
    end

    test "backoff doubles and then caps" do
      assert Throttle.lock_seconds(1) == 0
      assert Throttle.lock_seconds(4) == 0
      assert Throttle.lock_seconds(5) == 1
      assert Throttle.lock_seconds(6) == 2
      assert Throttle.lock_seconds(7) == 4
      # Capped, so an operator locked out mid-incident is not locked out forever.
      assert Throttle.lock_seconds(100) == 300
    end

    test "token authentication is not throttled" do
      {:ok, _, raw} = ExAuth.login("kim", valid_password())
      for _ <- 1..20, do: ExAuth.authenticate("emo_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))
      assert {:ok, _} = ExAuth.authenticate(raw)
    end
  end

  describe "authorisation" do
    test "an operator may command motion but not calibrate" do
      {:ok, principal, _} = ExAuth.login("kim", valid_password())

      assert ExAuth.can?(principal, :write_setpoint)
      assert ExAuth.can?(principal, :jog)
      refute ExAuth.can?(principal, :calibrate)
      refute ExAuth.can?(principal, :configure_safety)
    end

    test "authorize/2 is with-friendly" do
      {:ok, principal, _} = ExAuth.login("kim", valid_password())

      assert :ok = ExAuth.authorize(principal, :jog)
      assert {:error, {:forbidden, :calibrate}} = ExAuth.authorize(principal, :calibrate)
    end

    test "describe/1 carries identity and no credential" do
      {:ok, principal, raw} = ExAuth.login("kim", valid_password())
      described = Principal.describe(principal)

      assert described =~ "kim"
      assert described =~ "operator"
      refute described =~ raw
    end
  end

  describe "revoke_sessions/1" do
    test "cuts open credentials so a role change cannot be outrun", %{account: account} do
      {:ok, _, raw} = ExAuth.login("kim", valid_password())
      assert {:ok, _} = ExAuth.authenticate(raw)

      {:ok, _} = ExAuth.Accounts.change_role(account, :observer)
      :ok = ExAuth.revoke_sessions(account.id)

      assert {:error, :revoked} = ExAuth.authenticate(raw)

      {:ok, principal, _} = ExAuth.login("kim", valid_password())
      assert principal.role == :observer
      refute ExAuth.can?(principal, :jog)
    end
  end
end
