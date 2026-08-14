defmodule EMotion.Pose do
  @moduledoc """
  The boundary between how `ExMove` writes a transform and how Cedar reads one.

  Both hold sixteen numbers meaning a 4x4 homogeneous transform, and they
  disagree about the layout in two independent ways:

      ExMove.Math   16-element tuple, row-major
      Cedar.Math    16-element list,  column-major

  Row-major to column-major is a transpose. Getting it wrong does not raise, it
  renders — every rotation becomes its own inverse, so an arm bends the right
  amount in the wrong direction and reads as "the model is mirrored" rather
  than "the conversion is wrong". Hence a module, and hence tests that assert
  on transformed points rather than on the numbers.

  ## The convention is ExMove's, not ours

  `from_frame/1` builds the matrix by composing `ExMove.Math.translation/3` and
  `ExMove.Math.rotation_rpy/3` — the same two calls `ExMove.FK` makes
  internally — and only then converts the representation. Reimplementing
  roll-pitch-yaw here would be a second definition of the convention, free to
  drift from the one that actually drives the machine.
  """

  alias Cedar.Math
  alias ExMove.Frame

  @doc """
  An `ExMove` transform as a Cedar matrix.

  Transposes; see the module docs for why that is the whole job.
  """
  @spec from_exmove(tuple()) :: Math.mat4()
  def from_exmove(transform) when is_tuple(transform) and tuple_size(transform) == 16 do
    # Cedar wants column c, row r at index c*4 + r. ExMove has it at r*4 + c.
    for c <- 0..3, r <- 0..3, do: elem(transform, r * 4 + c) * 1.0
  end

  @doc """
  An `ExMove.Frame` as a Cedar matrix.

  Position in metres, orientation as roll-pitch-yaw in radians — canonical
  units throughout, per `EMotion.Units`, so nothing here converts anything but
  layout.
  """
  @spec from_frame(Frame.t()) :: Math.mat4()
  def from_frame(%Frame{} = frame) do
    ExMove.Math.translation(frame.x, frame.y, frame.z)
    |> ExMove.Math.mul(ExMove.Math.rotation_rpy(frame.rx, frame.ry, frame.rz))
    |> from_exmove()
  end

  @doc "Where a frame is, as a Cedar vector."
  @spec position(Frame.t()) :: Math.vec3()
  def position(%Frame{} = frame), do: {frame.x, frame.y, frame.z}

  @doc """
  A `Cedar.Cell` transform map as a Cedar matrix.

  The studio's own pose type, used for robot bases and named frames. Same
  shape as `ExMove.Frame` by design, so this is the same conversion.
  """
  @spec from_transform(map()) :: Math.mat4()
  def from_transform(%{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz}) do
    from_frame(%Frame{x: x, y: y, z: z, rx: rx, ry: ry, rz: rz})
  end
end
