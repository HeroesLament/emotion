use crate::chain::NifJoint;
use crate::math;
use crate::jacobian;

#[derive(rustler::NifTaggedEnum)]
pub enum IkResult {
    Ok(Vec<f64>, f64, f64),
    NearSingular(Vec<f64>, f64, f64),
    Constrained(Vec<f64>, f64, f64),
    NoSolution(String),
}

const W_THRESHOLD: f64 = 1e-6;
const LAMBDA_MAX:  f64 = 0.2;
const MAX_STEP:    f64 = 0.2;
const NULL_GAIN:   f64 = 0.1;


pub fn solve(
    joints: &[NifJoint],
    seed: &[f64],
    target_pos: (f64, f64, f64),
    target_rpy: (f64, f64, f64),
    max_iterations: u32,
    tolerance: f64,
    damping: f64,
) -> IkResult {
    let n = joints.len();
    let mut q: Vec<f64> = seed.to_vec();
    clamp_to_limits(&mut q, joints);

    let (tx, ty, tz)   = target_pos;
    let (tr, tp, tyaw) = target_rpy;
    let t_rot = math::rotation_rpy(tr, tp, tyaw);

    let q_mid: Vec<f64> = joints.iter().map(|j| {
        if j.limit_lo < j.limit_hi { (j.limit_lo + j.limit_hi) / 2.0 } else { 0.0 }
    }).collect();

    let mut last_w      = 0.0f64;
    let mut constrained = false;
    let mut best_q      = q.clone();
    let mut best_err    = f64::MAX;

    for _iter in 0..max_iterations {
        let tcp = fk_tcp(joints, &q);
        let (cx, cy, cz) = math::translation_of(&tcp);

        let ep = [tx - cx, ty - cy, tz - cz];
        let eo = orientation_error(&t_rot, &tcp);
        let e  = [ep[0], ep[1], ep[2], eo[0], eo[1], eo[2]];
        let err_norm = e.iter().map(|x| x * x).sum::<f64>().sqrt();

        if err_norm < best_err { best_err = err_norm; best_q = q.clone(); }

        let jac = jacobian::compute(joints, &q);
        let w   = manipulability(&jac, n);
        last_w  = w;

        if err_norm < tolerance {
            let angles = normalize_angles(q);
            let kappa  = condition_number_from_jac(&jac, n);
            let final_constrained = joints.iter().enumerate()
                .any(|(i, _)| is_constrained(joints, i, angles[i]));
            return match (w < W_THRESHOLD, final_constrained) {
                (_, true)      => IkResult::Constrained(angles, w, kappa),
                (true, false)  => IkResult::NearSingular(angles, w, kappa),
                (false, false) => IkResult::Ok(angles, w, kappa),
            };
        }

        // Selective damping: compute per-direction λ from singular values of J,
        // then collapse to an effective scalar λ_eff for the Gaussian DLS solver.
        // This preserves the proven numerical stability of the Gaussian path while
        // getting the benefit of direction-aware damping.
        let sigma = singular_values_of_jjt(&jac, n);
        let lambda = selective_lambda_eff(&sigma, damping);

        let (dq_primary, j_pinv) = dls_step_with_pinv(&jac, &e, n, lambda);

        let dq_null = if n > 6 {
            let dq_0: Vec<f64> = q.iter().zip(q_mid.iter())
                .map(|(qi, qm)| -NULL_GAIN * (qi - qm))
                .collect();
            null_projection(&j_pinv, &jac, &dq_0, n)
        } else {
            vec![0.0; n]
        };

        let mut dq: Vec<f64> = (0..n)
            .map(|i| (dq_primary[i] + dq_null[i]).clamp(-MAX_STEP, MAX_STEP))
            .collect();

        // Active set joint limit clamping
        let active: Vec<bool> = (0..n).map(|i| is_active(joints, i, q[i], dq[i])).collect();
        let any_active = active.iter().any(|&a| a);

        if any_active {
            constrained = true;
            for i in 0..n { if active[i] { dq[i] = 0.0; } }

            let free_idx: Vec<usize> = (0..n).filter(|&i| !active[i]).collect();
            let n_free = free_idx.len();
            if n_free > 0 {
                let jac_free = extract_free_cols(&jac, &free_idx, n);
                let sigma_free = singular_values_of_jjt(&jac_free, n_free);
                let lambda_free = selective_lambda_eff(&sigma_free, damping);
                let (dq_free, _) = dls_step_with_pinv(&jac_free, &e, n_free, lambda_free);
                for (fi, &orig_i) in free_idx.iter().enumerate() {
                    dq[orig_i] = dq_free[fi].clamp(-MAX_STEP, MAX_STEP);
                }
            }
        } else {
            constrained = joints.iter().enumerate()
                .any(|(i, _)| is_constrained(joints, i, q[i]));
        }

        for i in 0..n { q[i] += dq[i]; }
        clamp_to_limits(&mut q, joints);
    }

    if constrained {
        let jac_best = jacobian::compute(joints, &best_q);
        let kappa = condition_number_from_jac(&jac_best, n);
        return IkResult::Constrained(normalize_angles(best_q), last_w, kappa);
    }

    IkResult::NoSolution(format!(
        "max_iterations ({}) reached, manipulability={:.6}",
        max_iterations, last_w
    ))
}

