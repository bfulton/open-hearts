use super::super::Ciphertext;
use crate::to_bytes::TranscriptCurve;
use ark_ec::AffineRepr;
use ark_std::{UniformRand, Zero};
use rand::Rng;
use std::ops::Mul;

impl<C: TranscriptCurve> std::ops::Add<Ciphertext<C>> for Ciphertext<C> {
    type Output = Self;

    fn add(self, _rhs: Self) -> Self {
        Self((self.0 + _rhs.0).into_affine(), (self.1 + _rhs.1).into_affine())
    }
}

impl<C: TranscriptCurve> Mul<C::ScalarField> for Ciphertext<C> {
    type Output = Self;
    fn mul(self, x: C::ScalarField) -> Self::Output {
        Self((self.0 * x).into_affine(), (self.1 * x).into_affine())
    }
}

impl<C: TranscriptCurve> std::iter::Sum for Ciphertext<C> {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self(C::Affine::zero(), C::Affine::zero()), |a, b| a + b)
    }
}

impl<C: TranscriptCurve> Zero for Ciphertext<C> {
    fn zero() -> Self {
        Self(C::Affine::zero(), C::Affine::zero())
    }

    fn is_zero(&self) -> bool {
        *self == Self(C::Affine::zero(), C::Affine::zero())
    }
}

impl<C: TranscriptCurve> UniformRand for Ciphertext<C> {
    fn rand<R: Rng + ?Sized>(rng: &mut R) -> Self {
        let c0 = C::rand(rng).into_affine();
        let c1 = C::rand(rng).into_affine();

        Self(c0, c1)
    }
}

#[cfg(test)]
mod test {

    use super::*;
    use ark_ec::CurveGroup;
    use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
    use ark_std::UniformRand;
    use rand::thread_rng;
    use starknet_curve::Projective;

    #[test]
    fn serialize_unserialize_test() {
        let mut rng = thread_rng();
        let c0 = Projective::rand(&mut rng).into_affine();
        let c1 = Projective::rand(&mut rng).into_affine();

        let cipher = Ciphertext::<Projective>(c0, c1);

        let mut serialized = vec![0; cipher.compressed_size()];
        cipher.serialize_compressed(&mut serialized[..]).unwrap();

        let deserialized = Ciphertext::<Projective>::deserialize_compressed(&serialized[..]).unwrap();
        assert_eq!(cipher, deserialized);
    }
}
