use crate::error::CryptoError;
use crate::to_bytes;
use crate::to_bytes::TranscriptCurve;
use crate::zkp::FiatShamirRng;

use super::{Parameters, Statement};

use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::UniformRand;
use digest::Digest;

#[derive(CanonicalDeserialize, CanonicalSerialize)]
pub struct Proof<C>
where
    C: TranscriptCurve,
{
    pub(crate) a: C,
    pub(crate) b: C,
    pub(crate) r: C::ScalarField,
}

impl<C: TranscriptCurve> Proof<C> {
    pub fn verify<D: Digest>(
        &self,
        parameters: &Parameters<C>,
        statement: &Statement<C>,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<(), CryptoError> {
        fs_rng.absorb(&to_bytes![
            b"chaum_pedersen",
            parameters.g,
            parameters.h,
            statement.0,
            statement.1
        ]?);
        fs_rng.absorb(&to_bytes![&self.a, &self.b]?);

        let c = C::ScalarField::rand(fs_rng);

        // g * r ==? a + x*c
        if *parameters.g * self.r != self.a + *statement.0 * c {
            return Err(CryptoError::ProofVerificationError(String::from(
                "Chaum-Pedersen",
            )));
        }

        // h * r ==? b + y*c
        if *parameters.h * self.r != self.b + *statement.1 * c {
            return Err(CryptoError::ProofVerificationError(String::from(
                "Chaum-Pedersen",
            )));
        }

        Ok(())
    }
}