// --- Selective damping -------------------------------------------------------

/// Singular values of J via eigenvalues of JJᵀ, sorted descending.
fn singular_values_of_jjt(jac: &[f64], n: usize) -> Vec<f64> {
    let mut jjt = [[0.0f64; 6]; 6];
    for i in 0..6 {
        for j in 0..6 {
            let mut s = 0.0;
            for k in 0..n { s += jac[i*n+k] * jac[j*n+k]; }
            jjt[i][j] = s;
        }
    }
    let eigenvalues = jacobi_eigenvalues_6(&jjt);
    let mut sigmas: Vec<f64> = eigenvalues.iter()
        .map(|&e| if e > 0.0 { e.sqrt() } else { 0.0 })
        .collect();
    sigmas.sort_by(|a, b| b.partial_cmp(a).unwrap());
    sigmas
}

/// Collapse per-direction λᵢ into a single effective λ for the scalar DLS.
/// Strategy: weight by how much each direction contributes to the step.
/// In practice: take the RMS of the per-direction lambdas, weighted by σᵢ.
/// Well-conditioned directions (large σ) pull λ_eff toward lambda_base.
/// Near-singular directions (small σ) pull toward LAMBDA_MAX.
fn selective_lambda_eff(sigma: &[f64], lambda_base: f64) -> f64 {
    let threshold = lambda_base * 10.0;
    let mut weighted_sum = 0.0f64;
    let mut weight_total = 0.0f64;

    for &si in sigma {
        if si < 1e-12 { continue; }
        // Per-direction lambda: ramps from lambda_base to LAMBDA_MAX as σ → 0
        let li = if si >= threshold {
            lambda_base
        } else {
            let t = si / threshold;
            lambda_base + (LAMBDA_MAX - lambda_base) * (1.0 - t * t)
        };
        // Weight by σ² — large singular values dominate
        let w = si * si;
        weighted_sum += li * w;
        weight_total += w;
    }

    if weight_total < 1e-14 { LAMBDA_MAX }
    else { weighted_sum / weight_total }
}


// --- Core DLS ---------------------------------------------------------------

fn dls_step_with_pinv(jac: &[f64], e: &[f64; 6], n: usize, lambda: f64)
    -> (Vec<f64>, Vec<f64>)
{
    let lambda2 = lambda * lambda;
    let mut a = [[0.0f64; 6]; 6];
    for i in 0..6 {
        for j in 0..6 {
            let mut s = 0.0;
            for k in 0..n { s += jac[i*n+k] * jac[j*n+k]; }
            a[i][j] = s;
        }
        a[i][i] += lambda2;
    }
    let mut a_inv = [[0.0f64; 6]; 6];
    for col in 0..6 {
        let mut rhs = [0.0f64; 6];
        rhs[col] = 1.0;
        let x = gaussian_solve_6(a, rhs);
        for row in 0..6 { a_inv[row][col] = x[row]; }
    }
    let mut j_pinv = vec![0.0f64; n * 6];
    for k in 0..n {
        for j in 0..6 {
            let mut s = 0.0;
            for i in 0..6 { s += jac[i*n+k] * a_inv[i][j]; }
            j_pinv[k*6+j] = s;
        }
    }
    let mut dq = vec![0.0f64; n];
    for k in 0..n {
        for i in 0..6 { dq[k] += j_pinv[k*6+i] * e[i]; }
    }
    (dq, j_pinv)
}

