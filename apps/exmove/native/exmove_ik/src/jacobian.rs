use crate::chain::NifJoint;
use crate::math;

/// Compute the 6×n geometric Jacobian for the chain at joint angles `thetas`.
///
/// Returns a flat row-major matrix: 6 rows × n cols.
/// Rows 0-2: linear velocity (position Jacobian)
/// Rows 3-5: angular velocity (orientation Jacobian)
pub fn compute(joints: &[NifJoint], thetas: &[f64]) -> Vec<f64> {
    let n = joints.len();

    // Build cumulative transforms T_0, T_0·T_1, ..., T_0·...·T_{n-1}
    // T_i is the transform of frame i in the base frame
    let mut frames: Vec<math::Mat4> = Vec::with_capacity(n + 1);
    frames.push(math::identity());

    for (joint, &theta) in joints.iter().zip(thetas.iter()) {
        let t = math::joint_transform(
            joint.origin_x, joint.origin_y, joint.origin_z,
            joint.roll, joint.pitch, joint.yaw,
            joint.axis_x, joint.axis_y, joint.axis_z,
            theta,
        );
        let prev = *frames.last().unwrap();
        frames.push(math::mul(&prev, &t));
    }

    // TCP position in base frame
    let tcp = frames.last().unwrap();
    let (px, py, pz) = math::translation_of(tcp);

    let mut jac = vec![0.0f64; 6 * n];

    for i in 0..n {
        let frame_i = &frames[i];

        // Joint axis in base frame: R_i · axis_i
        // The rotation submatrix of frame_i transforms the local axis
        let ax = joints[i].axis_x;
        let ay = joints[i].axis_y;
        let az = joints[i].axis_z;

        // Rotate axis into base frame using the rotation part of frame_i
        let zx = frame_i[0]*ax + frame_i[1]*ay + frame_i[2]*az;
        let zy = frame_i[4]*ax + frame_i[5]*ay + frame_i[6]*az;
        let zz = frame_i[8]*ax + frame_i[9]*ay + frame_i[10]*az;

        // Origin of joint i in base frame
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