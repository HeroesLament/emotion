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

# Joint velocity and acceleration limits used to live here, as a map keyed by
# URDF joint name. They are rows now — `joint_settings` in the controller's
# database — because they are facts about one installation and this file is
# compiled into a release. See `protocol/ROBOT.md`: the URDF describes the
# mechanism, commissioning describes the machine, and an integrator who has to
# cut a new release to slow an axis down has been handed a maintenance problem
# disguised as a configuration system.

# ── Credentials ─────────────────────────────────────────────────────────────

config :exstore, ecto_repos: [ExStore.Repo]

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
