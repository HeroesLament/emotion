defmodule ExMove.Math do
  @moduledoc """
  4x4 homogeneous transform math for forward kinematics.

  Matrices are represented as a flat 16-element tuple, row-major:

      | m0  m1  m2  m3  |
      | m4  m5  m6  m7  |
      | m8  m9  m10 m11 |
      | m12 m13 m14 m15 |

  The bottom row is always {0, 0, 0, 1} for valid transforms.
  """

  # Identity transform
  def identity do
    {1.0, 0.0, 0.0, 0.0,
     0.0, 1.0, 0.0, 0.0,
     0.0, 0.0, 1.0, 0.0,
     0.0, 0.0, 0.0, 1.0}
  end

  @doc "Pure translation matrix"
  def translation(x, y, z) do
    {1.0, 0.0, 0.0,   x,
     0.0, 1.0, 0.0,   y,
     0.0, 0.0, 1.0,   z,
     0.0, 0.0, 0.0, 1.0}
  end

  @doc "Rotation from roll-pitch-yaw (extrinsic XYZ)"
  def rotation_rpy(roll, pitch, yaw) do
    cr = :math.cos(roll);  sr = :math.sin(roll)
    cp = :math.cos(pitch); sp = :math.sin(pitch)
    cy = :math.cos(yaw);   sy = :math.sin(yaw)

    {cy*cp,  cy*sp*sr - sy*cr,  cy*sp*cr + sy*sr,  0.0,
     sy*cp,  sy*sp*sr + cy*cr,  sy*sp*cr - cy*sr,  0.0,
     -sp,    cp*sr,             cp*cr,             0.0,
     0.0,    0.0,               0.0,               1.0}
  end

  @doc "Rotation by angle theta around an arbitrary unit axis {ax, ay, az}"
  def rotation_axis({ax, ay, az}, theta) do
    c  = :math.cos(theta)
    s  = :math.sin(theta)
    t  = 1.0 - c

    {t*ax*ax + c,     t*ax*ay - s*az,  t*ax*az + s*ay,  0.0,
     t*ax*ay + s*az,  t*ay*ay + c,     t*ay*az - s*ax,  0.0,
     t*ax*az - s*ay,  t*ay*az + s*ax,  t*az*az + c,     0.0,
     0.0,             0.0,             0.0,             1.0}
  end

  @doc "Multiply two 4x4 transforms"
  def mul(
    {a0,  a1,  a2,  a3,
     a4,  a5,  a6,  a7,
     a8,  a9,  a10, a11,
     a12, a13, a14, a15},
    {b0,  b1,  b2,  b3,
     b4,  b5,  b6,  b7,
     b8,  b9,  b10, b11,
     b12, b13, b14, b15}
  ) do
    {a0*b0  + a1*b4  + a2*b8  + a3*b12,
     a0*b1  + a1*b5  + a2*b9  + a3*b13,
     a0*b2  + a1*b6  + a2*b10 + a3*b14,
     a0*b3  + a1*b7  + a2*b11 + a3*b15,

     a4*b0  + a5*b4  + a6*b8  + a7*b12,
     a4*b1  + a5*b5  + a6*b9  + a7*b13,
     a4*b2  + a5*b6  + a6*b10 + a7*b14,
     a4*b3  + a5*b7  + a6*b11 + a7*b15,

     a8*b0  + a9*b4  + a10*b8  + a11*b12,
     a8*b1  + a9*b5  + a10*b9  + a11*b13,
     a8*b2  + a9*b6  + a10*b10 + a11*b14,
     a8*b3  + a9*b7  + a10*b11 + a11*b15,

     a12*b0 + a13*b4 + a14*b8  + a15*b12,
     a12*b1 + a13*b5 + a14*b9  + a15*b13,
     a12*b2 + a13*b6 + a14*b10 + a15*b14,
     a12*b3 + a13*b7 + a14*b11 + a15*b15}
  end

  @doc "Extract translation {x, y, z} from a transform"
  def translation_of({_,_,_,x, _,_,_,y, _,_,_,z, _,_,_,_}), do: {x, y, z}

  @doc "Extract RPY {roll, pitch, yaw} from rotation part of a transform"
  def rpy_of({r00,_,_r02,_, r10,_,_r12,_, r20,r21,r22,_, _,_,_,_}) do
    pitch = :math.atan2(-r20, :math.sqrt(r00*r00 + r10*r10))
    yaw   = :math.atan2(r10, r00)
    roll  = :math.atan2(r21, r22)
    {roll, pitch, yaw}
  end

  @doc "Compose a list of transforms left to right"
  def compose(transforms) do
    Enum.reduce(transforms, identity(), &mul(&2, &1))
  end
end
