use super::super::Plaintext;
use crate::to_bytes::TranscriptCurve;

use ark_ec::AffineRepr;
use ark_ff::Zero;
use ark_std::{rand::Rng, UniformRand};
use std::ops::Mul;

impl<C: TranscriptCurve> Mul<C::ScalarField> for Plaintext<C> {
    type Output = Self;
    fn mul(self, x: C::ScalarField) -> Self::Output {
        Self((self.0 * x).into_affine())
    }
}

impl<C: TranscriptCurve> std::ops::Add<Plaintext<C>> for Plaintext<C> {
    type Output = Self;

    fn add(self, _rhs: Self) -> Self {
        Self((self.0 + _rhs.0).into_affine())
    }
}

impl<C: TranscriptCurve> UniformRand for Plaintext<C> {
    fn rand<R: Rng + ?Sized>(rng: &mut R) -> Self {
        Self(C::rand(rng).into_affine())
    }
}

impl<C: TranscriptCurve> Zero for Plaintext<C> {
    fn zero() -> Self {
        Self(C::Affine::zero())
    }

    fn is_zero(&self) -> bool {
        self.0 == C::Affine::zero()
    }
}
