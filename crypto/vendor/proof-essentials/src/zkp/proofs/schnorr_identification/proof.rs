use super::{Parameters, Statement};
use crate::error::CryptoError;
use crate::to_bytes;
use crate::to_bytes::TranscriptCurve;
use crate::zkp::FiatShamirRng;

use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::UniformRand;
use digest::Digest;

#[derive(Copy, Clone, CanonicalDeserialize, CanonicalSerialize, Debug, PartialEq, Eq)]
pub struct Proof<C>
where
    C: TranscriptCurve,
{
    pub(crate) random_commit: C,
    pub(crate) opening: C::ScalarField,
}

impl<C: TranscriptCurve> Proof<C> {
    pub fn verify<D: Digest>(
        &self,
        pp: &Parameters<C>,
        statement: &Statement<C>,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<(), CryptoError> {
        fs_rng.absorb(&to_bytes![
            b"schnorr_identity",
            pp,
            statement,
            &self.random_commit
        ]?);

        let c = C::ScalarField::rand(fs_rng);

        if *pp * self.opening + *statement * c != self.random_commit {
            return Err(CryptoError::ProofVerificationError(String::from(
                "Schnorr Identification",
            )));
        }

        Ok(())
    }
}