fn null_projection(j_pinv: &[f64], jac: &[f64], dq_0: &[f64], n: usize) -> Vec<f64> {
    let mut jdq = [0.0f64; 6];
    for row in 0..6 {
        for k in 0..n { jdq[row] += jac[row*n+k] * dq_0[k]; }
    }
    let mut jpinv_jdq = vec![0.0f64; n];
    for k in 0..n {
        for j in 0..6 { jpinv_jdq[k] += j_pinv[k*6+j] * jdq[j]; }
    }
    dq_0.iter().zip(jpinv_jdq.iter()).map(|(a, b)| a - b).collect()
}

// --- Active set helpers ------------------------------------------------------

fn is_active(joints: &[NifJoint], i: usize, qi: f64, dqi: f64) -> bool {
    let j = &joints[i];
    if j.limit_lo >= j.limit_hi { return false; }
    (qi + dqi > j.limit_hi && dqi > 0.0) ||
    (qi + dqi < j.limit_lo && dqi < 0.0)
}

fn is_constrained(joints: &[NifJoint], i: usize, qi: f64) -> bool {
    let j = &joints[i];
    if j.limit_lo >= j.limit_hi { return false; }
    qi >= j.limit_hi || qi <= j.limit_lo
}

fn clamp_to_limits(q: &mut Vec<f64>, joints: &[NifJoint]) {
    for (i, j) in joints.iter().enumerate() {
        if j.limit_lo < j.limit_hi {
            q[i] = q[i].clamp(j.limit_lo, j.limit_hi);
        }
    }
}

fn extract_free_cols(jac: &[f64], free_idx: &[usize], n: usize) -> Vec<f64> {
    let n_free = free_idx.len();
    let mut out = vec![0.0f64; 6 * n_free];
    for row in 0..6 {
        for (fi, &ci) in free_idx.iter().enumerate() {
            out[row * n_free + fi] = jac[row * n + ci];
        }
    }
    out
}

// --- Metrics ----------------------------------------------------------------

fn manipulability(jac: &[f64], n: usize) -> f64 {
    let mut jjt = [[0.0f64; 6]; 6];
    for i in 0..6 {
        for j in 0..6 {
            let mut s = 0.0;
            for k in 0..n { s += jac[i*n+k] * jac[j*n+k]; }
            jjt[i][j] = s;
        }
    }
    let det = det6(&jjt);
    if det < 0.0 { 0.0 } else { det.sqrt() }
}

pub fn condition_number_from_jac(jac: &[f64], n: usize) -> f64 {
    let sigmas = singular_values_of_jjt(jac, n);
    let s_min = sigmas.last().copied().unwrap_or(0.0);
    let s_max = sigmas.first().copied().unwrap_or(0.0);
    if s_min < 1e-12 { f64::INFINITY } else { s_max / s_min }
}

pub fn condition_number(jac: &[f64], n: usize) -> f64 {
    condition_number_from_jac(jac, n)
}

// --- Jacobi eigenvalues of 6×6 symmetric matrix -----------------------------

fn jacobi_eigenvalues_6(a: &[[f64; 6]; 6]) -> [f64; 6] {
    let mut m = *a;
    for _ in 0..100 {
        let mut max_val = 0.0f64;
        let mut p = 0usize;
        let mut q = 1usize;
        for i in 0..6 {
            for j in (i+1)..6 {
                if m[i][j].abs() > max_val { max_val = m[i][j].abs(); p = i; q = j; }
            }
        }
        if max_val < 1e-14 { break; }
        let theta = if (m[q][q] - m[p][p]).abs() < 1e-14 {
            std::f64::consts::FRAC_PI_4 * m[p][q].signum()
        } else {
            0.5 * ((2.0 * m[p][q]) / (m[q][q] - m[p][p])).atan()
        };
        let c = theta.cos();
        let s = theta.sin();
        let mpp = m[p][p]; let mqq = m[q][q]; let mpq = m[p][q];
        m[p][p] = c*c*mpp - 2.0*s*c*mpq + s*s*mqq;
        m[q][q] = s*s*mpp + 2.0*s*c*mpq + c*c*mqq;
        m[p][q] = 0.0; m[q][p] = 0.0;
        for r in 0..6 {
            if r == p || r == q { continue; }
            let mrp = m[r][p]; let mrq = m[r][q];
            m[r][p] = c*mrp - s*mrq; m[p][r] = m[r][p];
            m[r][q] = s*mrp + c*mrq; m[q][r] = m[r][q];
        }
    }
    [m[0][0], m[1][1], m[2][2], m[3][3], m[4][4], m[5][5]]
}

