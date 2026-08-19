defmodule EMotion.Cell.Loaded do
  @moduledoc """
  The chain this controller is, for the whole of this boot.

  `ROBOT.md` argues why loading a robot is a restart: the axis nodes in the
  Information Model come from the chain, so changing the chain changes the
  shape of the address space, and a client subscribed to `axes.j5` on a
  five-axis arm is holding something that no longer exists. That rule is what
  makes this module simple — the chain is read once, cached in
  `:persistent_term`, and never invalidated, because nothing may change it
  while the controller is up.

  It is cached rather than re-read because the callers include a projection
  that runs at up to 30 Hz. Re-parsing a document per read is affordable for
  the 47-line Arctos export and is not for a real one carrying meshes, and the
  cost would arrive as a mysterious slow read rather than as an error.

  ## The fallback is not a third description

  With nothing commissioned, this returns the chain parsed from the URDF this
  build ships in `exmove/priv`, which is the same document `install/0` seeds
  the database with on first boot. It is one description read two ways, not a
  second description — which is the distinction the whole exercise was about.
  """

  require Logger

  alias ExMove.{Chain, URDF}
  alias ExStore.Cell.Robot
  alias ExStore.Robots

  @key {__MODULE__, :chain}
  @shipped :arctos

  @doc "The loaded chain. Parses the shipped description if nothing is commissioned."
  @spec chain() :: Chain.t()
  def chain do
    case :persistent_term.get(@key, nil) do
      nil ->
        chain = shipped()
        :persistent_term.put(@key, chain)
        chain

      chain ->
        chain
    end
  end

  @doc """
  Reads the commissioned robot and caches it for this boot.

  Seeds the store on first boot with the description this build ships, in the
  same spirit as `ExAuth.Provision` minting an administrator: a bench
  controller should come up usable, and a controller that came up refusing to
  say where its own tool is would be useless in a way nobody could diagnose.
  """
  @spec install() :: {:ok, Chain.t()} | {:error, term()}
  def install do
    with {:ok, robot} <- commissioned(),
         {:ok, chain} <- build(robot) do
      :persistent_term.put(@key, chain)
      Logger.info("robot: #{robot.name}, #{length(chain.joints)} axes — #{inspect(chain.axis_ids)}")
      {:ok, chain}
    else
      {:error, reason} ->
        Logger.error(
          "could not load a commissioned robot (#{inspect(reason)}); " <>
            "falling back to the description this build ships"
        )

        {:error, reason}
    end
  end

  @doc "Forgets the cached chain. Tests only — a running controller has one robot."
  def forget, do: :persistent_term.erase(@key)

  # ── Building ──────────────────────────────────────────────────────────────

  defp commissioned do
    case Robots.active() do
      nil -> seed()
      robot -> {:ok, robot}
    end
  end

  defp seed do
    path = Path.join(to_string(:code.priv_dir(:exmove)), "#{@shipped}.urdf")

    with {:ok, urdf} <- File.read(path),
         {:ok, chain} <- URDF.parse_string(urdf, name: @shipped),
         {:ok, robot} <- Robots.store(%{name: to_string(@shipped), urdf: urdf, joints: summary(chain)}),
         :ok <- commission_defaults(robot, chain),
         {:ok, robot} <- Robots.activate(robot) do
      Logger.info("no robot was commissioned; seeded the store with #{robot.name}")
      {:ok, robot}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # The wiring this build has always assumed, said out loud in rows rather than
  # implied by a loader. Everything here is commissioning: which drive, how
  # fast, and how far — none of it is in the drawing, and all of it was
  # previously spread across a compiled config block, a hardcoded map inside
  # the parser and a literal list in the Information Model.
  @default_limits {-3.05, 3.05}
  @default_rates %{
    "joint1" => {1.57, 5.0},
    "joint2" => {1.05, 4.0},
    "joint3" => {1.57, 5.0},
    "joint4" => {2.09, 8.0},
    "joint5" => {2.09, 8.0},
    "joint6" => {3.14, 12.0}
  }

  defp commission_defaults(robot, chain) do
    {soft_lower, soft_upper} = @default_limits

    chain.joints
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {joint, index}, :ok ->
      {max_vel, max_acc} = Map.get(@default_rates, joint.name, {1.0, 4.0})

      attrs = %{
        axis_id: "j#{index}",
        max_vel: joint.max_vel || max_vel,
        max_acc: max_acc,
        soft_lower: soft_lower,
        soft_upper: soft_upper,
        home: 0.0
      }

      case Robots.commission(robot, joint.name, attrs) do
        {:ok, _setting} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, {:commissioning, joint.name, changeset}}}
      end
    end)
  end

  defp build(robot) do
    with {:ok, chain} <- URDF.parse_string(robot.urdf, name: String.to_atom(robot.name)),
         {:ok, axis_ids} <- wiring(robot, chain) do
      {:ok, Chain.wire(%{chain | joints: commissioned_joints(robot, chain)}, axis_ids)}
    end
  end

  # Every joint has to be wired or none of this is servable, and a chain with a
  # hole in its wiring must not quietly become a shorter arm. Naming the joints
  # that are missing is the difference between "commissioning is incomplete"
  # and an arm that moves five of its six axes.
  defp wiring(robot, chain) do
    axis_ids = Robots.axis_ids(robot)

    case Enum.zip(chain.joints, axis_ids) |> Enum.filter(fn {_joint, id} -> is_nil(id) end) do
      [] ->
        {:ok, axis_ids}

      unwired ->
        {:error, {:unwired, Enum.map(unwired, fn {joint, _id} -> joint.name end)}}
    end
  end

  # Commissioning narrows what the drawing allows; it never widens it. The
  # store refuses a soft limit outside the mechanical travel, so taking the
  # commissioned value where there is one is safe by construction rather than
  # by a comparison here that could disagree with the one that wrote it.
  defp commissioned_joints(robot, chain) do
    by_name = Map.new(Robots.settings(robot), &{&1.joint_name, &1})

    Enum.map(chain.joints, fn joint ->
      case Map.get(by_name, joint.name) do
        nil ->
          joint

        setting ->
          %{
            joint
            | limit: travel(setting) || joint.limit,
              max_vel: setting.max_vel || joint.max_vel,
              max_acc: setting.max_acc || joint.max_acc
          }
      end
    end)
  end

  defp travel(%{soft_lower: lower, soft_upper: upper})
       when is_float(lower) and is_float(upper),
       do: {lower, upper}

  defp travel(_setting), do: nil

  defp summary(chain) do
    Enum.map(chain.joints, fn joint ->
      {lower, upper} =
        case joint.limit do
          {lower, upper} -> {lower, upper}
          nil -> {nil, nil}
        end

      %{name: joint.name, lower: lower, upper: upper, max_vel: joint.max_vel}
    end)
  end

  # The shipped description, commissioned the way `seed/0` commissions it.
  #
  # Applying the defaults here rather than returning the bare document is the
  # difference between "what this build ships" and "what this build ships,
  # unconfigured". The Arctos export declares every joint `continuous`, so a
  # bare parse has no travel at all — and a controller that published no joint
  # limits because nobody had written any into the CAD file would be reporting
  # the absence of a rule as the absence of a limit.
  defp shipped do
    {:ok, chain} = URDF.load(@shipped)
    {lower, upper} = @default_limits

    joints =
      Enum.map(chain.joints, fn joint ->
        {max_vel, max_acc} = Map.get(@default_rates, joint.name, {1.0, 4.0})

        %{
          joint
          | limit: joint.limit || {lower, upper},
            max_vel: joint.max_vel || max_vel,
            max_acc: joint.max_acc || max_acc
        }
      end)

    Chain.wire(%{chain | joints: joints}, for(i <- 1..length(joints), do: :"j#{i}"))
  end

  @doc false
  def shipped_name, do: @shipped

  @doc false
  def default_travel, do: @default_limits

  @doc false
  def robot_name(%Robot{name: name}), do: name
end
