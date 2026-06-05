mod math;
mod chain;
mod jacobian;
mod solver;

use chain::NifJoint;
use solver::IkResult;

rustler::init!("Elixir.ExMove.IK.NIF");

/// Compute the 6×n Jacobian at the given joint angles.
/// Returns flat row-major Vec<f64> — 6 rows × n cols.
/// Rows 0-2: linear velocity, rows 3-5: angular velocity.
#[rustler::nif(schedule = "DirtyCpu")]
fn jacobian(joints: Vec<NifJoint>, thetas: Vec<f64>) -> Vec<f64> {
    jacobian::compute(&joints, &thetas)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn solve(
    joints: Vec<NifJoint>,
    seed: Vec<f64>,
    target_pos: (f64, f64, f64),
    target_rpy: (f64, f64, f64),
    max_iterations: u32,
    tolerance: f64,
    damping: f64,
) -> IkResult {
    if joints.len() != seed.len() {
        return IkResult::NoSolution("joints/seed length mismatch".to_string());
    }
    solver::solve(
        &joints, &seed,
        target_pos, target_rpy,
        max_iterations, tolerance, damping,
    )
}