// --- FK / orientation helpers -----------------------------------------------

fn normalize_angles(q: Vec<f64>) -> Vec<f64> {
    use std::f64::consts::PI;
    q.into_iter().map(|a| {
        let mut a = a % (2.0 * PI);
        if a >  PI { a -= 2.0 * PI; }
        if a < -PI { a += 2.0 * PI; }
        a
    }).collect()
}

fn fk_tcp(joints: &[NifJoint], q: &[f64]) -> math::Mat4 {
    let mut acc = math::identity();
    for (joint, &theta) in joints.iter().zip(q.iter()) {
        let t = math::joint_transform(
            joint.origin_x, joint.origin_y, joint.origin_z,
            joint.roll, joint.pitch, joint.yaw,
            joint.axis_x, joint.axis_y, joint.axis_z,
            theta,
        );
        acc = math::mul(&acc, &t);
    }
    acc
}

fn orientation_error(r_desired: &math::Mat4, r_current: &math::Mat4) -> [f64; 3] {
    let xd = [r_desired[0], r_desired[4], r_desired[8]];
    let yd = [r_desired[1], r_desired[5], r_desired[9]];
    let zd = [r_desired[2], r_desired[6], r_desired[10]];
    let xc = [r_current[0], r_current[4], r_current[8]];
    let yc = [r_current[1], r_current[5], r_current[9]];
    let zc = [r_current[2], r_current[6], r_current[10]];
    [
        0.5 * (cross(xc, xd)[0] + cross(yc, yd)[0] + cross(zc, zd)[0]),
        0.5 * (cross(xc, xd)[1] + cross(yc, yd)[1] + cross(zc, zd)[1]),
        0.5 * (cross(xc, xd)[2] + cross(yc, yd)[2] + cross(zc, zd)[2]),
    ]
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
}

// --- Linear algebra ---------------------------------------------------------

fn det6(m: &[[f64; 6]; 6]) -> f64 {
    let mut a = *m;
    let mut det = 1.0f64;
    for col in 0..6 {
        let mut max_row = col;
        let mut max_val = a[col][col].abs();
        for row in (col+1)..6 {
            if a[row][col].abs() > max_val { max_val = a[row][col].abs(); max_row = row; }
        }
        if max_row != col { a.swap(col, max_row); det = -det; }
        let pivot = a[col][col];
        if pivot.abs() < 1e-14 { return 0.0; }
        det *= pivot;
        for row in (col+1)..6 {
            let f = a[row][col] / pivot;
            for k in col..6 { a[row][k] -= f * a[col][k]; }
        }
    }
    det
}

fn gaussian_solve_6(mut a: [[f64; 6]; 6], mut b: [f64; 6]) -> [f64; 6] {
    for col in 0..6 {
        let mut max_row = col;
        let mut max_val = a[col][col].abs();
        for row in (col+1)..6 {
            if a[row][col].abs() > max_val { max_val = a[row][col].abs(); max_row = row; }
        }
        a.swap(col, max_row);
        b.swap(col, max_row);
        let pivot = a[col][col];
        if pivot.abs() < 1e-14 { continue; }
        for row in (col+1)..6 {
            let f = a[row][col] / pivot;
            for k in col..6 { a[row][k] -= f * a[col][k]; }
            b[row] -= f * b[col];
        }
    }
    let mut x = [0.0f64; 6];
    for i in (0..6).rev() {
        let mut s = b[i];
        for j in (i+1)..6 { s -= a[i][j] * x[j]; }
        let d = a[i][i];
        x[i] = if d.abs() < 1e-14 { 0.0 } else { s / d };
    }
    x
}
