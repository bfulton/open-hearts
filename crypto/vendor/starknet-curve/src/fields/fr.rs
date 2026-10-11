//! The Starknet curve's scalar field: the order of its group.
//!
//! Open Hearts: ported from arkworks 0.3 to 0.6, as fq.rs.
use ark_ff::fields::{Fp256, MontBackend, MontConfig};

#[derive(MontConfig)]
#[modulus = "3618502788666131213697322783095070105526743751716087489154079457884512865583"]
#[generator = "3"]
pub struct FrConfig;

pub type Fr = Fp256<MontBackend<FrConfig, 4>>;
