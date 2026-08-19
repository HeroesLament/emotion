defmodule EMotion.Controller do
  @moduledoc """
  DSL for declaring an ExMo machine controller.

  Provides `axis/2` and `behaviors/1` macros that accumulate a machine
  definition at compile time. At runtime the module becomes a valid OTP
  Supervisor and contributes its axes and behaviors to the Information Model.

  ## Example

      defmodule MiniLathe do
        use EMotion.Controller

        axis :z,       type: :linear, unit: :mm,  limits: {-300.0, 0.0}, home_pos: 0.0
        axis :spindle, type: :rotary, unit: :rpm,  limits: {0.0, 3000.0}

        behaviors [
          EMotion.Behaviors.MiniLathe.Home,
          EMotion.Behaviors.MiniLathe.SetSpindleSpeed,
          EMotion.Behaviors.MiniLathe.Threading
        ]
      end

  ## What gets generated

  - `__axes__/0`        — list of axis specs as maps
  - `__behaviors__/0`   — list of behavior modules
  - `axes_fragment/0`   — `%EMotion.Schema.Object{}` for the Axes subtree
  - `behaviors/0`       — list of behavior definition modules (for the registry)
  - `start_link/1`      — starts a supervised ExDrive.Drive per axis
  - `child_spec/1`      — standard OTP child spec

  ## Axis options

    * `:type`        — `:linear` or `:rotary` (required)
    * `:unit`        — `:mm`, `:inches`, `:rpm`, `:degrees`, or any atom (required)
    * `:limits`      — `{min, max}` float tuple (optional)
    * `:home_pos`    — float or nil (optional)
    * `:description` — string (optional)
    * `:extra`       — list of `%EMotion.Schema.Property{}` for custom properties (optional)
  """

  defmacro __using__(_opts) do
    quote do
      use Supervisor

      import EMotion.Controller, only: [axis: 2, behaviors: 1]

      Module.register_attribute(__MODULE__, :exmo_axes,      accumulate: true)
      Module.register_attribute(__MODULE__, :exmo_behaviors, accumulate: false)

      @before_compile EMotion.Controller
    end
  end

  @doc """
  Declares an axis on this controller.

  The first argument is the axis name as an atom (e.g. `:z`, `:spindle`).
  It is used to derive the axis id (`"<module_prefix>.<name>"`) and display name.

  ## Example

      axis :z,       type: :linear, unit: :mm,  limits: {-300.0, 0.0}, home_pos: 0.0
      axis :spindle, type: :rotary, unit: :rpm,  limits: {0.0, 3000.0}
  """
  defmacro axis(name, opts) do
    quote do
      @exmo_axes {unquote(name), unquote(opts)}
    end
  end

  @doc """
  Declares the list of behavior modules for this controller.

  ## Example

      behaviors [
        EMotion.Behaviors.MiniLathe.Home,
        EMotion.Behaviors.MiniLathe.Threading
      ]
  """
  defmacro behaviors(modules) do
    quote do
      @exmo_behaviors unquote(modules)
    end
  end

  defmacro __before_compile__(env) do
    axes      = Module.get_attribute(env.module, :exmo_axes) |> Enum.reverse()
    behaviors = Module.get_attribute(env.module, :exmo_behaviors) || []

    axis_specs = Enum.map(axes, fn {name, opts} ->
      id          = "#{Macro.underscore(env.module)}.#{name}"
      display     = name |> to_string() |> String.capitalize()

      Map.new(opts)
      |> Map.put(:id,   id)
      |> Map.put(:name, display)
    end)

    quote do
      # ── Public introspection ─────────────────────────────────────────────

      def __axes__,     do: unquote(Macro.escape(axis_specs))
      def __behaviors__, do: unquote(behaviors)

      # ── Information Model contributions ──────────────────────────────────

      def axes_fragment do
        alias EMotion.Schema.{Object, FromAxis}

        children = Enum.map(__axes__(), &FromAxis.to_object/1)

        %Object{
          id:       "axes",
          name:     "Axes",
          children: children
        }
      end

      def behaviors, do: __behaviors__()

      # ── OTP Supervisor ────────────────────────────────────────────────────

      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl Supervisor
      def init(_opts) do
        children = Enum.map(__axes__(), fn spec ->
          {ExDrive.Drive, spec}
        end)

        Supervisor.init(children, strategy: :one_for_one)
      end
    end
  end
end
