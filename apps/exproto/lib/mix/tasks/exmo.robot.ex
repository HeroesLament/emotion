defmodule Mix.Tasks.Exmo.Robot do
  @moduledoc """
  Loads and inspects the robot description this controller is commissioned with.

      mix exmo.robot list
      mix exmo.robot load <path.urdf> [--name arctos] [--activate]
      mix exmo.robot show [name]
      mix exmo.robot wire <joint> <axis> [--name arctos]
      mix exmo.robot limit <joint> <lower> <upper> [--name arctos]

  A URDF is a document, not an argument, so it arrives here rather than over
  JSON-RPC — the same reasoning `PROGRAMS.md` gives for program bodies, which
  is that a file of tens of kilobytes has no business in a frame competing with
  a 30 Hz position stream. When an HTTP body transfer exists this task becomes
  a client of it.

  ## Loading takes effect at the next restart

  The axis nodes in the Information Model come from the loaded chain, so
  changing the robot changes the shape of the address space and cannot happen
  underneath a running controller. `ROBOT.md` argues why that is the rule
  rather than a limitation. This task says so every time it changes something.

  ## Runs alongside a live controller

  Starts only `:exstore`, so it does not contend for the ports or the OPC UA
  server a running controller already holds. It writes to the same database.
  """

  @shortdoc "Load a URDF, and see what the controller is commissioned with"

  use Mix.Task

  alias ExMove.URDF
  alias ExStore.Cell.Robot
  alias ExStore.Robots

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:exstore)

    {opts, args, _invalid} =
      OptionParser.parse(argv, strict: [name: :string, activate: :boolean])

    case args do
      ["list"] -> list()
      ["load", path] -> load(path, opts)
      ["show"] -> show(active_or_named(opts))
      ["show", name] -> show(Robots.by_name(name))
      ["wire", joint, axis] -> wire(active_or_named(opts), joint, axis)
      ["limit", joint, lower, upper] -> limit(active_or_named(opts), joint, lower, upper)
      _unknown -> Mix.shell().info(@moduledoc)
    end
  end

  defp list do
    case Robots.list() do
      [] ->
        Mix.shell().info("\n  no robot descriptions stored\n")

      robots ->
        Mix.shell().info("")

        for robot <- robots do
          mark = if robot.active, do: "*", else: " "
          joints = length(Robot.joint_names(robot))
          Mix.shell().info("  #{mark} #{pad(robot.name)} #{joints} axes, #{byte_size(robot.urdf)} bytes")
        end

        Mix.shell().info("\n  * is the one this controller is\n")
    end
  end

  defp load(path, opts) do
    with {:ok, urdf} <- File.read(path),
         {:ok, chain} <- URDF.parse_string(urdf, name: :probe) do
      name = Keyword.get(opts, :name) || Path.basename(path, ".urdf")

      case Robots.store(%{name: name, urdf: urdf, joints: summary(chain)}) do
        {:ok, robot} ->
          Mix.shell().info("\n  stored #{robot.name}: #{length(chain.joints)} axes")
          for joint <- chain.joints, do: Mix.shell().info("    #{joint.name}")

          if Keyword.get(opts, :activate, false) do
            {:ok, _} = Robots.activate(robot)
            Mix.shell().info("\n  loaded. Restart the controller: the axis nodes come from the")
            Mix.shell().info("  chain, so the address space changes shape with it.\n")
          else
            Mix.shell().info("\n  not loaded — `mix exmo.robot load #{path} --activate` does that.\n")
          end

          unwired(robot)

        {:error, changeset} ->
          errors(changeset)
      end
    else
      {:error, {reason, message}} ->
        # The parser's refusals name the element that caused them, which is the
        # whole point of them; printing the reason as well gives a script
        # something to match on.
        Mix.shell().error("\n  refused (#{reason}): #{message}\n")

      {:error, posix} ->
        Mix.shell().error("\n  cannot read #{path}: #{:file.format_error(posix)}\n")
    end
  end

  defp show(nil), do: Mix.shell().error("\n  no such robot\n")

  defp show(robot) do
    Mix.shell().info("\n  #{robot.name}#{if robot.active, do: " (loaded)", else: ""}\n")
    settings = Map.new(Robots.settings(robot), &{&1.joint_name, &1})

    for joint <- Robot.joints(robot) do
      setting = Map.get(settings, joint["name"])

      Mix.shell().info(
        "  #{pad(joint["name"])} #{pad(axis(setting), 6)}" <>
          "#{pad(travel(joint, setting), 24)}#{rate(setting)}"
      )
    end

    Mix.shell().info("")
    unwired(robot)
  end

  defp wire(nil, _joint, _axis), do: Mix.shell().error("\n  no robot loaded\n")

  defp wire(robot, joint, axis) do
    case Robots.commission(robot, joint, %{axis_id: axis}) do
      {:ok, _setting} ->
        Mix.shell().info("\n  #{joint} is #{axis} — takes effect at the next restart\n")

      {:error, changeset} ->
        errors(changeset)
    end
  end

  defp limit(nil, _joint, _lower, _upper), do: Mix.shell().error("\n  no robot loaded\n")

  defp limit(robot, joint, lower, upper) do
    with {lower, ""} <- Float.parse(lower),
         {upper, ""} <- Float.parse(upper) do
      case Robots.commission(robot, joint, %{soft_lower: lower, soft_upper: upper}) do
        {:ok, _setting} ->
          Mix.shell().info("\n  #{joint} travels #{lower}..#{upper} — takes effect at the next restart\n")

        {:error, changeset} ->
          errors(changeset)
      end
    else
      _not_a_number -> Mix.shell().error("\n  limits are radians, as numbers\n")
    end
  end

  defp active_or_named(opts) do
    case Keyword.get(opts, :name) do
      nil -> Robots.active()
      name -> Robots.by_name(name)
    end
  end

  # Named rather than counted, because "3 joints are unwired" tells nobody
  # which drive to go and look at.
  defp unwired(robot) do
    missing =
      robot
      |> Robot.joint_names()
      |> Enum.reject(fn name ->
        setting = Robots.setting(robot, name)
        setting && setting.axis_id
      end)

    if missing != [] do
      Mix.shell().error("  unwired: #{Enum.join(missing, ", ")}")
      Mix.shell().error("  a robot with an unwired joint will not load — `mix exmo.robot wire <joint> <axis>`\n")
    end
  end

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

  defp axis(nil), do: "—"
  defp axis(%{axis_id: nil}), do: "—"
  defp axis(%{axis_id: axis_id}), do: axis_id

  defp travel(joint, setting) do
    case {joint["lower"], joint["upper"], setting && setting.soft_lower, setting && setting.soft_upper} do
      {_lo, _hi, soft_lo, soft_hi} when is_float(soft_lo) and is_float(soft_hi) ->
        "#{fmt(soft_lo)}..#{fmt(soft_hi)} rad (soft)"

      {lo, hi, _soft_lo, _soft_hi} when is_number(lo) and is_number(hi) ->
        "#{fmt(lo)}..#{fmt(hi)} rad"

      _continuous ->
        "continuous"
    end
  end

  defp rate(nil), do: ""
  defp rate(%{max_vel: nil}), do: ""
  defp rate(%{max_vel: max_vel}), do: "#{fmt(max_vel)} rad/s"

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 2)

  defp pad(string, width \\ 14), do: String.pad_trailing(to_string(string), width)

  defp errors(changeset) do
    Mix.shell().error("")

    for {field, messages} <- Ecto.Changeset.traverse_errors(changeset, & &1),
        message <- messages do
      Mix.shell().error("  #{field} #{message}")
    end

    Mix.shell().error("")
  end
end
