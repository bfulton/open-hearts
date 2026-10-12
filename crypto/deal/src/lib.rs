//! The verifiable deal (docs/explanation/fair-deal.md): Barnett–Smart mental
//! poker with the Bayer–Groth shuffle argument, from
//! geometryxyz/mental-poker on the Starknet curve, wrapped as flat
//! functions over byte buffers so the same build serves the browser
//! (wasm32, no bindgen) and the Dart VM (a cdylib over FFI).
//!
//! Everything public is deterministic in its inputs: randomness comes
//! in as a 32-byte seed the caller draws, so a test can replay a deal
//! and a bot seat's operations can be recomputed by everyone from a
//! seed everyone knows.
//!
//! Sizes, all fixed: a point 32 bytes, a scalar 32, a masked card 64,
//! a key-ownership proof 64, a reveal token with its proof 128, a
//! sealed token 64. A shuffle proof is a few kilobytes; its length is
//! returned. A deck is 52 masked cards, 3328 bytes.

use ark_ec::{AffineRepr, CurveGroup};
use ark_ff::{Field, PrimeField, UniformRand};
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::{One, Zero};
use barnett_smart_card_protocol::discrete_log_cards::{self, DLCards, Parameters};
use barnett_smart_card_protocol::{BarnettSmartProtocol, Reveal};
use proof_essentials::homomorphic_encryption::el_gamal::{self, Plaintext};
use proof_essentials::to_bytes;
use proof_essentials::utils::permutation::Permutation;
use rand::SeedableRng;
use rand_chacha::ChaCha20Rng;
use std::sync::OnceLock;

type Curve = starknet_curve::Projective;
type Affine = starknet_curve::Affine;
type Scalar = starknet_curve::Fr;
type Protocol = DLCards<Curve>;
type Card = discrete_log_cards::Card<Curve>;
type Masked = discrete_log_cards::MaskedCard<Curve>;
type Token = discrete_log_cards::RevealToken<Curve>;
type KeyProof = <Protocol as BarnettSmartProtocol>::ZKProofKeyOwnership;
type RevealProof = <Protocol as BarnettSmartProtocol>::ZKProofReveal;
type ShuffleProof = <Protocol as BarnettSmartProtocol>::ZKProofShuffle;

#[cfg(target_arch = "wasm32")]
mod no_entropy {
    use getrandom::{register_custom_getrandom, Error};
    fn none(_: &mut [u8]) -> Result<(), Error> {
        Err(Error::UNSUPPORTED)
    }
    register_custom_getrandom!(none);
}

pub const DECK: usize = 52;
pub const POINT: usize = 32;
pub const SCALAR: usize = 32;
pub const MASKED: usize = 64;
pub const KEY_PROOF: usize = 64;
pub const TOKEN: usize = POINT + 96;
pub const SEALED: usize = 64;
pub const SEAL_PROOF: usize = 3 * POINT + 2 * SCALAR;

/// One argument for a whole batch of reveal tokens, however many.
pub const BATCH_PROOF: usize = 2 * POINT + SCALAR;

/// How long [reveal_tokens] writes for [n] cards: the tokens, and one
/// argument for the lot.
pub const fn tokens_len(n: usize) -> usize {
    n * POINT + BATCH_PROOF
}
pub const DECK_BYTES: usize = DECK * MASKED;

/// The Bayer–Groth argument sees the deck as an m × n matrix, and its
/// size depends on which way the fifty-two are folded, and on nothing
/// else. The four folds, when this one was chosen:
///
/// | m × n | argument |
/// |---|---|
/// | 2 × 26 | 5,496 B |
/// | **4 × 13** | **4,120 B** |
/// | 13 × 4 | 5,848 B |
/// | 26 × 2 | 10,104 B |
///
/// Four by thirteen is a quarter off the argument — 6% off everything
/// a hand's events carry — for somewhat more time to make one and to
/// check one than two by twenty-six takes. A hand makes four and
/// checks four, inside a deal turn that allows fifteen seconds, so the
/// time is affordable where the bytes cross a phone's link four times
/// over. The round trip holds this fold to its size (ops.rs).
const M: usize = 4;
const N: usize = 13;

/// Public parameters and the 52 cards, the same for every table, from
/// fixed seeds: nothing in them is secret, and everyone must agree on
/// them before a card is dealt.
struct Fixed {
    pp: Parameters<Curve>,
    cards: Vec<Card>,
}

