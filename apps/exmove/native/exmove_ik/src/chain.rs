use rustler::NifStruct;

/// Joint geometry passed from Elixir for each joint in the chain.
#[derive(Debug, Clone, NifStruct)]
#[module = "ExMove.IK.Joint"]
pub struct NifJoint {
    pub origin_x: f64,
    pub origin_y: f64,
    pub origin_z: f64,
    pub roll:     f64,
    pub pitch:    f64,
    pub yaw:      f64,
    pub axis_x:   f64,
    pub axis_y:   f64,
    pub axis_z:   f64,
    /// Joint limits. Set lo >= hi to indicate continuous (no limit).
    pub limit_lo: f64,
    pub limit_hi: f64,
}