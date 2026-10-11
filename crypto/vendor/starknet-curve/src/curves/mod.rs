use crate::{fq::Fq, fr::Fr};
use ark_ec::{
    models::CurveConfig,
    short_weierstrass::{self, SWCurveConfig},
};
use ark_ff::MontFp;

#[cfg(test)]
mod tests;

#[derive(Copy, Clone, Default, PartialEq, Eq)]
pub struct StarkwareParameters;

impl CurveConfig for StarkwareParameters {
    type BaseField = Fq;
    type ScalarField = Fr;

    /// COFACTOR = 1
    const COFACTOR: &'static [u64] = &[1];

    /// COFACTOR_INV = 1
    const COFACTOR_INV: Fr = MontFp!("1");
}

pub type Affine = short_weierstrass::Affine<StarkwareParameters>;
pub type Projective = short_weierstrass::Projective<StarkwareParameters>;

impl SWCurveConfig for StarkwareParameters {
    /// COEFF_A = 1
    const COEFF_A: Fq = MontFp!("1");

    /// COEFF_B = 3141592653589793238462643383279502884197169399375105820974944592307816406665
    const COEFF_B: Fq = MontFp!("3141592653589793238462643383279502884197169399375105820974944592307816406665");

    /// AFFINE_GENERATOR_COEFFS = (G_GENERATOR_X, G_GENERATOR_Y)
    const GENERATOR: Affine = Affine::new_unchecked(G_GENERATOR_X, G_GENERATOR_Y);

    // Open Hearts: the point at infinity carries a flag of its own, as it
    // did in arkworks 0.3, rather than being written as (0, 0).
    type ZeroFlag = bool;
}

/// G_GENERATOR_X = 874739451078007766457464989774322083649278607533249481151382481072868806602
pub const G_GENERATOR_X: Fq = MontFp!("874739451078007766457464989774322083649278607533249481151382481072868806602");

/// G_GENERATOR_Y = 152666792071518830868575557812948353041420400780739481342941381225525861407
pub const G_GENERATOR_Y: Fq = MontFp!("152666792071518830868575557812948353041420400780739481342941381225525861407");
