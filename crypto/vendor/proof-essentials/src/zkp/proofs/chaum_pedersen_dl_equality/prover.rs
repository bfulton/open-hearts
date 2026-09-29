// Open Hearts: a point in a transcript is normalised first. ark-ec's
// byte form of a projective point is its Jacobian coordinates, which a
// serialisation round trip does not preserve, so a proof made here and
// verified from its bytes hashed two different things. Affine, then
// back, pins Z to one on both sides.
use crate::error::CryptoError;

use super::proof::Proof;
use super::{Parameters, Statement, Witness};

use ark_ec::{AffineCurve, ProjectiveCurve};
use ark_ff::{to_bytes, PrimeField};
use ark_marlin::rng::FiatShamirRng;
use ark_std::{rand::Rng, UniformRand};
use digest::Digest;

use std::marker::PhantomData;

pub struct Prover<C>
where
    C: ProjectiveCurve,
{
    phantom: PhantomData<C>,
}

impl<C> Prover<C>
where
    C: ProjectiveCurve,
{
    pub fn create_proof<R: Rng, D: Digest>(
        rng: &mut R,
        parameters: &Parameters<C>,
        statement: &Statement<C>,
        witness: &Witness<C>,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<Proof<C>, CryptoError> {
        fs_rng.absorb(
            &to_bytes![
                b"chaum_pedersen",
                parameters.g,
                parameters.h,
                statement.0,
                statement.1
            ]
            .unwrap(),
        );

        let omega = C::ScalarField::rand(rng);
        let a = parameters.g.mul(omega.into_repr()).into_affine().into_projective();
        let b = parameters.h.mul(omega.into_repr()).into_affine().into_projective();

        fs_rng.absorb(&to_bytes![a, b]?);

        let c = C::ScalarField::rand(fs_rng);

        let r = omega + c * *witness;

        Ok(Proof { a, b, r })
    }
}
