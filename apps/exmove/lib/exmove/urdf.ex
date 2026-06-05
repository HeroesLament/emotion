defmodule ExMove.URDF do
  @moduledoc """
  Parse a URDF file into an ExMove.Chain.

  Pure Elixir implementation — no XML library dependency. URDF is parsed
  at startup once and discarded; the engine works only on ExMove types.

  Usage:

      {:ok, chain} = ExMove.URDF.load(:arctos)
      {:ok, chain} = ExMove.URDF.parse_file("/path/to/robot.urdf", name: :myrobot)
  """

  alias ExMove.{Chain, Joint}

  def load(robot_name, opts \\ []) do
    priv = :code.priv_dir(:exmove) |> to_string()
    path = Path.join(priv, "#{robot_name}.urdf")
    opts = Keyword.put_new(opts, :name, robot_name)
    parse_file(path, opts)
  end

  def parse_file(path, opts \\ []) do
    case File.read(path) do
      {:ok, xml}       -> parse_string(xml, opts)
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  def parse_string(xml, opts \\ []) do
    name         = Keyword.get(opts, :name, :robot)
    axis_prefix  = Keyword.get(opts, :axis_prefix, :j)
    joint_filter = Keyword.get(opts, :joints, nil)

    joints   = extract_joints(xml)
    actuated = Enum.filter(joints, &(&1.type in [:revolute, :prismatic]))

    actuated = if joint_filter do
      Enum.filter(actuated, &(&1.name in joint_filter))
    else
      actuated
    end

    axis_ids = actuated
      |> Enum.with_index(1)
      |> Enum.map(fn {_, i} -> :"#{axis_prefix}#{i}" end)

    {:ok, %Chain{name: name, joints: actuated, axis_ids: axis_ids}}
  end

  defp extract_joints(xml) do
    ~r/<joint\s([^>]*)>(.*?)<\/joint>/s
    |> Regex.scan(xml, capture: :all)
    |> Enum.map(fn [_full, attrs_str, body] -> parse_joint(attrs_str, body) end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_joint(attrs_str, body) do
    name = extract_attr(attrs_str, "name")
    type = extract_attr(attrs_str, "type") |> parse_type()
    case name do
      nil -> nil
      _ ->
        origin   = extract_element(body, "origin") |> parse_origin()
        axis     = extract_element(body, "axis")   |> parse_axis()
        limit_el = extract_element(body, "limit")
        limit    = parse_limit(limit_el, type)
        max_vel  = parse_limit_attr(limit_el, "velocity")
        max_acc  = parse_limit_attr(limit_el, "effort")   # effort used as acc proxy when present
        # Apply config fallbacks for this joint name
        {max_vel, max_acc} = apply_config_limits(name, max_vel, max_acc)
        %Joint{id: nil, name: name, type: type, axis: axis,
               origin: origin.xyz, rpy: origin.rpy, limit: limit,
               max_vel: max_vel, max_acc: max_acc}
    end
  end

  defp extract_element(xml, tag) do
    case Regex.run(~r/<#{tag}\s([^>]*)\/>|<#{tag}\s([^>]*)>/s, xml) do
      [_full, attrs, ""] -> attrs
      [_full, "", attrs] -> attrs
      [_full, attrs]     -> attrs
      _                  -> nil
    end
  end

  defp extract_attr(nil, _key), do: nil
  defp extract_attr(attrs_str, key) do
    case Regex.run(~r/#{key}="([^"]*)"/, attrs_str) do
      [_, value] -> value
      _          -> nil
    end
  end

  defp parse_type("revolute"),   do: :revolute
  defp parse_type("continuous"), do: :revolute
  defp parse_type("prismatic"),  do: :prismatic
  defp parse_type("fixed"),      do: :fixed
  defp parse_type(_),            do: :unknown

  defp parse_origin(nil),   do: %{xyz: {0.0, 0.0, 0.0}, rpy: {0.0, 0.0, 0.0}}
  defp parse_origin(attrs), do: %{
    xyz: extract_attr(attrs, "xyz") |> parse_vec3({0.0, 0.0, 0.0}),
    rpy: extract_attr(attrs, "rpy") |> parse_vec3({0.0, 0.0, 0.0}),
  }

  defp parse_axis(nil),   do: {0.0, 0.0, 1.0}
  defp parse_axis(attrs), do: extract_attr(attrs, "xyz") |> parse_vec3({0.0, 0.0, 1.0})

  defp parse_limit(nil, _), do: nil
  defp parse_limit(attrs, _) do
    lo = extract_attr(attrs, "lower") |> parse_float(nil)
    hi = extract_attr(attrs, "upper") |> parse_float(nil)
    if lo && hi, do: {lo, hi}, else: nil
  end

  defp parse_limit_attr(nil, _key), do: nil
  defp parse_limit_attr(attrs, key), do: extract_attr(attrs, key) |> parse_float(nil)

  # Arctos defaults — used when URDF has no <limit velocity="..."> and no
  # application config is present. Tune these per physical drive.
  # Values in rad/s (~conservative stepper limits with 20% safety margin).
  @arctos_defaults %{
    "joint1" => %{max_vel: 1.57,  max_acc: 5.0},
    "joint2" => %{max_vel: 1.05,  max_acc: 4.0},
    "joint3" => %{max_vel: 1.57,  max_acc: 5.0},
    "joint4" => %{max_vel: 2.09,  max_acc: 8.0},
    "joint5" => %{max_vel: 2.09,  max_acc: 8.0},
    "joint6" => %{max_vel: 3.14,  max_acc: 12.0},
  }

  # Apply per-joint velocity/acceleration limits.
  # Priority: URDF value > application config > hardcoded defaults above.
  defp apply_config_limits(joint_name, urdf_vel, urdf_acc) do
    cfg       = Application.get_env(:exmove, :joint_limits, %{})
    joint_cfg = Map.get(cfg, joint_name, %{})
    defaults  = Map.get(@arctos_defaults, joint_name, %{})
    max_vel = urdf_vel || Map.get(joint_cfg, :max_vel) || Map.get(defaults, :max_vel)
    max_acc = urdf_acc || Map.get(joint_cfg, :max_acc) || Map.get(defaults, :max_acc)
    {max_vel, max_acc}
  end

  defp parse_vec3(nil, default), do: default
  defp parse_vec3(str, default) do
    case String.split(str) |> Enum.map(&parse_float(&1, nil)) do
      [x, y, z] when not is_nil(x) and not is_nil(y) and not is_nil(z) -> {x, y, z}
      _ -> default
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float(str, default) do
    case Float.parse(str) do
      {f, _} -> f
      :error  ->
        case Integer.parse(str) do
          {i, _} -> i * 1.0
          :error  -> default
        end
    end
  end
end
