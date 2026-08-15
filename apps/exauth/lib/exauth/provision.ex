defmodule ExAuth.Provision do
  @moduledoc """
  First-boot account creation.

  ## There is no default password

  The single most-cited vulnerability in industrial robotics is a documented
  factory credential: ABB's IRC5 ships `Default User` / `robotics`, which is
  CVE-2020-10287 at CVSS 9.8, filed precisely because the pair appears in
  public manuals. KUKA's smartPAD groups default to `kuka`. Yaskawa's
  MANAGEMENT level defaults to eight nines. Universal Robots ships
  `root`/`easybot`. Every one of these is a real, exploited-in-the-wild
  default, and every one exists because a headless device has to be reachable
  on first boot.

  It has to be reachable. It does not have to be predictable. So on an empty
  account table this generates a random administrator password, prints it once
  in the boot log, and marks it must-change. An operator who never reads the
  log has a controller they cannot administer, which is a support call. A
  controller anyone can administer from a manual is a recall.
  """

  require Logger

  alias ExAuth.Accounts

  @username "admin"

  # Crockford-style: no I, L, O, U. A password read off a serial console and
  # typed into a tablet should not depend on distinguishing 1 from l.
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @groups 5
  @group_size 4

  @doc """
  Ensures an administrator exists.

  Returns `{:created, username, password}` on first boot, or `:exists`
  thereafter. Idempotent: called on every boot, does something once.
  """
  @spec ensure_administrator() :: {:created, String.t(), String.t()} | :exists | {:error, term()}
  def ensure_administrator do
    if Accounts.count() > 0 do
      :exists
    else
      password = generate_password()

      case Accounts.create(%{
             username: @username,
             password: password,
             role: :administrator,
             must_change_password: true
           }) do
        {:ok, account} ->
          announce(account.username, password)
          {:created, account.username, password}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  A random password with roughly 100 bits of entropy.

  Grouped with hyphens because this gets read aloud and typed by hand at least
  once, and an unbroken 20-character string is where that goes wrong.
  """
  @spec generate_password() :: String.t()
  def generate_password do
    1..@groups
    |> Enum.map_join("-", fn _ -> random_group() end)
  end

  defp random_group do
    @group_size
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte -> <<Enum.at(@alphabet, rem(byte, length(@alphabet)))>> end)
  end

  defp announce(username, password) do
    Logger.warning("""

    ┌──────────────────────────────────────────────────────────────────────┐
    │  FIRST BOOT: an administrator account has been created.              │
    └──────────────────────────────────────────────────────────────────────┘

        username  #{username}
        password  #{password}

    This is shown ONCE. It is not stored anywhere in recoverable form and
    cannot be printed again. Write it down now.

    The account is flagged must-change: the first thing it should do is set a
    password of its own, and the second is create accounts for the people who
    will actually use this machine.

    If this password is lost, recovery means physical access to the controller
    and deleting the credential database.
    """)
  end
end
