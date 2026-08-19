defmodule MiniLathe do
  @moduledoc """
  E-Motion controller definition for a single-axis mini lathe.

  Registers two drives (Z leadscrew + spindle), three behaviors
  (Home, SetSpindleSpeed, Threading), and contributes an axis fragment
  to the Information Model.

  Start with:

      iex> MiniLathe.start()

  Or add to your application supervisor:

      children = [MiniLathe]
  """

  use Supervisor

  # ── Axis configuration ────────────────────────────────────────────────────

  @axes [
    %{
      id:       "axis.z",
      name:     "Z",
      type:     :linear,
      unit:     :mm,
      limits:   {-300.0, 0.0},
      home_pos: 0.0
    },
    %{
      id:       "spindle",
      name:     "Spindle",
      type:     :rotary,
      unit:     :rpm,
      limits:   {0.0, 3000.0},
      home_pos: nil
    }
  ]

  # ── Supervisor ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children =
      Enum.map(@axes, fn axis ->
        {ExDrive.Drive, axis}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ── Convenience starter ───────────────────────────────────────────────────

  def start, do: start_link()

  # ── Information Model fragment ────────────────────────────────────────────

  @doc """
  Returns the EMotion.Schema.Object fragment for this machine's axes.
  Merged into the root model by EMotion.Schema.Registry.
  """
  def axes_fragment do
    alias EMotion.Schema.{Object, Property}

    %Object{
      id:   "axes",
      name: "Axes",
      children: [
        %Object{
          id:          "axes.z",
          name:        "Z",
          description: "Z-axis leadscrew",
          children:    axis_properties("axes.z")
        },
        %Object{
          id:          "axes.spindle",
          name:        "Spindle",
          description: "Spindle motor",
          children:    axis_properties("axes.spindle") ++ [
            %Property{
              id:          "axes.spindle.direction",
              name:        "Direction",
              type:        :string,
              description: "cw | ccw | stopped",
              readable:    true,
              writable:    true,
              observable:  true
            }
          ]
        }
      ]
    }
  end

  defp axis_properties(prefix) do
    alias EMotion.Schema.Property

    [
      %Property{id: "#{prefix}.position",        name: "Position",       type: :float,  readable: true,  writable: false, observable: true},
      %Property{id: "#{prefix}.target_position",  name: "TargetPosition", type: :float,  readable: true,  writable: true,  observable: false},
      %Property{id: "#{prefix}.velocity",         name: "Velocity",       type: :float,  readable: true,  writable: false, observable: true},
      %Property{id: "#{prefix}.drive_state",      name: "DriveState",     type: :string, readable: true,  writable: false, observable: true},
      %Property{id: "#{prefix}.fault_code",       name: "FaultCode",      type: :uint16, readable: true,  writable: false, observable: false}
    ]
  end

  # ── Behavior registrations ────────────────────────────────────────────────

  @doc "Returns behavior definition modules to be merged into the Behaviors.Catalog."
  def behaviors do
    [
      EMotion.Behaviors.MiniLathe.Home,
      EMotion.Behaviors.MiniLathe.SetSpindleSpeed,
      EMotion.Behaviors.MiniLathe.Threading
    ]
  end
end
