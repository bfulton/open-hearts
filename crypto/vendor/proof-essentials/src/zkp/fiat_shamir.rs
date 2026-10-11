//! Open Hearts: the Fiat–Shamir generator these proofs draw their
//! challenges from, as ark-marlin 0.3 made it (`ark_marlin::rng::
//! FiatShamirRng`), kept here because ark-marlin was never carried past
//! arkworks 0.3 and every challenge must come out as it did.
//!
//! A ChaCha20 generator keyed by a running hash: seeding hashes the
//! seed's bytes; absorbing hashes the new bytes followed by the current
//! hash, and rekeys. The key is the hash's first 32 bytes. Bytes are
//! written as arkworks 0.3 wrote them (crate::to_bytes).

use crate::to_bytes::ToBytes;
use digest::{Digest, Output};
use rand::{RngCore, SeedableRng};
use rand_chacha::ChaChaRng;

pub struct FiatShamirRng<D: Digest> {
    r: ChaChaRng,
    seed: Output<D>,
}

impl<D: Digest> RngCore for FiatShamirRng<D> {
    #[inline]
    fn next_u32(&mut self) -> u32 {
        self.r.next_u32()
    }

    #[inline]
    fn next_u64(&mut self) -> u64 {
        self.r.next_u64()
    }

    #[inline]
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        self.r.fill_bytes(dest);
    }

    #[inline]
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), rand::Error> {
        self.r.fill_bytes(dest);
        Ok(())
    }
}

fn key<D: Digest>(seed: &Output<D>) -> [u8; 32] {
    let mut key = [0u8; 32];
    key.copy_from_slice(&seed[..32]);
    key
}

impl<D: Digest> FiatShamirRng<D> {
    /// A generator keyed by the hash of [seed].
    pub fn from_seed<T: ToBytes>(seed: &T) -> Self {
        let mut bytes = Vec::new();
        seed.write(&mut bytes).expect("failed to convert to bytes");
        let seed = D::digest(&bytes);
        let r = ChaChaRng::from_seed(key::<D>(&seed));
        Self { r, seed }
    }

    /// Rekeys with the hash of [seed]'s bytes followed by the current hash.
    pub fn absorb<T: ToBytes>(&mut self, seed: &T) {
        let mut bytes = Vec::new();
        seed.write(&mut bytes).expect("failed to convert to bytes");
        bytes.extend_from_slice(&self.seed);
        self.seed = D::digest(&bytes);
        self.r = ChaChaRng::from_seed(key::<D>(&self.seed));
    }
}
