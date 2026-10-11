use crate::error::CryptoError;
use crate::to_bytes::{ToBytes, TranscriptCurve};
use crate::vector_commitment::HomomorphicCommitmentScheme;

use ark_ec::VariableBaseMSM;
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::{io::Write, marker::PhantomData};
use rand::Rng;

pub mod arithmetic_definitions;
mod tests;

pub struct PedersenCommitment<C: TranscriptCurve> {
    _curve: PhantomData<C>,
}

#[derive(Clone, CanonicalSerialize, CanonicalDeserialize, Debug)]
pub struct CommitKey<C: TranscriptCurve> {
    g: Vec<C::Affine>,
    h: C::Affine,
}

impl<C: TranscriptCurve> CommitKey<C> {
    pub fn new(g: Vec<C::Affine>, h: C::Affine) -> Self {
        Self { g, h }
    }
}

impl<C: TranscriptCurve> ToBytes for CommitKey<C> {
    fn write<W: Write>(&self, mut w: W) -> ark_std::io::Result<()> {
        self.g.write(&mut w)?;
        self.h.write(&mut w)?;

        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, CanonicalSerialize, CanonicalDeserialize)]
pub struct Commitment<C: TranscriptCurve>(pub C::Affine);

impl<C: TranscriptCurve> ToBytes for Commitment<C> {
    fn write<W: Write>(&self, mut w: W) -> ark_std::io::Result<()> {
        self.0.write(&mut w)?;

        Ok(())
    }
}

impl<C: TranscriptCurve> HomomorphicCommitmentScheme<C::ScalarField> for PedersenCommitment<C> {
    type CommitKey = CommitKey<C>;
    type Commitment = Commitment<C>;

    fn setup<R: Rng>(public_randomess: &mut R, len: usize) -> CommitKey<C> {
        let mut g = Vec::with_capacity(len);
        for _ in 0..len {
            g.push(C::rand(public_randomess).into_affine());
        }
        let h = C::rand(public_randomess).into_affine();
        CommitKey::<C> { g, h }
    }

    fn commit(
        commit_key: &CommitKey<C>,
        x: &Vec<C::ScalarField>,
        r: C::ScalarField,
    ) -> Result<Self::Commitment, CryptoError> {
        if x.len() > commit_key.g.len() {
            return Err(CryptoError::CommitmentLengthError(
                String::from("Pedersen"),
                x.len(),
                commit_key.g.len(),
            ));
        }

        let scalars = [&[r], x.as_slice()].concat();

        let bases = [&[commit_key.h], &commit_key.g[..x.len()]].concat();

        Ok(Commitment(
            <C as VariableBaseMSM>::msm(&bases, &scalars)
                .expect("as many bases as scalars")
                .into_affine(),
        ))
    }
}
