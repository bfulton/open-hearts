// Open Hearts: a point in a transcript is normalised first. ark-ec's
// byte form of a projective point is its Jacobian coordinates, which a
// serialisation round trip does not preserve, so a proof made here and
// verified from its bytes hashed two different things. Affine, then
// back, pins Z to one on both sides. (Since the port to arkworks 0.6 the
// byte form is crate::to_bytes's, which writes that normal form itself;
// the normalisation stays, so the proof holds what it always held.)
use crate::error::CryptoError;
use crate::to_bytes;
use crate::to_bytes::TranscriptCurve;
use crate::zkp::FiatShamirRng;

use super::{proof::Proof, Parameters, Statement, Witness};

use ark_ec::AffineRepr;
use ark_std::rand::Rng;
use ark_std::UniformRand;
use digest::Digest;

use std::marker::PhantomData;

pub struct Prover<C>
where
    C: TranscriptCurve,
{
    phantom: PhantomData<C>,
}

impl<C> Prover<C>
where
    C: TranscriptCurve,
{
    pub fn create_proof<R: Rng, D: Digest>(
        rng: &mut R,
        pp: &Parameters<C>,
        statement: &Statement<C>,
        witness: &Witness<C>,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<Proof<C>, CryptoError> {
        let random = C::ScalarField::rand(rng);

        let random_commit = (*pp * random).into_affine().into_group();

        fs_rng.absorb(&to_bytes![
            b"schnorr_identity",
            pp,
            statement,
            random_commit
        ]?);

        let c = C::ScalarField::rand(fs_rng);

        let opening = random - c * witness;

        Ok(Proof {
            random_commit,
            opening,
        })
    }
}
