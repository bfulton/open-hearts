//! The Starknet curve's base field: p = 2^251 + 17·2^192 + 1.
//!
//! Open Hearts: ported from arkworks 0.3, where the Montgomery constants
//! were spelled out, to 0.6, where they are derived from the modulus and
//! the generator. An element is the same Montgomery form (R = 2^256),
//! so a value sampled from the same bytes is the same value; the tests
//! hold R, R² and the generator to the constants 0.3 spelled out.
use ark_ff::fields::{Fp256, MontBackend, MontConfig};

#[derive(MontConfig)]
#[modulus = "3618502788666131213697322783095070105623107215331596699973092056135872020481"]
#[generator = "3"]
pub struct FqConfig;

pub type Fq = Fp256<MontBackend<FqConfig, 4>>;
