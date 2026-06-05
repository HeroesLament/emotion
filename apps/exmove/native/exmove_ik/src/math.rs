/// 4x4 homogeneous transform, row-major flat array.
pub type Mat4 = [f64; 16];

pub fn identity() -> Mat4 {
    [
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    ]
}

pub fn translation(x: f64, y: f64, z: f64) -> Mat4 {
    [
        1.0, 0.0, 0.0,   x,
        0.0, 1.0, 0.0,   y,
        0.0, 0.0, 1.0,   z,
        0.0, 0.0, 0.0, 1.0,
    ]
}

pub fn rotation_rpy(roll: f64, pitch: f64, yaw: f64) -> Mat4 {
    let (cr, sr) = (roll.cos(),  roll.sin());
    let (cp, sp) = (pitch.cos(), pitch.sin());
    let (cy, sy) = (yaw.cos(),   yaw.sin());

    [
        cy*cp,  cy*sp*sr - sy*cr,  cy*sp*cr + sy*sr,  0.0,
        sy*cp,  sy*sp*sr + cy*cr,  sy*sp*cr - cy*sr,  0.0,
          -sp,             cp*sr,             cp*cr,  0.0,
          0.0,               0.0,               0.0,  1.0,
    ]
}

pub fn rotation_axis(ax: f64, ay: f64, az: f64, theta: f64) -> Mat4 {
    let c = theta.cos();
    let s = theta.sin();
    let t = 1.0 - c;

    [
        t*ax*ax + c,     t*ax*ay - s*az,  t*ax*az + s*ay,  0.0,
        t*ax*ay + s*az,  t*ay*ay + c,     t*ay*az - s*ax,  0.0,
        t*ax*az - s*ay,  t*ay*az + s*ax,  t*az*az + c,     0.0,
        0.0,             0.0,             0.0,             1.0,
    ]
}

pub fn mul(a: &Mat4, b: &Mat4) -> Mat4 {
    let mut out = [0.0f64; 16];
    for row in 0..4 {
        for col in 0..4 {
            out[row*4 + col] =
                a[row*4+0] * b[0*4+col] +
                a[row*4+1] * b[1*4+col] +
                a[row*4+2] * b[2*4+col] +
                a[row*4+3] * b[3*4+col];
        }
    }
    out
}

/// Extract translation {x, y, z}
pub fn translation_of(m: &Mat4) -> (f64, f64, f64) {
    (m[3], m[7], m[11])
}

/// Extract RPY from rotation submatrix
pub fn rpy_of(m: &Mat4) -> (f64, f64, f64) {
    let pitch = (-m[8]).atan2((m[0]*m[0] + m[4]*m[4]).sqrt());
    let yaw   = m[4].atan2(m[0]);
    let roll  = m[9].atan2(m[10]);
    (roll, pitch, yaw)
}

/// Build the joint-local transform: T_origin · R_rpy · R_axis(theta)
pub fn joint_transform(
    ox: f64, oy: f64, oz: f64,
    roll: f64, pitch: f64, yaw: f64,
    ax: f64, ay: f64, az: f64,
    theta: f64,
) -> Mat4 {
    let t = translation(ox, oy, oz);
    let r = rotation_rpy(roll, pitch, yaw);
    let j = rotation_axis(ax, ay, az, theta);
    mul(&mul(&t, &r), &j)
}

/// Compose a series of transforms
pub fn compose(transforms: &[Mat4]) -> Mat4 {
    transforms.iter().fold(identity(), |acc, t| mul(&acc, t))
}
