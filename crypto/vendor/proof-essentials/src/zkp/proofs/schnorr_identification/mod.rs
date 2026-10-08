pub mod proof;
pub mod prover;
mod test;

use crate::error::CryptoError;
use crate::to_bytes::TranscriptCurve;
use crate::zkp::ArgumentOfKnowledge;
use crate::zkp::FiatShamirRng;
use ark_ec::{CurveGroup, PrimeGroup};
use ark_std::marker::PhantomData;
use ark_std::rand::Rng;
use digest::Digest;

pub struct SchnorrIdentification<C: TranscriptCurve> {
    _group: PhantomData<C>,
}

pub type Parameters<C> = <C as CurveGroup>::Affine;

pub type Statement<C> = <C as CurveGroup>::Affine;

pub type Witness<C> = <C as PrimeGroup>::ScalarField;

impl<C: TranscriptCurve> ArgumentOfKnowledge for SchnorrIdentification<C> {
    type CommonReferenceString = Parameters<C>;
    type Statement = Statement<C>;
    type Witness = Witness<C>;
    type Proof = proof::Proof<C>;

    fn prove<R: Rng, D: Digest>(
        rng: &mut R,
        common_reference_string: &Self::CommonReferenceString,
        statement: &Self::Statement,
        witness: &Self::Witness,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<Self::Proof, CryptoError> {
        prover::Prover::create_proof(rng, common_reference_string, statement, witness, fs_rng)
    }

    fn verify<D: Digest>(
        common_reference_string: &Self::CommonReferenceString,
        statement: &Self::Statement,
        proof: &Self::Proof,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<(), CryptoError> {
        proof.verify(common_reference_string, statement, fs_rng)
    }
}

impl<C: TranscriptCurve> SchnorrIdentification<C> {
    pub const PROTOCOL_NAME: &'static [u8] = b"Schnorr Identification Scheme";
}
