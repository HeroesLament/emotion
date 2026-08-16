use crate::chain::NifJoint;
use crate::math;

/// Compute the 6×n geometric Jacobian for the chain at joint angles `thetas`.
///
/// Returns a flat row-major matrix: 6 rows × n cols.
/// Rows 0-2: linear velocity (position Jacobian)
/// Rows 3-5: angular velocity (orientation Jacobian)
///
/// # Which frame a column belongs to
///
/// Column i is `[z_i × (p_tcp - o_i); z_i]`, where `z_i` is joint i's axis in
/// the base frame and `o_i` is a point on that axis. Both come from the frame
/// **after** joint i's own transform — that is, after its origin offset and its
/// rpy rotation have been applied.
///
/// This is worth spelling out because getting it wrong is silent. Taking them
/// from the frame before joint i's transform gives a Jacobian that is
/// self-consistent — `J·dq` still equals the twist you solved for — and does
/// not match the arm. Every pivot is then the *previous* joint's origin, so
/// every lever arm is one link too long, and the axis is rotated by the parent's
/// rotation without the joint's own rpy. On a chain with zero rpy throughout,
/// the axes come out right and only the pivots are wrong, which is the most
/// misleading way for this to fail: the motion is plausible, roughly the right
/// shape, and several times too fast in a direction nobody asked for.
///
/// `jacobian_test.exs` in exmove pins every column against a finite difference
/// of `ExMove.FK.solve/2`. That is the only check that catches this class of
/// error; comparing `J·dq` to the commanded twist compares `J` with itself.
///
/// # The tool
///
/// `tool` is the TCP offset from the last joint, as `(x, y, z, roll, pitch,
/// yaw)`. It moves `p_tcp` and therefore every linear column; the angular
/// columns are untouched, because a rigid attachment turns at exactly the rate
/// of the thing it is attached to.
///
/// Getting this wrong is invisible under translation. A tool is rigid, so for a
/// command with no angular part `v_tool` and `v_wrist` are equal and a Jacobian
/// written about the wrong point still produces the right motion. Under rotation
/// they differ by `ω × r`, and solving about the wrist for "turn about this axis
/// and do not translate" holds the wrist still and swings the tool through an
/// arc — the tool orbiting the point it was meant to pivot about.
pub fn tool_transform((x, y, z, roll, pitch, yaw): (f64, f64, f64, f64, f64, f64)) -> math::Mat4 {
    math::mul(&math::translation(x, y, z), &math::rotation_rpy(roll, pitch, yaw))
}

pub fn compute(joints: &[NifJoint], thetas: &[f64], tool: (f64, f64, f64, f64, f64, f64)) -> Vec<f64> {
    let n = joints.len();

    // Cumulative transforms. frames[i] is the base-frame pose of the chain
    // *after* joint i, so frames has n entries and frames[n-1] is the tip.
    let mut frames: Vec<math::Mat4> = Vec::with_capacity(n);
    let mut acc = math::identity();

    for (joint, &theta) in joints.iter().zip(thetas.iter()) {
        let t = math::joint_transform(
            joint.origin_x, joint.origin_y, joint.origin_z,
            joint.roll, joint.pitch, joint.yaw,
            joint.axis_x, joint.axis_y, joint.axis_z,
            theta,
        );
        acc = math::mul(&acc, &t);
        frames.push(acc);
    }

    let mut jac = vec![0.0f64; 6 * n];
    if n == 0 {
        return jac;
    }

    // Tool centre point in the base frame.
    let (px, py, pz) = math::translation_of(&math::mul(frames.last().unwrap(), &tool_transform(tool)));

    for i in 0..n {
        let frame_i = &frames[i];

        let ax = joints[i].axis_x;
        let ay = joints[i].axis_y;
        let az = joints[i].axis_z;

        // Joint axis in the base frame. Rotating the local axis by frame_i's
        // rotation is exact even though frame_i includes joint i's own rotation
        // about that axis: a rotation leaves its own axis fixed.
        let zx = frame_i[0]*ax + frame_i[1]*ay + frame_i[2]*az;
        let zy = frame_i[4]*ax + frame_i[5]*ay + frame_i[6]*az;
        let zz = frame_i[8]*ax + frame_i[9]*ay + frame_i[10]*az;

        // A point on joint i's axis, in the base frame. Rotating about the axis
        // does not move it, so this is the same point before and after theta.
        let (ox, oy, oz) = math::translation_of(frame_i);

        // Position Jacobian: z_i × (p_tcp - o_i)
        let dx = px - ox;
        let dy = py - oy;
        let dz = pz - oz;

        jac[0*n + i] = zy*dz - zz*dy;  // cross product z × d, x
        jac[1*n + i] = zz*dx - zx*dz;  // y
        jac[2*n + i] = zx*dy - zy*dx;  // z

        // Orientation Jacobian: z_i directly
        jac[3*n + i] = zx;
        jac[4*n + i] = zy;
        jac[5*n + i] = zz;
    }

    jac
}
