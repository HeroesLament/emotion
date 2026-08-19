defmodule ExMove.URDF do
  @moduledoc """
  A URDF document, read into an `ExMove.Chain`.

  See `protocol/ROBOT.md`. In short: the URDF is the one description of the
  mechanism, the controller stores the document rather than a normalised copy
  of it, and everything about the *installation* — which drive is which joint,
  how fast this arm may move in this cell, where home is — lives elsewhere,
  because none of it changes when the CAD does.

  ## The chain is walked, not read in order

  The loader this replaces took the chain from the order joints appeared in the
  file and ignored `<parent>` and `<child>` entirely. URDF makes no such
  guarantee — it is a tree described as an unordered set of edges, and a CAD
  exporter is free to emit them in any order at all. That defect passes every
  test written against the file it was developed on, which is why the fixture
  for this module has its joints deliberately shuffled.

  ## Refusals are the feature

  Every refusal names the element that caused it. A URDF this build cannot
  honour must fail as a sentence somebody can act on, not as a chain that is
  quietly the wrong shape — the whole class of failure this module exists to
  end is the one where the arm is described plausibly and incorrectly.
  """

  alias ExMove.{Chain, Frame, Joint, Math}

  @type refusal :: {atom(), String.t()}

  @doc "Loads a URDF shipped in this application's priv directory."
  @spec load(atom() | String.t(), keyword()) :: {:ok, Chain.t()} | {:error, refusal()}
  def load(robot_name, opts \\ []) do
    path = Path.join(to_string(:code.priv_dir(:exmove)), "#{robot_name}.urdf")
    parse_file(path, Keyword.put_new(opts, :name, robot_name))
  end

  @spec parse_file(Path.t(), keyword()) :: {:ok, Chain.t()} | {:error, refusal()}
  def parse_file(path, opts \\ []) do
    case File.read(path) do
      {:ok, xml} -> parse_string(xml, opts)
      {:error, reason} -> {:error, {:unreadable, "cannot read #{path}: #{:file.format_error(reason)}"}}
    end
  end

  @doc """
  Parses a URDF document into a chain.

  Options:

    * `:name` — the chain's name, an atom. Defaults to the `<robot name=...>`.
    * `:axis_ids` — the drive each joint is wired to, base to tip. Deliberately
      not invented here: which drive is joint 3 is a fact about an installation
      and this module only knows about a mechanism. Defaults to `[]`.
  """
  @spec parse_string(binary(), keyword()) :: {:ok, Chain.t()} | {:error, refusal()}
  def parse_string(xml, opts \\ []) when is_binary(xml) do
    with :ok <- refuse_xacro(xml),
         {:ok, root} <- parse_xml(xml),
         {:ok, robot_name, children} <- robot_element(root),
         {:ok, joints} <- joint_elements(children),
         {:ok, ordered} <- walk(joints),
         {:ok, actuated, flange} <- collapse_fixed(ordered) do
      name = Keyword.get(opts, :name) || String.to_atom(robot_name)

      {:ok,
       %Chain{
         name: name,
         joints: actuated,
         axis_ids: Keyword.get(opts, :axis_ids, []),
         flange: flange
       }}
    end
  end

  # ── XML ───────────────────────────────────────────────────────────────────

  # Detected on the text rather than after parsing, because xacro markup is
  # usually well-formed XML and would otherwise arrive as a chain full of
  # elements this module does not recognise, or as an empty one. It is a macro
  # language: the answer is to expand it first, not to grow a macro expander in
  # a robot controller.
  defp refuse_xacro(xml) do
    if String.contains?(xml, "xacro:") do
      {:error,
       {:xacro,
        "this is xacro, not URDF — expand it first with `xacro robot.xacro > robot.urdf`"}}
    else
      :ok
    end
  end

  defp parse_xml(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> {:error, {:malformed, "not valid XML: #{Exception.message(reason)}"}}
    end
  end

  defp robot_element({"robot", attrs, children}), do: {:ok, attr(attrs, "name") || "robot", children}

  defp robot_element({tag, _attrs, _children}),
    do: {:error, {:not_urdf, "root element is <#{tag}>, expected <robot>"}}

  # ── Joints ────────────────────────────────────────────────────────────────

  defp joint_elements(children) do
    children
    |> Enum.filter(&element?(&1, "joint"))
    |> reduce_while_ok(&joint/1)
  end

  defp joint({"joint", attrs, body}) do
    name = attr(attrs, "name")
    type = attr(attrs, "type")

    with :ok <- require_name(name),
         :ok <- refuse_mimic(name, body),
         {:ok, type} <- joint_type(name, type),
         {:ok, parent} <- link_ref(name, body, "parent"),
         {:ok, child} <- link_ref(name, body, "child") do
      origin = child_element(body, "origin")
      limit = child_element(body, "limit")

      {:ok,
       %{
         parent: parent,
         child: child,
         joint: %Joint{
           # Not an axis id. Which drive turns this joint is commissioning, and
           # a URDF that thought it knew would be describing an installation it
           # has never seen.
           id: nil,
           name: name,
           type: type,
           axis: vec3(child_element(body, "axis"), "xyz", {0.0, 0.0, 1.0}),
           origin: vec3(origin, "xyz", {0.0, 0.0, 0.0}),
           rpy: vec3(origin, "rpy", {0.0, 0.0, 0.0}),
           limit: travel(type, limit),
           max_vel: number(limit, "velocity"),
           max_acc: nil
         }
       }}
    end
  end

  defp require_name(nil), do: {:error, {:unnamed_joint, "a <joint> has no name attribute"}}
  defp require_name(_name), do: :ok

  # A mimic joint is a real thing on real grippers, and a coupled axis treated
  # as an independent one puts the arm somewhere other than where it was sent.
  defp refuse_mimic(name, body) do
    if child_element(body, "mimic") do
      {:error,
       {:mimic,
        "joint \"#{name}\" mimics another joint; this build solves independent axes only"}}
    else
      :ok
    end
  end

  # `continuous` is a revolute joint with no travel limit, and it is the type
  # the Arctos export uses for all six.
  defp joint_type(_name, "revolute"), do: {:ok, :revolute}
  defp joint_type(_name, "continuous"), do: {:ok, :revolute}
  defp joint_type(_name, "fixed"), do: {:ok, :fixed}

  # Parsed by the old loader and silently wrong, which is worse than refused.
  # Forward kinematics here and in the NIF applies `rotation_axis` to every
  # joint without consulting its type, so a prismatic axis would be turned
  # rather than extended — and the pose it produced would look plausible.
  defp joint_type(name, "prismatic") do
    {:error,
     {:prismatic,
      "joint \"#{name}\" is prismatic; this build's kinematics rotates about " <>
        "every joint axis and would silently turn it instead of extending it"}}
  end

  defp joint_type(name, nil),
    do: {:error, {:untyped_joint, "joint \"#{name}\" has no type attribute"}}

  defp joint_type(name, other),
    do: {:error, {:unknown_joint_type, "joint \"#{name}\" has type \"#{other}\", which this build does not know"}}

  defp link_ref(joint_name, body, which) do
    case child_element(body, which) do
      nil ->
        {:error, {:unlinked_joint, "joint \"#{joint_name}\" has no <#{which}> link"}}

      {_tag, attrs, _children} ->
        case attr(attrs, "link") do
          nil -> {:error, {:unlinked_joint, "joint \"#{joint_name}\" has a <#{which}> with no link attribute"}}
          link -> {:ok, link}
        end
    end
  end

  # `continuous` has no travel; `nil` is how the rest of the suite says so.
  defp travel(:fixed, _limit), do: nil

  defp travel(_type, nil), do: nil

  defp travel(_type, limit) do
    case {number(limit, "lower"), number(limit, "upper")} do
      {lower, upper} when is_float(lower) and is_float(upper) -> {lower, upper}
      _absent -> nil
    end
  end

  # ── The tree ──────────────────────────────────────────────────────────────

  # One chain, walked from the root. Every refusal here names a link, because
  # "your robot branches" is not something anybody can act on and "link
  # `wrist_2` has two children" is.
  defp walk([]), do: {:error, {:no_joints, "the document declares no joints"}}

  defp walk(edges) do
    by_parent = Enum.group_by(edges, & &1.parent)
    children = MapSet.new(edges, & &1.child)
    roots = edges |> Enum.map(& &1.parent) |> Enum.uniq() |> Enum.reject(&MapSet.member?(children, &1))

    case roots do
      [root] ->
        follow(root, by_parent, [])

      [] ->
        {:error, {:cycle, "every link is some joint's child; the chain has no base and is a loop"}}

      many ->
        {:error,
         {:disconnected,
          "the document describes #{length(many)} separate mechanisms, rooted at " <>
            Enum.map_join(Enum.sort(many), ", ", &"\"#{&1}\"")}}
    end
  end

  defp follow(link, by_parent, acc) do
    case Map.get(by_parent, link, []) do
      [] ->
        {:ok, Enum.reverse(acc)}

      [edge] ->
        follow(edge.child, by_parent, [edge.joint | acc])

      branches ->
        {:error,
         {:branch,
          "link \"#{link}\" has #{length(branches)} joints hanging off it (" <>
            Enum.map_join(branches, ", ", &"\"#{&1.joint.name}\"") <>
            "); this build solves one serial chain"}}
    end
  end

  # ── Fixed joints ──────────────────────────────────────────────────────────

  # A fixed joint is geometry, not an axis, and the rest of the suite expects
  # one commanded position per joint in the chain. So a fixed joint is folded
  # into the next actuated joint's origin — exact, since both are rigid — and
  # a trailing run of them becomes the flange: the offset from the last axis to
  # where a tool bolts on.
  #
  # That distinction is the answer to a question ROBOT.md left open. The flange
  # is the mechanism's; the tool is what somebody fitted to it. `EMotion.Cell`
  # composes the two, and neither has to know about the other.
  defp collapse_fixed(joints) do
    {actuated, pending} =
      Enum.reduce(joints, {[], nil}, fn joint, {acc, pending} ->
        case {joint.type, pending} do
          {:fixed, nil} ->
            {acc, origin_transform(joint)}

          {:fixed, transform} ->
            {acc, Math.mul(transform, origin_transform(joint))}

          # Nothing to fold in, so the joint is left exactly as the document
          # wrote it. Decomposing a transform back to roll-pitch-yaw is exact
          # but not unique — at a pitch of ±90° the roll and yaw trade places —
          # and there is no reason to put a joint through that round trip to
          # multiply it by the identity.
          {_actuated, nil} ->
            {[joint | acc], nil}

          {_actuated, transform} ->
            {[rebase(joint, Math.mul(transform, origin_transform(joint))) | acc], nil}
        end
      end)

    case Enum.reverse(actuated) do
      [] ->
        {:error, {:no_actuated_joints, "every joint in the chain is fixed; there is nothing to move"}}

      actuated ->
        {:ok, actuated, frame(pending)}
    end
  end

  defp rebase(joint, transform) do
    {x, y, z} = Math.translation_of(transform)
    {rx, ry, rz} = Math.rpy_of(transform)
    %{joint | origin: {x, y, z}, rpy: {rx, ry, rz}}
  end

  defp frame(nil), do: %Frame{}

  defp frame(transform) do
    {x, y, z} = Math.translation_of(transform)
    {rx, ry, rz} = Math.rpy_of(transform)
    %Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}
  end

  defp origin_transform(%Joint{origin: {ox, oy, oz}, rpy: {roll, pitch, yaw}}) do
    Math.mul(Math.translation(ox, oy, oz), Math.rotation_rpy(roll, pitch, yaw))
  end

  # ── Reading elements ──────────────────────────────────────────────────────

  defp element?({tag, _attrs, _children}, tag), do: true
  defp element?(_other, _tag), do: false

  defp child_element(children, tag) do
    Enum.find(children, &element?(&1, tag))
  end

  defp attr(attrs, key) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp vec3(nil, _key, default), do: default

  defp vec3({_tag, attrs, _children}, key, default) do
    case attr(attrs, key) do
      nil ->
        default

      value ->
        case value |> String.split() |> Enum.map(&to_float/1) do
          [x, y, z] when is_float(x) and is_float(y) and is_float(z) -> {x, y, z}
          _malformed -> default
        end
    end
  end

  defp number(nil, _key), do: nil

  defp number({_tag, attrs, _children}, key) do
    case attr(attrs, key) do
      nil -> nil
      value -> to_float(value)
    end
  end

  defp to_float(string) do
    case Float.parse(string) do
      {float, ""} -> float
      _not_a_float -> nil
    end
  end

  defp reduce_while_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
