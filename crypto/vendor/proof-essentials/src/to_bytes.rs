//! Open Hearts: the bytes a Fiat–Shamir transcript hashes, as arkworks
//! 0.3 wrote them.
//!
//! Every challenge in these proofs is drawn from a hash of the statement
//! and the commitments, and arkworks 0.3 wrote those into the hash with
//! its `ToBytes` trait. 0.4 dropped the trait. A proof made today must be
//! checked by a device on the older library, and every proof already kept
//! must still check, so the bytes hashed cannot change by one: this is
//! that trait and its `to_bytes!` macro, with exactly the encodings 0.3
//! gave the types these proofs hash —
//!
//! - integers little-endian, `bool` as one byte, byte strings and arrays
//!   as their bytes, sequences as their elements one after another with
//!   no length;
//! - a field element as the little-endian limbs of its canonical integer
//!   (32 bytes on the Starknet curve);
//! - an affine point as x, y and a byte saying whether it is the point at
//!   infinity, which 0.3 held as (0, 1, true);
//! - a projective point as its Jacobian X, Y, Z. Every projective point a
//!   transcript here takes is normalised first (the prover's, by the fix
//!   recorded in ../README.md; the verifier's, by coming from its bytes),
//!   so its Z is one, or it is 0.3's (1, 1, 0) at infinity: what is
//!   written is that normal form, whatever coordinates 0.6 happens to hold.
//!
//! The golden vectors (crypto/deal/tests/golden.rs) hold every proof made
//! through this to the bytes 0.3 made.

use ark_ec::short_weierstrass::{Affine, Projective, SWCurveConfig};
use ark_ec::{AffineRepr, CurveGroup};
use ark_ff::{BigInteger, Field, Fp, FpConfig, One, PrimeField, Zero};
use std::io::{Result, Write};

/// Writes `self` as arkworks 0.3's `ToBytes` did.
pub trait ToBytes {
    fn write<W: Write>(&self, writer: W) -> Result<()>;
}

/// A curve whose points, affine and projective, have their 0.3 bytes.
pub trait TranscriptCurve: CurveGroup<Affine: ToBytes> + ToBytes {}
impl<C: CurveGroup<Affine: ToBytes> + ToBytes> TranscriptCurve for C {}

/// The bytes of everything named, one after another, as 0.3's macro of
/// the same name.
#[macro_export]
macro_rules! to_bytes {
    ($($x:expr),*) => ({
        let mut buf = ::std::vec::Vec::<u8>::new();
        {$crate::push_to_vec!(buf, $($x),*)}.map(|_| buf)
    });
}

#[doc(hidden)]
#[macro_export]
macro_rules! push_to_vec {
    ($buf:expr, $y:expr, $($x:expr),*) => ({
        {
            $crate::to_bytes::ToBytes::write(&$y, &mut $buf)
        }.and({$crate::push_to_vec!($buf, $($x),*)})
    });

    ($buf:expr, $x:expr) => ({
        $crate::to_bytes::ToBytes::write(&$x, &mut $buf)
    })
}

impl ToBytes for u8 {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        writer.write_all(&[*self])
    }
}

impl ToBytes for u32 {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        writer.write_all(&self.to_le_bytes())
    }
}

impl ToBytes for u64 {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        writer.write_all(&self.to_le_bytes())
    }
}

impl ToBytes for bool {
    fn write<W: Write>(&self, writer: W) -> Result<()> {
        (*self as u8).write(writer)
    }
}

impl<const N: usize> ToBytes for [u8; N] {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        writer.write_all(self)
    }
}

impl<T: ToBytes> ToBytes for Vec<T> {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        for item in self {
            item.write(&mut writer)?;
        }
        Ok(())
    }
}

impl<'a, T: 'a + ToBytes> ToBytes for &'a [T] {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        for item in *self {
            item.write(&mut writer)?;
        }
        Ok(())
    }
}

impl<'a, T: 'a + ToBytes> ToBytes for &'a T {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        (*self).write(&mut writer)
    }
}

/// A field element: the little-endian limbs of its canonical integer, of
/// each base prime field element in turn (one, on a prime field).
pub fn write_field<F: Field, W: Write>(f: &F, mut writer: W) -> Result<()> {
    for e in f.to_base_prime_field_elements() {
        writer.write_all(&e.into_bigint().to_bytes_le())?;
    }
    Ok(())
}

impl<P: FpConfig<N>, const N: usize> ToBytes for Fp<P, N> {
    fn write<W: Write>(&self, writer: W) -> Result<()> {
        write_field(self, writer)
    }
}

impl<P: SWCurveConfig> ToBytes for Affine<P> {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        match self.xy() {
            Some((x, y)) => {
                write_field(&x, &mut writer)?;
                write_field(&y, &mut writer)?;
                false.write(&mut writer)
            }
            None => {
                write_field(&P::BaseField::zero(), &mut writer)?;
                write_field(&P::BaseField::one(), &mut writer)?;
                true.write(&mut writer)
            }
        }
    }
}

impl<P: SWCurveConfig> ToBytes for Projective<P> {
    fn write<W: Write>(&self, mut writer: W) -> Result<()> {
        let (x, y, z) = match self.into_affine().xy() {
            Some((x, y)) => (x, y, P::BaseField::one()),
            None => (P::BaseField::one(), P::BaseField::one(), P::BaseField::zero()),
        };
        write_field(&x, &mut writer)?;
        write_field(&y, &mut writer)?;
        write_field(&z, &mut writer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ark_ec::PrimeGroup;
    use ark_ff::{AdditiveGroup, UniformRand};
    use starknet_curve::{Affine, Fq, Projective};

    #[test]
    fn a_point_is_x_y_and_whether_it_is_infinity() {
        let g = Affine::generator();
        let bytes = to_bytes![g].unwrap();
        assert_eq!(bytes.len(), 65);
        assert_eq!(bytes[..32], g.x.into_bigint().to_bytes_le()[..]);
        assert_eq!(bytes[32..64], g.y.into_bigint().to_bytes_le()[..]);
        assert_eq!(bytes[64], 0);
        let mut zero = vec![0u8; 65];
        zero[32] = 1;
        zero[64] = 1;
        assert_eq!(to_bytes![Affine::zero()].unwrap(), zero, "(0, 1, true), as 0.3 held it");
    }

    #[test]
    fn a_projective_point_is_written_normalised() {
        let rng = &mut ark_std::test_rng();
        let p = Projective::rand(rng);
        let q = p.double() - p; // the same point, with another Z
        let one = Fq::one().into_bigint().to_bytes_le();
        let bytes = to_bytes![q].unwrap();
        assert_eq!(bytes[..64], to_bytes![p.into_affine()].unwrap()[..64]);
        assert_eq!(bytes[64..], one[..]);
        let mut zero = one.clone();
        zero.extend_from_slice(&one);
        zero.extend_from_slice(&[0u8; 32]);
        assert_eq!(to_bytes![Projective::zero()].unwrap(), zero, "(1, 1, 0), as 0.3 held it");
        assert_eq!(to_bytes![Projective::generator() - Projective::generator()].unwrap(), zero);
    }

    #[test]
    fn strings_and_sequences_are_their_bytes() {
        let s: &[u8] = b"abc";
        assert_eq!(to_bytes![s, b"de", 7u32, vec![1u8, 2]].unwrap(), b"abcde\x07\x00\x00\x00\x01\x02");
    }
}
