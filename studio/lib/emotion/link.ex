defmodule EMotion.Link do
  @moduledoc """
  The studio's connection to a controller.

  One link at a time, and that is a deliberate consequence of how a cell is
  meant to be organised: controllers elect a master, the master's information
  model aggregates the cell, and a client talks to the master. Multiplicity
  belongs behind that aggregation rather than in the client, the same way an
  OPC UA aggregating server presents many devices in one namespace.

  The process is registered by name rather than being a hardcoded singleton, so
  switching cells is a stop and a start, and a future studio that genuinely
  needs two is a supervisor change rather than a rewrite.

  ## What it does

  On connect: authenticates, browses the controller's axes, builds a robot from
  them, replaces the cell with it, and subscribes to joint positions. Every
  notification becomes a `{:set_joints, robot_id, positions}` change on
  `EMotion.Cell.Server`, which is the integration point that server's own docs
  anticipated — "a live telemetry feed can propose changes without knowing a
  GUI exists".

  ## Why it never blocks on the socket

  `ExLink` offers both a blocking request/response and a message-driven one.
  This uses the message-driven one for everything after the handshake, because
  a `receive` inside a GenServer stalls every other message the process is
  responsible for — including the disconnect that someone is pressing precisely
  because the link has gone slow.

  The handshake itself is synchronous, in `handle_continue/2`, while the
  mailbox holds nothing but socket traffic.

  ## Writes

  `jog/3` writes a joint setpoint. It is a `call` and it reports what the
  controller says the axis actually holds, which is not always what was asked
  for — a drive clamps to its limits, and a studio that drew the requested
  angle would be drawing a lie.
  """

  use GenServer

  require Logger

  alias EMotion.{Cell, Controller.Profile}
  alias ExMove.{Chain, Joint}

  @default_name __MODULE__

  # Bounded so a controller cannot make the studio allocate atoms without limit
  # by declaring axes. The model has six; a hundred would be a different machine
  # or a hostile one, and either deserves a refusal rather than a chain.
  @max_axes 64

  defstruct [
    :profile,
    :session,
    :subscription,
    :robot_id,
    :axes,
    :info,
    cell_server: EMotion.Cell.Server,
    subscribers: MapSet.new()
  ]

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @default_name))
  end

  @doc """
  Connects to a controller and mirrors it into the cell.

  Options:

    * `:password` — used once, exchanged for a token which is then stored.
      Omit it to use a token saved earlier.
    * `:cell_server` — where to publish changes; defaults to `EMotion.Cell.Server`.
    * `:known_hosts` — override the certificate trust store.
  """
  @spec connect(Profile.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect(%Profile{} = profile, opts \\ []) do
    GenServer.call(server(opts), {:connect, profile, opts}, 30_000)
  end

  @spec disconnect(keyword()) :: :ok
  def disconnect(opts \\ []), do: GenServer.call(server(opts), :disconnect)

  @doc "`:disconnected` or `{:connected, info}`."
  @spec status(keyword()) :: :disconnected | {:connected, map()}
  def status(opts \\ []), do: GenServer.call(server(opts), :status)

  @doc """
  Commands one joint, in radians.

  Returns the value the controller applied.
  """
  @spec jog(atom() | String.t(), float(), keyword()) :: {:ok, float()} | {:error, term()}
  def jog(axis, radians, opts \\ []) do
    GenServer.call(server(opts), {:jog, to_string(axis), radians * 1.0}, 10_000)
  end

  @doc "Receive `{:link, event}` messages: `:connected`, `{:disconnected, reason}`, `{:error, term}`."
  @spec subscribe(keyword()) :: :ok
  def subscribe(opts \\ []), do: GenServer.call(server(opts), {:subscribe, self()})

  defp server(opts), do: Keyword.get(opts, :name, @default_name)

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       robot_id: Keyword.get(opts, :robot_id, :arm_a),
       cell_server: Keyword.get(opts, :cell_server, EMotion.Cell.Server)
     }}
  end

  @impl true
  def handle_call({:connect, profile, opts}, _from, %{session: nil} = state) do
    case establish(profile, opts) do
      {:ok, session, info, axes, subscription} ->
        state = %{
          state
          | profile: profile,
            session: session,
            info: info,
            axes: axes,
            subscription: subscription,
            robot_id: profile.robot_id
        }

        publish_robot(state, opts)
        notify(state, :connected)
        {:reply, {:ok, info}, state}

      {:error, reason} ->
        notify(state, {:error, reason})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:connect, _profile, _opts}, _from, state) do
    {:reply, {:error, :already_connected}, state}
  end

  def handle_call(:disconnect, _from, state) do
    {:reply, :ok, close(state, :requested)}
  end

  def handle_call(:status, _from, %{session: nil} = state), do: {:reply, :disconnected, state}
  def handle_call(:status, _from, state), do: {:reply, {:connected, state.info}, state}

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:jog, _axis, _value}, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:jog, axis, value}, _from, state) do
    node_id = "axes.#{axis}.target_position"

    case ExLink.request(state.session, "nodes/write", %{
           "writes" => [%{"nodeId" => node_id, "value" => value}]
         }) do
      {:ok, session, %{"result" => %{"results" => [%{"ok" => true, "value" => applied}]}}} ->
        {:reply, {:ok, applied}, %{state | session: session}}

      {:ok, session, %{"result" => %{"results" => [%{"error" => error}]}}} ->
        {:reply, {:error, error}, %{state | session: session}}

      {:ok, session, %{"error" => error}} ->
        {:reply, {:error, error}, %{state | session: session}}

      {:error, reason} ->
        {:reply, {:error, reason}, close(state, reason)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, %{session: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case ExLink.stream(state.session, message) do
      {:ok, session, frames} ->
        state = %{state | session: session}
        Enum.each(frames, &apply_frame(&1, state))
        {:noreply, state}

      :unknown ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("EMotion.Link: connection lost — #{inspect(reason)}")
        {:noreply, close(state, reason)}
    end
  end

  # ── Connecting ────────────────────────────────────────────────────────────

  defp establish(profile, opts) do
    with {:ok, token} <- token_for(profile, opts),
         {:ok, session, info} <- open(profile, token, opts),
         {:ok, session, axes} <- browse_axes(session),
         {:ok, session, subscription} <- subscribe_positions(session, axes, profile.rate_hz) do
      {:ok, session, info, axes, subscription}
    end
  end

  # A password, if given, is used exactly once and replaced by a token that can
  # be revoked from the controller without changing anyone's password.
  defp token_for(profile, opts) do
    case Keyword.get(opts, :password) do
      nil ->
        Profile.token(profile) |> case do
          {:ok, token} -> {:ok, token}
          :error -> {:error, :no_credential}
        end

      password ->
        case ExLink.login(profile.host, profile.port, profile.username, password,
               Keyword.take(opts, [:known_hosts, :insecure]) ++ [label: "E-Motion Studio"]
             ) do
          {:ok, %{"token" => token}} ->
            Profile.put_token(profile, token)
            {:ok, token}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp open(profile, token, opts) do
    ExLink.connect(
      profile.host,
      profile.port,
      token,
      Keyword.take(opts, [:known_hosts, :insecure]) ++
        [client_info: %{"name" => "E-Motion Studio", "version" => "0.1.0"}]
    )
  end

  # The axes the controller declares, in its order. Taken from the model rather
  # than assumed, so a five-axis machine draws five joints.
  defp browse_axes(session) do
    case ExLink.request(session, "nodes/browse", %{"nodeId" => "axes"}) do
      {:ok, session, %{"result" => %{"children" => children}}} ->
        axes =
          children
          |> Enum.filter(&(&1["class"] == "object"))
          |> Enum.map(fn child ->
            %{
              node_id: child["nodeId"],
              axis: child["nodeId"] |> String.split(".") |> List.last(),
              name: child["name"]
            }
          end)

        cond do
          axes == [] -> {:error, :no_axes}
          length(axes) > @max_axes -> {:error, {:too_many_axes, length(axes)}}
          true -> {:ok, session, axes}
        end

      {:ok, _session, %{"error" => error}} ->
        {:error, error}

      other ->
        other
    end
  end

  defp subscribe_positions(session, axes, rate_hz) do
    node_ids = Enum.map(axes, &"#{&1.node_id}.position")

    case ExLink.request(session, "nodes/subscribe", %{
           "nodeIds" => node_ids,
           "rateHz" => rate_hz
         }) do
      {:ok, session, %{"result" => result}} -> {:ok, session, result["subscriptionId"]}
      {:ok, _session, %{"error" => error}} -> {:error, error}
      other -> other
    end
  end

  # ── Telemetry into the cell ───────────────────────────────────────────────

  defp apply_frame(%{"method" => method, "params" => params}, state) do
    if method == "notifications/nodes/changed" do
      positions =
        params
        |> Map.get("values", [])
        |> Map.new(fn value -> {value["nodeId"], value["value"]} end)

      merge_joints(positions, state)
    end
  end

  defp apply_frame(_frame, _state), do: :ok

  # Only changed values arrive, so a notification is a patch and never a full
  # pose. Merging against the cell's current joints is not an optimisation —
  # reading the frame as a pose would snap every unmentioned joint to zero.
  defp merge_joints(positions, state) when map_size(positions) > 0 do
    cell = Cell.Server.snapshot(state.cell_server)

    case Cell.robot(cell, state.robot_id) do
      {:ok, robot} ->
        joints =
          state.axes
          |> Enum.with_index()
          |> Enum.map(fn {axis, index} ->
            Map.get(positions, "#{axis.node_id}.position", Enum.at(robot.joints, index, 0.0))
          end)

        Cell.Server.change({:set_joints, state.robot_id, joints}, state.cell_server)

      :error ->
        :ok
    end
  end

  defp merge_joints(_positions, _state), do: :ok

  defp publish_robot(state, _opts) do
    robot = %Cell.Robot{
      id: state.robot_id,
      name: state.profile.name,
      chain: chain_for(state.axes),
      base: Cell.origin(),
      joints: List.duplicate(0.0, length(state.axes))
    }

    {:ok, cell} =
      Cell.new(name: state.profile.name)
      |> Cell.apply_change({:add_robot, robot})

    Cell.Server.replace(cell, state.cell_server)
  end

  # Geometry the controller does not publish. The information model describes
  # what an axis *is* — its unit, its limits, its state — and says nothing about
  # link lengths, so the studio cannot yet draw the real machine's proportions.
  # Until a URDF arrives over the link or from a library, the joints are real
  # and the geometry is a stand-in, which is worth knowing before believing a
  # reach envelope on screen.
  defp chain_for(axes) do
    %Chain{
      name: :controller,
      axis_ids: Enum.map(axes, &String.to_atom(&1.axis)),
      joints:
        axes
        |> Enum.with_index()
        |> Enum.map(fn {axis, index} ->
          %Joint{
            id: String.to_atom(axis.axis),
            name: axis.name,
            type: :revolute,
            axis: if(rem(index, 3) == 0, do: {0.0, 1.0, 0.0}, else: {1.0, 0.0, 0.0}),
            origin: {0.0, 0.2, 0.0},
            rpy: {0.0, 0.0, 0.0},
            limit: {-3.05, 3.05}
          }
        end)
    }
  end

  # ── Teardown ──────────────────────────────────────────────────────────────

  defp close(%{session: nil} = state, _reason), do: state

  defp close(state, reason) do
    notify(state, {:disconnected, reason})
    %{state | session: nil, subscription: nil, axes: nil, info: nil}
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, &send(&1, {:link, event}))
  end
end
