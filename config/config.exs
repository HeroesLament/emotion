# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Arctos 6-DOF arm joint velocity and acceleration limits.
# max_vel: rad/s  — conservative hardware limits, tune per physical drive
# max_acc: rad/s² — used for lookahead deceleration (future)
#
# Source: Arctos stepper specs + 20% safety margin.
# These fill in where the URDF has no <limit velocity="..."> element.
config :exmove, :joint_limits, %{
  "joint1" => %{max_vel: 1.57,  max_acc: 5.0},   # base rotation    ~90°/s
  "joint2" => %{max_vel: 1.05,  max_acc: 4.0},   # shoulder         ~60°/s
  "joint3" => %{max_vel: 1.57,  max_acc: 5.0},   # elbow            ~90°/s
  "joint4" => %{max_vel: 2.09,  max_acc: 8.0},   # wrist roll      ~120°/s
  "joint5" => %{max_vel: 2.09,  max_acc: 8.0},   # wrist pitch     ~120°/s
  "joint6" => %{max_vel: 3.14,  max_acc: 12.0},  # tool rotation   ~180°/s
}

# ── Credentials ─────────────────────────────────────────────────────────────

config :exauth, ecto_repos: [ExAuth.Repo]

# Argon2id parameters are pinned rather than left to the library default, so a
# dependency bump cannot silently change how long a login takes on a Pi or how
# much memory it costs. m_cost 15 is 32 MiB per verification; the default 16 is
# 64 MiB, which is more than a small Nerves target should spend on a login.
# t_cost 3 at 32 MiB lands around 100 ms on a Pi 5 — invisible once per session,
# and expensive enough to matter to anyone with the database.
config :argon2_elixir,
  t_cost: 3,
  m_cost: 15,
  parallelism: 2

import_config "#{config_env()}.exs"
