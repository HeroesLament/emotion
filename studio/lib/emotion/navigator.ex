defmodule EMotion.Navigator do
  @moduledoc """
  Mouse gestures, folded into a camera.

      nav = EMotion.Navigator.new()
      nav = EMotion.Navigator.handle(nav, event)

      camera = nav.camera

  Pure, and a fold rather than a callback: every mouse event that reaches the
  scene goes through `handle/2`, which returns a new navigator. That makes the
  whole interaction testable without a window, which matters because camera
  controls are almost impossible to debug by looking at them — "it feels wrong"
  is not a stack trace.

  ## The gestures

      left drag      orbit
      middle drag    pan
      shift+left     pan, for mice that have no middle button
      wheel          dolly

  These are the ones every CAD package agrees on, which is the only good reason
  to pick any particular set. A user who has spent a decade in SolidWorks
  should not have to learn a new hand.

  ## Drag state lives here, not in wx

  A drag is three events — down, move, up — and the delta that matters is
  between consecutive moves, not from the press. Keeping the last position here
  means the scene's model holds one navigator rather than a scattering of
  `dragging?`, `last_x`, `last_y` fields, and a mouse that leaves the window
  mid-drag cannot strand any of them out of sync.
  """

  alias Cedar.Camera

  @type t :: %__MODULE__{
          camera: Camera.t(),
          drag: nil | {:orbit | :pan, {number(), number()}},
          orbit_speed: float(),
          pan_speed: float(),
          dolly_speed: float()
        }

  defstruct camera: nil,
            drag: nil,
            # Degrees per pixel. A full turn in roughly a screen's width.
            orbit_speed: 0.4,
            # Scene units per pixel, scaled by distance so panning feels the
            # same whether you are looking at a cell or at one flange.
            pan_speed: 0.0022,
            dolly_speed: 1.12

  @doc "A navigator around a camera."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {camera_opts, opts} = Keyword.pop(opts, :camera, [])

    camera =
      case camera_opts do
        %Camera{} = camera -> camera
        list when is_list(list) -> Camera.new(list)
      end

    struct!(__MODULE__, Keyword.put(opts, :camera, camera))
  end

  @doc """
  Folds one mouse event in.

  Takes the payload Cedar delivers to a scene — `%{type:, button:, x:, y:,
  wheel_delta:, modifiers:}` — and ignores anything it does not use, so a
  caller can hand it every event without filtering.
  """
  @spec handle(t(), map()) :: t()
  def handle(%__MODULE__{} = nav, %{type: :down, button: button} = event) do
    mode =
      cond do
        button == :middle -> :pan
        button == :left and :shift in modifiers(event) -> :pan
        button == :left -> :orbit
        true -> nil
      end

    if mode, do: %{nav | drag: {mode, position(event)}}, else: nav
  end

  def handle(%__MODULE__{drag: nil} = nav, %{type: :move}), do: nav

  def handle(%__MODULE__{drag: {mode, {last_x, last_y}}} = nav, %{type: :move} = event) do
    {x, y} = position(event)
    dx = x - last_x
    dy = y - last_y

    camera =
      case mode do
        :orbit ->
          # Dragging right turns the scene right, which means moving the eye
          # left. Inverting either axis here is the single most common way a
          # camera ends up feeling wrong.
          Camera.orbit(nav.camera, -dx * nav.orbit_speed, dy * nav.orbit_speed)

        :pan ->
          # Scaled by distance: panning a millimetre of screen should move less
          # of the world when you are close to it.
          scale = nav.pan_speed * nav.camera.distance
          Camera.pan(nav.camera, -dx * scale, dy * scale)
      end

    %{nav | camera: camera, drag: {mode, {x, y}}}
  end

  def handle(%__MODULE__{} = nav, %{type: :up}), do: %{nav | drag: nil}

  # A mouse that leaves the window mid-drag would otherwise keep dragging when
  # it comes back, from wherever it re-entered - a visible jump.
  def handle(%__MODULE__{} = nav, %{type: :leave}), do: %{nav | drag: nil}

  def handle(%__MODULE__{} = nav, %{type: :wheel, wheel_delta: delta})
      when is_number(delta) and delta != 0 do
    factor = if delta > 0, do: 1.0 / nav.dolly_speed, else: nav.dolly_speed
    %{nav | camera: Camera.dolly(nav.camera, factor)}
  end

  def handle(%__MODULE__{} = nav, _event), do: nav

  @doc "Whether a drag is in progress, for a cursor change or a status line."
  @spec dragging?(t()) :: boolean()
  def dragging?(%__MODULE__{drag: nil}), do: false
  def dragging?(%__MODULE__{}), do: true

  @doc "Replaces the camera, for a standard view or a zoom-to-fit."
  @spec put_camera(t(), Camera.t()) :: t()
  def put_camera(%__MODULE__{} = nav, %Camera{} = camera), do: %{nav | camera: camera}

  @doc "Applies a function to the camera, ending any drag in progress."
  @spec update_camera(t(), (Camera.t() -> Camera.t())) :: t()
  def update_camera(%__MODULE__{} = nav, fun) do
    %{nav | camera: fun.(nav.camera), drag: nil}
  end

  # ==========================================================================

  defp position(%{x: x, y: y}), do: {x, y}

  defp modifiers(%{modifiers: modifiers}) when is_list(modifiers), do: modifiers
  defp modifiers(_event), do: []
end
