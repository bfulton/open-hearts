use crate::error::CryptoError;
use ark_std::rand::Rng;
use digest::Digest;

pub mod arguments;
pub mod fiat_shamir;
pub mod proofs;

pub use fiat_shamir::FiatShamirRng;

pub trait ArgumentOfKnowledge {
    type CommonReferenceString;
    type Statement;
    type Witness;
    type Proof;

    fn prove<R: Rng, D: Digest>(
        rng: &mut R,
        common_reference_string: &Self::CommonReferenceString,
        statement: &Self::Statement,
        witness: &Self::Witness,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<Self::Proof, CryptoError>;

    fn verify<D: Digest>(
        common_reference_string: &Self::CommonReferenceString,
        statement: &Self::Statement,
        proof: &Self::Proof,
        fs_rng: &mut FiatShamirRng<D>,
    ) -> Result<(), CryptoError>;
}