fn fixed() -> &'static Fixed {
    static FIXED: OnceLock<Fixed> = OnceLock::new();
    FIXED.get_or_init(|| {
        let mut rng = ChaCha20Rng::from_seed(*b"open-hearts deal parameters v1  ");
        let pp = Protocol::setup(&mut rng, M, N).expect("setup");
        let mut rng = ChaCha20Rng::from_seed(*b"open-hearts fifty-two cards v1  ");
        let cards = (0..DECK).map(|_| Card::rand(&mut rng)).collect();
        Fixed { pp, cards }
    })
}

/// The generator a 32-byte seed drives, or None for a seed shorter
/// than that: refused, as any other input of the wrong size is.
fn rng_from(seed: &[u8]) -> Option<ChaCha20Rng> {
    let s: [u8; 32] = seed.get(..32)?.try_into().ok()?;
    Some(ChaCha20Rng::from_seed(s))
}

/// A seat's keys from its 32-byte secret: the reference crate's own
/// key generation, driven by a generator seeded with the secret, so
/// the same secret always gives the same pair and nothing here needs
/// the parameters' private generator.
fn keys(secret: &[u8]) -> Option<(Affine, Scalar)> {
    if secret.len() < 32 {
        return None;
    }
    Protocol::player_keygen(&mut rng_from(secret)?, &fixed().pp).ok()
}

/// The ElGamal generator the parameters were set up with. The
/// protocol's own parameters keep it private and offer no way to ask
/// for it, but a public key is sk·G, so one throwaway pair gives it
/// back exactly: G = sk⁻¹·pk. Drawn once, and checked in the tests
/// against a second pair.
fn generator() -> Affine {
    static G: OnceLock<Affine> = OnceLock::new();
    *G.get_or_init(|| {
        let (pk, sk) = keys(b"open-hearts generator probe v1  ").expect("probe keys");
        (pk * sk.inverse().expect("a key's secret is not zero")).into_affine()
    })
}

fn write<T: CanonicalSerialize>(v: &T, out: &mut [u8]) -> Option<usize> {
    let n = v.compressed_size();
    if out.len() < n {
        return None;
    }
    v.serialize_compressed(&mut out[..n]).ok()?;
    Some(n)
}

fn read<T: CanonicalDeserialize>(bytes: &[u8]) -> Option<T> {
    T::deserialize_compressed(bytes).ok()
}

fn read_deck(bytes: &[u8]) -> Option<Vec<Masked>> {
    if bytes.len() < DECK_BYTES {
        return None;
    }
    (0..DECK).map(|i| read::<Masked>(&bytes[i * MASKED..(i + 1) * MASKED])).collect()
}

fn write_deck(deck: &[Masked], out: &mut [u8]) -> Option<usize> {
    if out.len() < DECK_BYTES {
        return None;
    }
    for (i, c) in deck.iter().enumerate() {
        write(c, &mut out[i * MASKED..(i + 1) * MASKED])?;
    }
    Some(DECK_BYTES)
}

// ---- the modules -----------------------------------------------------------
//
// The deal's operations (ops.rs), the shares a seat's key and secret
// are held in when the seat has gone (shares.rs), and the flat
// interface wasm and the VM call them through (ffi.rs). Everything
// public in them is public here, where it has always been.

mod ffi;
mod ops;
mod shares;

pub use ffi::*;
pub use ops::*;
pub use shares::*;

/// The seeds the tests draw with: [i] first, so each is its own.
#[cfg(test)]
fn seed(i: u8) -> [u8; 32] {
    let mut s = [0u8; 32];
    s[0] = i;
    s[31] = 7;
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The parameters' generator is private, so it is taken back from
    /// a throwaway pair (see [generator]). Any other pair proves it was
    /// the right one: every public key is that same G times its secret.
    #[test]
    fn the_generator_taken_back_is_the_one_every_key_was_made_with() {
        let g = generator();
        for i in 1..5u8 {
            let mut secret = [0u8; 32];
            secret[0] = i;
            secret[17] = 200 - i;
            let (pk, sk) = keys(&secret).expect("a pair");
            assert_eq!((g * sk).into_affine(), pk, "pair {i}");
        }
    }
}
