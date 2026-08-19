defmodule Mix.Tasks.Emotion.Account do
  @moduledoc """
  Administers controller accounts.

      mix emotion.account list
      mix emotion.account create <username> --role operator
      mix emotion.account passwd <username>
      mix emotion.account role <username> <role>
      mix emotion.account disable <username>
      mix emotion.account enable <username>
      mix emotion.account tokens <username>
      mix emotion.account revoke <username>

  Passwords are generated, never taken as an argument. A password on a command
  line ends up in shell history, in `ps` output for as long as the process
  lives, and in whatever ships those somewhere central — three copies of a
  credential nobody meant to make.

  ## Runs alongside a live controller

  Starts only `:exauth`, not the whole umbrella, so it does not try to bind
  ports a running controller already holds. It talks to the same database.
  """

  @shortdoc "Create, list and modify controller accounts"

  use Mix.Task

  alias ExAuth.{Accounts, Provision, Role, Tokens}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:exauth)

    {opts, args, _} = OptionParser.parse(argv, strict: [role: :string])

    case args do
      ["list"] -> list()
      ["create", username] -> create(username, Keyword.get(opts, :role, "operator"))
      ["passwd", username] -> passwd(username)
      ["role", username, role] -> set_role(username, role)
      ["disable", username] -> disable(username)
      ["enable", username] -> enable(username)
      ["tokens", username] -> tokens(username)
      ["revoke", username] -> revoke(username)
      _ -> usage()
    end
  end

  defp list do
    case Accounts.list() do
      [] ->
        Mix.shell().info("no accounts")

      accounts ->
        Mix.shell().info("")
        Mix.shell().info(row("USERNAME", "ROLE", "STATUS", "LAST LOGIN"))

        for a <- accounts do
          status =
            cond do
              a.disabled_at -> "disabled"
              a.must_change_password -> "must change pw"
              true -> "active"
            end

          Mix.shell().info(row(a.username, to_string(a.role), status, stamp(a.last_login_at)))
        end

        Mix.shell().info("")
    end
  end

  defp create(username, role) do
    with {:ok, role} <- parse_role(role) do
      password = Provision.generate_password()

      case Accounts.create(%{username: username, password: password, role: role}) do
        {:ok, account} ->
          announce(account.username, role, password)

        {:error, changeset} ->
          Mix.shell().error("could not create #{username}:")

          for {field, {message, _}} <- changeset.errors do
            Mix.shell().error("  #{field} #{message}")
          end
      end
    end
  end

  defp passwd(username) do
    with {:ok, account} <- fetch(username) do
      password = Provision.generate_password()

      case Accounts.change_password(account, password) do
        {:ok, _updated} ->
          # Every token this account holds is cut. A password reset that leaves
          # working bearer tokens behind has not locked anyone out of anything,
          # which is usually the entire reason for resetting it.
          :ok = ExAuth.revoke_sessions(account.id)
          announce(account.username, account.role, password)
          Mix.shell().info("Existing tokens for this account have been revoked.")

        {:error, changeset} ->
          Mix.shell().error("could not change password: #{inspect(changeset.errors)}")
      end
    end
  end

  defp set_role(username, role) do
    with {:ok, account} <- fetch(username),
         {:ok, role} <- parse_role(role) do
      {:ok, _updated} = Accounts.change_role(account, role)

      # Grants are frozen into a principal when a connection authenticates, so
      # a role change does not reach a session already open. Cutting the tokens
      # is what makes the change take effect rather than take effect eventually.
      :ok = ExAuth.revoke_sessions(account.id)

      Mix.shell().info("#{username} is now #{role}; its tokens were revoked so the change applies.")
    end
  end

  defp disable(username) do
    with {:ok, account} <- fetch(username) do
      {:ok, _} = Accounts.disable(account)
      Mix.shell().info("#{username} disabled and all its tokens revoked.")
    end
  end

  defp enable(username) do
    with {:ok, account} <- fetch(username) do
      {:ok, _} = Accounts.enable(account)
      Mix.shell().info("#{username} enabled. It has no tokens; it must log in again.")
    end
  end

  defp tokens(username) do
    with {:ok, account} <- fetch(username) do
      case Tokens.list_for_account(account.id) do
        [] ->
          Mix.shell().info("#{username} holds no tokens")

        tokens ->
          Mix.shell().info("")
          Mix.shell().info(row("LABEL", "ISSUED", "LAST USED", "STATE"))

          for t <- tokens do
            state =
              cond do
                t.revoked_at -> "revoked"
                t.expires_at && DateTime.compare(t.expires_at, DateTime.utc_now()) != :gt -> "expired"
                true -> "valid"
              end

            Mix.shell().info(row(t.label, stamp(t.inserted_at), stamp(t.last_used_at), state))
          end

          Mix.shell().info("")
      end
    end
  end

  defp revoke(username) do
    with {:ok, account} <- fetch(username) do
      :ok = ExAuth.revoke_sessions(account.id)
      Mix.shell().info("all tokens for #{username} revoked; it can still log in with its password.")
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp fetch(username) do
    case Accounts.get_by_username(username) do
      nil ->
        Mix.shell().error("no such account: #{username}")
        :error

      account ->
        {:ok, account}
    end
  end

  defp parse_role(role) do
    case Role.parse(role) do
      {:ok, role} ->
        {:ok, role}

      :error ->
        Mix.shell().error("unknown role: #{role}")
        Mix.shell().error("known roles: #{Enum.map_join(Role.all(), ", ", &to_string/1)}")
        :error
    end
  end

  defp announce(username, role, password) do
    Mix.shell().info("""

        username  #{username}
        role      #{role}
        password  #{password}

    Shown once. It is stored only as an Argon2id hash and cannot be printed
    again; `mix emotion.account passwd #{username}` issues a new one.
    """)
  end

  defp row(a, b, c, d) do
    "  " <>
      String.pad_trailing(a, 22) <>
      String.pad_trailing(b, 16) <> String.pad_trailing(c, 16) <> d
  end

  defp stamp(nil), do: "—"
  defp stamp(dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_string()

  defp usage do
    Mix.shell().info(@moduledoc)
  end
end
