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
/// size depends on which way the fifty-two are folded. Measured, all
/// four factorisations, by `wire::shuffle_argument_size`:
///
/// | m × n | argument | made | checked |
/// |---|---|---|---|
/// | 2 × 26 | 5,496 B | 105 ms | 103 ms |
/// | **4 × 13** | **4,120 B** | 142 ms | 116 ms |
/// | 13 × 4 | 5,848 B | 290 ms | 158 ms |
/// | 26 × 2 | 10,104 B | 493 ms | 225 ms |
///
/// Four by thirteen is a quarter off the argument — 6% off everything
/// a hand's events carry — for a third more time to make one and a
/// tenth more to check one. A hand makes four and checks four, inside
/// a deal turn that allows fifteen seconds, so the milliseconds are
/// affordable where the bytes cross a phone's link four times over.
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

// ---- the operations, over slices ------------------------------------------

/// A player's public key from a 32-byte secret.
pub fn keygen(secret: &[u8], pk_out: &mut [u8]) -> Option<usize> {
    let (pk, _) = keys(secret)?;
    write(&pk, pk_out)
}

/// Proves knowledge of the secret behind a key, bound to a name.
pub fn key_proof(secret: &[u8], name: &[u8], seed: &[u8], out: &mut [u8]) -> Option<usize> {
    let f = fixed();
    let (pk, sk) = keys(secret)?;
    let mut rng = rng_from(seed)?;
    let name = to_bytes![name].ok()?;
    let proof = Protocol::prove_key_ownership(&mut rng, &f.pp, &pk, &sk, &name).ok()?;
    write(&proof, out)
}

pub fn verify_key(pk: &[u8], name: &[u8], proof: &[u8]) -> bool {
    let f = fixed();
    let (Some(pk), Some(proof)) = (read::<Affine>(pk), read::<KeyProof>(proof)) else {
        return false;
    };
    let Ok(name) = to_bytes![name] else { return false };
    Protocol::verify_key_ownership(&f.pp, &pk, &name, &proof).is_ok()
}

/// The table's key: the sum of every seat's. Each key's proof is the
/// caller's to have checked.
pub fn aggregate(pks: &[u8], out: &mut [u8]) -> Option<usize> {
    let mut acc = Curve::zero();
    for chunk in pks.chunks(POINT) {
        let pk = read::<Affine>(chunk)?;
        acc += pk.into_group();
    }
    write(&acc.into_affine(), out)
}

/// The deck before anyone shuffles: every card masked under the joint
/// key with the masking factor one, which everyone can recompute.
pub fn initial_deck(joint: &[u8], out: &mut [u8]) -> Option<usize> {
    let f = fixed();
    let joint = read::<Affine>(joint)?;
    let mut rng = rng_from(&[0u8; 32])?;
    let deck: Vec<Masked> = f
        .cards
        .iter()
        .map(|c| Protocol::mask(&mut rng, &f.pp, &joint, c, &Scalar::one()).map(|m| m.0))
        .collect::<Result<_, _>>()
        .ok()?;
    write_deck(&deck, out)
}

/// One seat's shuffle: a secret permutation and remasking drawn from
/// [seed], with the argument that the output is a shuffle of the
/// input. Writes the new deck and returns the proof's length.
pub fn shuffle(joint: &[u8], deck_in: &[u8], seed: &[u8], deck_out: &mut [u8], proof_out: &mut [u8]) -> Option<usize> {
    let f = fixed();
    let joint = read::<Affine>(joint)?;
    let deck = read_deck(deck_in)?;
    let mut rng = rng_from(seed)?;
    let permutation = Permutation::new(&mut rng, DECK);
    let factors: Vec<Scalar> = (0..DECK).map(|_| Scalar::rand(&mut rng)).collect();
    let (next, proof) = Protocol::shuffle_and_remask(&mut rng, &f.pp, &joint, &deck, &factors, &permutation).ok()?;
    write_deck(&next, deck_out)?;
    write(&proof, proof_out)
}

pub fn verify_shuffle(joint: &[u8], deck_in: &[u8], deck_out: &[u8], proof: &[u8]) -> bool {
    let f = fixed();
    let (Some(joint), Some(a), Some(b), Some(proof)) =
        (read::<Affine>(joint), read_deck(deck_in), read_deck(deck_out), read::<ShuffleProof>(proof))
    else {
        return false;
    };
    Protocol::verify_shuffle(&f.pp, &joint, &a, &b, &proof).is_ok()
}

/// This seat's share of opening one masked card, with the proof that
/// it was made with the key behind [secret].
pub fn reveal_token(secret: &[u8], masked: &[u8], seed: &[u8], out: &mut [u8]) -> Option<usize> {
    let f = fixed();
    let (pk, sk) = keys(secret)?;
    let masked = read::<Masked>(masked)?;
    let mut rng = rng_from(seed)?;
    let (token, proof) = Protocol::compute_reveal_token(&mut rng, &f.pp, &sk, &pk, &masked).ok()?;
    if out.len() < TOKEN {
        return None;
    }
    let n = write(&token, &mut out[..POINT])?;
    let m = write(&proof, &mut out[POINT..TOKEN])?;
    Some(n + m)
}

pub fn verify_token(pk: &[u8], masked: &[u8], token: &[u8]) -> bool {
    let f = fixed();
    if token.len() < TOKEN {
        return false;
    }
    let (Some(pk), Some(masked), Some(t), Some(proof)) = (
        read::<Affine>(pk),
        read::<Masked>(masked),
        read::<Token>(&token[..POINT]),
        read::<RevealProof>(&token[POINT..TOKEN]),
    ) else {
        return false;
    };
    Protocol::verify_reveal(&f.pp, &pk, &t, &masked, &proof).is_ok()
}

/// Tokens for many cards at once, with one argument for the lot.
///
/// A token is 32 bytes and the proof beside it is 96, and every one
/// of those proofs says the same thing about the same key. A batch
/// says it once.
///
/// The standard batch: take public coefficients ρ_i that the prover
/// cannot choose, from a hash of the whole statement, and argue about
/// the combination instead of the parts —
///
/// ```text
///     H = Σ ρ_i·C1_i        B = Σ ρ_i·T_i
///     pk = sk·G             B = sk·H
/// ```
///
/// A seat that gets one token wrong moves B off sk·H, and can only
/// put it back by knowing the ρ_i before it commits, which the hash
/// denies it: a bad batch passes with probability about 1/|F|. The
/// argument itself is the same Σ-protocol as [seal] over one witness —
/// commit with a random a, challenge from a hash of the statement,
/// answer z = a + c·sk.
///
/// Writes [tokens_len] bytes: the tokens in the order the cards came
/// in, then the argument. [unmask] takes the tokens alone.
pub fn reveal_tokens(secret: &[u8], masked_many: &[u8], seed: &[u8], out: &mut [u8]) -> Option<usize> {
    let g = generator();
    let (pk, sk) = keys(secret)?;
    let n = masked_many.len() / MASKED;
    if n == 0 || !masked_many.len().is_multiple_of(MASKED) || out.len() < tokens_len(n) {
        return None;
    }
    let mut cards = Vec::with_capacity(n);
    for i in 0..n {
        cards.push(read::<Masked>(&masked_many[i * MASKED..(i + 1) * MASKED])?);
    }
    for (i, m) in cards.iter().enumerate() {
        let token: Token = el_gamal::Plaintext((m.0 * sk).into_affine());
        write(&token, &mut out[i * POINT..(i + 1) * POINT])?;
    }
    let (h, b) = batch_points(&pk, &cards, &out[..n * POINT])?;

    let mut rng = rng_from(seed)?;
    let a = Scalar::rand(&mut rng);
    let a1 = (g * a).into_affine();
    let a2 = (h * a).into_affine();
    let c = batch_challenge(&pk, &h, &b, &a1, &a2)?;
    let z = a + c * sk;

    let p = &mut out[n * POINT..tokens_len(n)];
    write(&a1, &mut p[..POINT])?;
    write(&a2, &mut p[POINT..2 * POINT])?;
    write(&z, &mut p[2 * POINT..])?;
    Some(tokens_len(n))
}

/// Whether a batch of tokens is the one [pk] owes for those cards, in
/// that order: what [reveal_tokens] wrote, checked by anybody.
pub fn verify_tokens(pk: &[u8], masked_many: &[u8], tokens: &[u8]) -> bool {
    let g = generator();
    let n = masked_many.len() / MASKED;
    if n == 0 || !masked_many.len().is_multiple_of(MASKED) || tokens.len() < tokens_len(n) {
        return false;
    }
    let Some(pk) = read::<Affine>(pk) else { return false };
    let mut cards = Vec::with_capacity(n);
    for i in 0..n {
        let Some(m) = read::<Masked>(&masked_many[i * MASKED..(i + 1) * MASKED]) else {
            return false;
        };
        cards.push(m);
    }
    let Some((h, b)) = batch_points(&pk, &cards, &tokens[..n * POINT]) else { return false };
    let p = &tokens[n * POINT..tokens_len(n)];
    let (Some(a1), Some(a2), Some(z)) = (
        read::<Affine>(&p[..POINT]),
        read::<Affine>(&p[POINT..2 * POINT]),
        read::<Scalar>(&p[2 * POINT..]),
    ) else {
        return false;
    };
    let Some(c) = batch_challenge(&pk, &h, &b, &a1, &a2) else { return false };
    (g * z) == a1.into_group() + (pk * c)
        && (h * z) == a2.into_group() + (b * c)
}

/// The two points a batch argues about: H, the cards' first halves
/// weighted by coefficients nobody chose, and B, the tokens weighted
/// the same. The coefficients come from a hash of the key, the cards
/// and the tokens together, so a seat cannot know one before it has
/// committed to all of them.
fn batch_points(pk: &Affine, cards: &[Masked], tokens: &[u8]) -> Option<(Affine, Affine)> {
    use blake2::{Blake2b512 as Blake2b, Digest};
    let mut bytes = b"open-hearts batch tokens v1".to_vec();
    bytes.extend(to_bytes![pk].ok()?);
    for m in cards {
        bytes.extend(to_bytes![m.0, m.1].ok()?);
    }
    bytes.extend(tokens);
    let mut rng = ChaCha20Rng::from_seed(<[u8; 32]>::try_from(&Blake2b::digest(&bytes)[..32]).ok()?);
    let mut h = Curve::zero();
    let mut b = Curve::zero();
    for (i, m) in cards.iter().enumerate() {
        let rho = Scalar::rand(&mut rng);
        let t = read::<Token>(&tokens[i * POINT..(i + 1) * POINT])?;
        h += m.0 * rho;
        b += t.0 * rho;
    }
    Some((h.into_affine(), b.into_affine()))
}

fn batch_challenge(pk: &Affine, h: &Affine, b: &Affine, a1: &Affine, a2: &Affine) -> Option<Scalar> {
    use blake2::{Blake2b512 as Blake2b, Digest};
    let mut bytes = b"open-hearts batch challenge v1".to_vec();
    bytes.extend(to_bytes![pk, h, b, a1, a2].ok()?);
    Some(Scalar::from_le_bytes_mod_order(&Blake2b::digest(&bytes)))
}

/// A seat's key split into additive shares, so that its cards can be
/// opened without anyone putting the key back together
/// (docs/explanation/live-play.md). The shares add to the key behind [secret]:
/// no smaller set is anything, and [share_key] of them aggregates to
/// the seat's own public key, which is what says a split is a split
/// of *that* key.
///
/// It splits the key itself, in the field it lives in, rather than the
/// secret's bytes, so a departed seat's cards open position by
/// position and its key is never rebuilt.
pub fn split(secret: &[u8], shares: usize, seed: &[u8], out: &mut [u8]) -> Option<usize> {
    if shares < 2 || out.len() < shares * SCALAR {
        return None;
    }
    let (_, sk) = keys(secret)?;
    let mut rng = rng_from(seed)?;
    // Every share but the last is drawn; the last is what is left, so
    // they add to the key and no smaller set of them is anything.
    let mut rest = sk;
    for i in 0..shares - 1 {
        let a = Scalar::rand(&mut rng);
        rest -= a;
        write(&a, &mut out[i * SCALAR..(i + 1) * SCALAR])?;
    }
    write(&rest, &mut out[(shares - 1) * SCALAR..shares * SCALAR])?;
    Some(shares * SCALAR)
}

// ---- shares of bytes ----------------------------------------------------
//
// A seat's *secret* is thirty-two bytes, not a scalar, and it is what
// answers before the deck is dealt and at the audit — so it needs the
// same t-of-n shape the key has, over the field bytes live in.
// GF(2^8) with the usual polynomial: addition is xor, which is why
// summing shares is summing them.

/// Two bytes multiplied in GF(2^8), the field a byte is.
fn gf_mul(mut a: u8, mut b: u8) -> u8 {
    let mut out = 0u8;
    for _ in 0..8 {
        if b & 1 != 0 {
            out ^= a;
        }
        let high = a & 0x80;
        a <<= 1;
        if high != 0 {
            a ^= 0x1b;
        }
        b >>= 1;
    }
    out
}

/// A byte's inverse: a^254, since a^255 is one for every a but zero.
fn gf_inv(a: u8) -> Option<u8> {
    if a == 0 {
        return None;
    }
    let mut out = 1u8;
    let mut power = a;
    // 254 = 0b11111110
    for bit in 1..8 {
        power = gf_mul(power, power);
        if 254 >> bit & 1 != 0 {
            out = gf_mul(out, power);
        }
    }
    Some(out)
}

/// A secret of any length in [n] shares of the same length, any [t] of
/// which rebuild it. Each byte gets its own polynomial of degree t−1
/// over GF(2^8), drawn from [seed], and share i is every byte's
/// polynomial at x = i; the index of a share is its place in the list,
/// counted from one, as with [split_threshold].
pub fn share_bytes(secret: &[u8], n: usize, t: usize, seed: &[u8], out: &mut [u8]) -> Option<usize> {
    let len = secret.len();
    if len == 0 || t < 2 || n < t || n > 255 || out.len() < n * len {
        return None;
    }
    let mut rng = rng_from(seed)?;
    // The coefficients above the constant term, one set per byte.
    let mut above = vec![0u8; len * (t - 1)];
    rand::RngCore::fill_bytes(&mut rng, &mut above);
    for i in 1..=n {
        for b in 0..len {
            let mut y = secret[b];
            let mut power = i as u8;
            for c in 0..t - 1 {
                y ^= gf_mul(above[b * (t - 1) + c], power);
                power = gf_mul(power, i as u8);
            }
            out[(i - 1) * len + b] = y;
        }
    }
    Some(n * len)
}

/// What the share at [index] is worth among the shares [have] holds,
/// evaluated [at] an index — [lagrange] in the field bytes live in,
/// and the same two uses: zero to rebuild the secret, another index to
/// make that index's share.
pub fn bytes_lagrange(have: &[u8], index: u8, at: u8) -> Option<u8> {
    if have.is_empty() || !have.contains(&index) || index == 0 || have.contains(&0) {
        return None;
    }
    let mut seen = have.to_vec();
    seen.sort_unstable();
    seen.dedup();
    if seen.len() != have.len() {
        return None;
    }
    let mut c = 1u8;
    for k in have {
        if *k == index {
            continue;
        }
        c = gf_mul(c, gf_mul(at ^ *k, gf_inv(index ^ *k)?));
    }
    Some(c)
}

/// A share scaled by its coefficient: what a holder sends, rather than
/// the share.
pub fn bytes_scale(share: &[u8], by: u8, out: &mut [u8]) -> Option<usize> {
    if out.len() < share.len() {
        return None;
    }
    for (i, b) in share.iter().enumerate() {
        out[i] = gf_mul(*b, by);
    }
    Some(share.len())
}

/// Scaled shares summed — which in this field is xor — into the
/// secret, or into the share of whatever index they were scaled
/// towards.
pub fn bytes_sum(parts: &[u8], len: usize, out: &mut [u8]) -> Option<usize> {
    if len == 0 || parts.is_empty() || !parts.len().is_multiple_of(len) || out.len() < len {
        return None;
    }
    out[..len].fill(0);
    for i in 0..parts.len() / len {
        for b in 0..len {
            out[b] ^= parts[i * len + b];
        }
    }
    Some(len)
}

/// A seat's key in [n] Shamir shares over the same scalar field, any
/// [t] of which rebuild it — where [split] makes shares that are all
/// needed at once.
///
/// A threshold because a hand's escrow rests on the jurors it was
/// sealed to still being reachable when a bot seat has to be opened
/// (docs/explanation/live-play.md). "Any two of the jury" keeps one holder
/// alone from being anything, with room to lose people.
///
/// The shares are f(1)..f(n) of a polynomial of degree t−1 whose
/// constant term is the key, drawn from [seed]. Written in index
/// order, [SCALAR] each; the index of a share is its place in the
/// list, counted from one, and is what [lagrange] needs.
///
/// Nothing here ever puts the key back together. A share's token is
/// scaled by its (public) Lagrange coefficient and the scaled tokens
/// *add*, exactly as the shares of [split] add.
pub fn split_threshold(secret: &[u8], n: usize, t: usize, seed: &[u8], out: &mut [u8]) -> Option<usize> {
    if t < 2 || n < t || n > 255 || out.len() < n * SCALAR {
        return None;
    }
    let (_, sk) = keys(secret)?;
    let mut rng = rng_from(seed)?;
    // f(x) = sk + a1·x + … + a(t−1)·x^(t−1)
    let coefficients: Vec<Scalar> = (1..t).map(|_| Scalar::rand(&mut rng)).collect();
    for i in 1..=n {
        let x = Scalar::from(i as u64);
        let mut y = sk;
        let mut power = x;
        for a in &coefficients {
            y += *a * power;
            power *= x;
        }
        write(&y, &mut out[(i - 1) * SCALAR..i * SCALAR])?;
    }
    Some(n * SCALAR)
}

/// The Lagrange coefficient for the share at [index], among the set
/// of shares [have] holds, evaluated at [at].
///
/// At zero it is what that share's part is worth towards the key
/// itself: Σ over the set of coefficient·share is the key, so Σ of
/// coefficient·(share·C1) is the seat's own token, and the card comes
/// out. At another index it is what the share is worth towards *that*
/// index's share — which is how a newcomer to the jury is given one
/// without anybody rebuilding the key (docs/explanation/live-play.md).
///
/// [have] is one byte per index, each 1..=255 and distinct; [index]
/// must be among them.
pub fn lagrange(have: &[u8], index: u8, at: u8, out: &mut [u8]) -> Option<usize> {
    if have.is_empty() || !have.contains(&index) || index == 0 {
        return None;
    }
    let mut seen = have.to_vec();
    seen.sort_unstable();
    seen.dedup();
    if seen.len() != have.len() || seen.first() == Some(&0) {
        return None;
    }
    let xi = Scalar::from(index as u64);
    let x = Scalar::from(at as u64);
    let mut c = Scalar::one();
    for k in have {
        if *k == index {
            continue;
        }
        let xk = Scalar::from(*k as u64);
        c *= (x - xk) * (xi - xk).inverse()?;
    }
    write(&c, out)
}

/// Two scalars multiplied: a share by its coefficient, which is what
/// a holder sends rather than the share itself.
pub fn scalar_mul(a: &[u8], b: &[u8], out: &mut [u8]) -> Option<usize> {
    write(&(read::<Scalar>(a)? * read::<Scalar>(b)?), out)
}

/// Scalars added: the parts a newcomer is sent, summed into the share
/// it now holds.
pub fn scalar_sum(parts: &[u8], out: &mut [u8]) -> Option<usize> {
    if parts.is_empty() || !parts.len().is_multiple_of(SCALAR) {
        return None;
    }
    let mut sum = Scalar::zero();
    for i in 0..parts.len() / SCALAR {
        sum += read::<Scalar>(&parts[i * SCALAR..(i + 1) * SCALAR])?;
    }
    write(&sum, out)
}

/// A point scaled by a scalar: a share's key by its coefficient, so
/// that anybody can check the scaled token against it.
pub fn point_scale(point: &[u8], scalar: &[u8], out: &mut [u8]) -> Option<usize> {
    let p = read::<Affine>(point)?;
    let s = read::<Scalar>(scalar)?;
    write(&(p * s).into_affine(), out)
}

/// One share's public key: what that share's token is checked
/// against, and one of the keys the seat's own is the sum of.
pub fn share_key(share: &[u8], out: &mut [u8]) -> Option<usize> {
    let s = read::<Scalar>(share)?;
    write(&(generator() * s).into_affine(), out)
}

/// One share's part of opening a masked card, proved against that
/// share's key exactly as a whole seat's token is proved against its
/// own.
///
/// Nothing needs to combine them. [unmask] adds every token it is
/// handed, so a seat's two shares go in as two tokens beside the other
/// seats' and the card comes out — and the key they are shares of was
/// never anywhere.
pub fn share_token(share: &[u8], masked: &[u8], seed: &[u8], out: &mut [u8]) -> Option<usize> {
    let f = fixed();
    let sk = read::<Scalar>(share)?;
    let pk = (generator() * sk).into_affine();
    let masked = read::<Masked>(masked)?;
    let mut rng = rng_from(seed)?;
    let (token, proof) = Protocol::compute_reveal_token(&mut rng, &f.pp, &sk, &pk, &masked).ok()?;
    if out.len() < TOKEN {
        return None;
    }
    let n = write(&token, &mut out[..POINT])?;
    let m = write(&proof, &mut out[POINT..TOKEN])?;
    Some(n + m)
}

/// The card behind [masked] given every seat's token. [tokens] are the
/// bare 32-byte tokens, one per key in [pks], with no proofs among
/// them: a token is checked when it arrives — against its key, singly
/// or in a batch ([verify_tokens]) — and what is kept afterwards is the
/// token alone, since a proof checked twice is most of the cost of a
/// card. Opening is addition, and addition has nothing to check.
pub fn unmask(pks: &[u8], tokens: &[u8], masked: &[u8]) -> Option<usize> {
    let f = fixed();
    let masked = read::<Masked>(masked)?;
    let n = pks.len() / POINT;
    if tokens.len() < n * POINT {
        return None;
    }
    let mut aggregate = Token::zero();
    for i in 0..n {
        aggregate = aggregate + read::<Token>(&tokens[i * POINT..(i + 1) * POINT])?;
    }
    let card = aggregate.reveal(&masked).ok()?;
    f.cards.iter().position(|c| *c == card)
}

/// A token for another seat's eyes only — a passed card — ElGamal
/// encrypted to that seat's key, with the argument that it is the right
/// token. Writes [SEALED] bytes of ciphertext and then [SEAL_PROOF] of
/// argument.
///
/// Sealing hides the token from everyone but the seat it is for, so
/// without an argument nobody else could tell an honest seal from a
/// bad one: a passer could send three cards the receiver would never
/// open, and no third party could say whose fault it was
/// (docs/explanation/fair-deal.md). The argument says, to anybody, that
/// what is inside the ciphertext is the share the owner's key owes for
/// that card — without saying what the share is.
///
/// Knowledge of the two secrets (sk, r) behind
///
/// ```text
///     pk = sk·G                    the owner's key
///     c1 = r·G                     the seal's first half
///     c2 = sk·C1 + r·pk_to         its second: the token sk·C1, blinded
/// ```
///
/// where C1 is the masked card's first half, and sk·C1 is exactly the
/// reveal token [reveal_token] would make. One Σ-protocol over two
/// witnesses, made non-interactive the usual way: commit with random
/// (a, b), take the challenge from a hash of the whole statement, and
/// answer z1 = a + c·sk, z2 = b + c·r.
pub fn seal(secret: &[u8], pk_to: &[u8], masked: &[u8], seed: &[u8], out: &mut [u8]) -> Option<usize> {
    let g = generator();
    let (pk, sk) = keys(secret)?;
    let to = read::<Affine>(pk_to)?;
    let m = read::<Masked>(masked)?;
    if out.len() < SEALED + SEAL_PROOF {
        return None;
    }
    let mut rng = rng_from(seed)?;
    let r = Scalar::rand(&mut rng);

    let token = m.0 * sk;
    let c1 = g * r;
    let c2 = token + (to * r);
    let sealed: Masked = el_gamal::Ciphertext(c1.into_affine(), c2.into_affine());

    let a = Scalar::rand(&mut rng);
    let b = Scalar::rand(&mut rng);
    let a1 = (g * a).into_affine();
    let a2 = (g * b).into_affine();
    let a3 = ((m.0 * a) + (to * b)).into_affine();
    let c = seal_challenge(&m, &pk, &to, &sealed, &a1, &a2, &a3)?;
    let z1 = a + c * sk;
    let z2 = b + c * r;

    let n = write(&sealed, &mut out[..SEALED])?;
    let p = &mut out[SEALED..SEALED + SEAL_PROOF];
    write(&a1, &mut p[..POINT])?;
    write(&a2, &mut p[POINT..2 * POINT])?;
    write(&a3, &mut p[2 * POINT..3 * POINT])?;
    write(&z1, &mut p[3 * POINT..3 * POINT + SCALAR])?;
    write(&z2, &mut p[3 * POINT + SCALAR..])?;
    Some(n + SEAL_PROOF)
}

/// Whether a sealed token is the one [pk_owner] owes for [masked],
/// sealed to [pk_to]: the argument [seal] wrote, checked by anybody.
/// [sealed] is the [SEALED] + [SEAL_PROOF] bytes seal returned.
pub fn verify_seal(pk_owner: &[u8], pk_to: &[u8], masked: &[u8], sealed: &[u8]) -> bool {
    let g = generator();
    if sealed.len() < SEALED + SEAL_PROOF {
        return false;
    }
    let p = &sealed[SEALED..SEALED + SEAL_PROOF];
    let (Some(pk), Some(to), Some(m), Some(s), Some(a1), Some(a2), Some(a3), Some(z1), Some(z2)) = (
        read::<Affine>(pk_owner),
        read::<Affine>(pk_to),
        read::<Masked>(masked),
        read::<Masked>(&sealed[..SEALED]),
        read::<Affine>(&p[..POINT]),
        read::<Affine>(&p[POINT..2 * POINT]),
        read::<Affine>(&p[2 * POINT..3 * POINT]),
        read::<Scalar>(&p[3 * POINT..3 * POINT + SCALAR]),
        read::<Scalar>(&p[3 * POINT + SCALAR..]),
    ) else {
        return false;
    };
    let Some(c) = seal_challenge(&m, &pk, &to, &s, &a1, &a2, &a3) else {
        return false;
    };
    (g * z1) == a1.into_group() + (pk * c)
        && (g * z2) == a2.into_group() + (s.0 * c)
        && (m.0 * z1) + (to * z2)
            == a3.into_group() + (s.1 * c)
}

/// The challenge a sealed token's argument answers: every public part
/// of the statement and the three commitments, hashed under a tag of
/// its own and taken into the scalar field. Sixty-four bytes go in, so
/// what comes out is a scalar with nothing to choose between its
/// values.
fn seal_challenge(
    masked: &Masked,
    pk_owner: &Affine,
    pk_to: &Affine,
    sealed: &Masked,
    a1: &Affine,
    a2: &Affine,
    a3: &Affine,
) -> Option<Scalar> {
    use blake2::{Blake2b512 as Blake2b, Digest};
    let bytes = to_bytes![
        b"open-hearts sealed token v1",
        masked.0,
        masked.1,
        pk_owner,
        pk_to,
        sealed.0,
        sealed.1,
        a1,
        a2,
        a3
    ]
    .ok()?;
    Some(Scalar::from_le_bytes_mod_order(&Blake2b::digest(&bytes)))
}

/// A secret two seats share and nobody else can compute: the hash of
/// the point [pk] times this seat's key. Both sides get the same 32
/// bytes; what a seat keeps for another — a share of its deal secret,
/// held against its leaving — is encrypted with it (packages/deal).
pub fn shared_secret(secret: &[u8], pk: &[u8], out: &mut [u8]) -> Option<usize> {
    use blake2::{Blake2s256 as Blake2s, Digest};
    let (_, sk) = keys(secret)?;
    let pk = read::<Affine>(pk)?;
    let point = (pk * sk).into_affine();
    let mut bytes = Vec::with_capacity(POINT);
    point.serialize_compressed(&mut bytes).ok()?;
    let digest = Blake2s::digest(&bytes);
    if out.len() < 32 {
        return None;
    }
    out[..32].copy_from_slice(&digest[..32]);
    Some(32)
}

/// Opens a sealed token with the key it was sealed to.
pub fn open(secret: &[u8], sealed: &[u8], out: &mut [u8]) -> Option<usize> {
    let (_, sk) = keys(secret)?;
    let c = read::<Masked>(sealed)?;
    let s = (c.0 * sk).into_affine();
    let m = (c.1 + (-s)).into_affine();
    write(&Plaintext::<Curve>(m), out)
}

/// The token behind a seal, from the parts the shares of the
/// recipient's key made of it: the same arithmetic [`open`] does, with
/// a key nobody holds.
///
/// A seal is a ciphertext of the same shape as a masked card, so a
/// share's part of opening one is a reveal token made with that share
/// over the seal itself — [`share_token`] makes it and [`verify_token`]
/// checks it, and this adds them up and takes them off.
pub fn open_shared(sealed: &[u8], parts: &[u8], out: &mut [u8]) -> Option<usize> {
    let c = read::<Masked>(sealed)?;
    let mut sum = Curve::zero();
    for chunk in parts.chunks(POINT) {
        sum += read::<Affine>(chunk)?.into_group();
    }
    let m = (c.1 + (-sum.into_affine())).into_affine();
    write(&Plaintext::<Curve>(m), out)
}

// ---- the flat interface -----------------------------------------------------
//
// Every function takes pointers and lengths into memory the caller
// owns (from `deal_alloc`), returns the bytes written or -1, and never
// keeps a reference. The same symbols serve wasm and the VM's FFI.
//
// Safety, for every unsafe function here: each pointer is null or
// valid for as many bytes as the function reads or writes through it
// (the fixed sizes above, or the length or count passed beside it), and
// no output overlaps an input. A null pointer reads as empty, which
// fails the call.

use std::slice;

/// Reads the fixed parameters in, so the first deal does not pay for it.
#[no_mangle]
pub extern "C" fn deal_setup() {
    let _ = fixed();
}

#[no_mangle]
pub extern "C" fn deal_alloc(n: usize) -> *mut u8 {
    let mut v = Vec::<u8>::with_capacity(n.max(1));
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    p
}

/// # Safety
/// `p` came from `deal_alloc(n)`.
#[no_mangle]
pub unsafe extern "C" fn deal_free(p: *mut u8, n: usize) {
    drop(Vec::from_raw_parts(p, 0, n.max(1)));
}

unsafe fn input<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if p.is_null() { &[] } else { slice::from_raw_parts(p, n) }
}

unsafe fn output<'a>(p: *mut u8, n: usize) -> &'a mut [u8] {
    if p.is_null() { &mut [] } else { slice::from_raw_parts_mut(p, n) }
}

fn done(r: Option<usize>) -> i32 {
    r.map(|n| n as i32).unwrap_or(-1)
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_keygen(secret: *const u8, out: *mut u8) -> i32 {
    done(keygen(input(secret, SCALAR), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_key_proof(secret: *const u8, name: *const u8, name_len: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(key_proof(input(secret, SCALAR), input(name, name_len), input(seed, 32), output(out, KEY_PROOF)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_key(pk: *const u8, name: *const u8, name_len: usize, proof: *const u8) -> i32 {
    verify_key(input(pk, POINT), input(name, name_len), input(proof, KEY_PROOF)) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_aggregate(pks: *const u8, count: usize, out: *mut u8) -> i32 {
    done(aggregate(input(pks, count * POINT), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_initial_deck(joint: *const u8, out: *mut u8) -> i32 {
    done(initial_deck(input(joint, POINT), output(out, DECK_BYTES)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_shuffle(joint: *const u8, deck_in: *const u8, seed: *const u8, deck_out: *mut u8, proof_out: *mut u8, proof_cap: usize) -> i32 {
    done(shuffle(input(joint, POINT), input(deck_in, DECK_BYTES), input(seed, 32), output(deck_out, DECK_BYTES), output(proof_out, proof_cap)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_shuffle(joint: *const u8, deck_in: *const u8, deck_out: *const u8, proof: *const u8, proof_len: usize) -> i32 {
    verify_shuffle(input(joint, POINT), input(deck_in, DECK_BYTES), input(deck_out, DECK_BYTES), input(proof, proof_len)) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_reveal_token(secret: *const u8, masked: *const u8, seed: *const u8, out: *mut u8) -> i32 {
    done(reveal_token(input(secret, SCALAR), input(masked, MASKED), input(seed, 32), output(out, TOKEN)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_split(secret: *const u8, shares: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(split(input(secret, SCALAR), shares, input(seed, 32), output(out, shares * SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_share_bytes(secret: *const u8, len: usize, n: usize, t: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(share_bytes(input(secret, len), n, t, input(seed, 32), output(out, n * len)))
}

/// The coefficient itself, since it is one byte: negative for a set
/// that is not one.
///
/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_bytes_lagrange(have: *const u8, count: usize, index: u8, at: u8) -> i32 {
    match bytes_lagrange(input(have, count), index, at) {
        Some(c) => c as i32,
        None => -1,
    }
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_bytes_scale(share: *const u8, len: usize, by: u8, out: *mut u8) -> i32 {
    done(bytes_scale(input(share, len), by, output(out, len)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_bytes_sum(parts: *const u8, count: usize, len: usize, out: *mut u8) -> i32 {
    done(bytes_sum(input(parts, count * len), len, output(out, len)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_split_threshold(secret: *const u8, n: usize, t: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(split_threshold(input(secret, SCALAR), n, t, input(seed, 32), output(out, n * SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_lagrange(have: *const u8, count: usize, index: u8, at: u8, out: *mut u8) -> i32 {
    done(lagrange(input(have, count), index, at, output(out, SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_scalar_mul(a: *const u8, b: *const u8, out: *mut u8) -> i32 {
    done(scalar_mul(input(a, SCALAR), input(b, SCALAR), output(out, SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_scalar_sum(parts: *const u8, count: usize, out: *mut u8) -> i32 {
    done(scalar_sum(input(parts, count * SCALAR), output(out, SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_point_scale(point: *const u8, scalar: *const u8, out: *mut u8) -> i32 {
    done(point_scale(input(point, POINT), input(scalar, SCALAR), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_share_key(share: *const u8, out: *mut u8) -> i32 {
    done(share_key(input(share, SCALAR), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_share_token(share: *const u8, masked: *const u8, seed: *const u8, out: *mut u8) -> i32 {
    done(share_token(input(share, SCALAR), input(masked, MASKED), input(seed, 32), output(out, TOKEN)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_open_shared(sealed: *const u8, parts: *const u8, count: usize, out: *mut u8) -> i32 {
    done(open_shared(input(sealed, SEALED), input(parts, count * POINT), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_token(pk: *const u8, masked: *const u8, token: *const u8) -> i32 {
    verify_token(input(pk, POINT), input(masked, MASKED), input(token, TOKEN)) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_unmask(pks: *const u8, tokens: *const u8, count: usize, masked: *const u8) -> i32 {
    done(unmask(input(pks, count * POINT), input(tokens, count * POINT), input(masked, MASKED)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_reveal_tokens(secret: *const u8, masked: *const u8, count: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(reveal_tokens(
        input(secret, SCALAR),
        input(masked, count * MASKED),
        input(seed, 32),
        output(out, tokens_len(count)),
    ))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_tokens(pk: *const u8, masked: *const u8, count: usize, tokens: *const u8) -> i32 {
    verify_tokens(input(pk, POINT), input(masked, count * MASKED), input(tokens, tokens_len(count))) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_seal(
    secret: *const u8,
    pk_to: *const u8,
    masked: *const u8,
    seed: *const u8,
    out: *mut u8,
) -> i32 {
    done(seal(
        input(secret, SCALAR),
        input(pk_to, POINT),
        input(masked, MASKED),
        input(seed, 32),
        output(out, SEALED + SEAL_PROOF),
    ))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_seal(pk_owner: *const u8, pk_to: *const u8, masked: *const u8, sealed: *const u8) -> i32 {
    i32::from(verify_seal(
        input(pk_owner, POINT),
        input(pk_to, POINT),
        input(masked, MASKED),
        input(sealed, SEALED + SEAL_PROOF),
    ))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_shared_secret(secret: *const u8, pk: *const u8, out: *mut u8) -> i32 {
    done(shared_secret(input(secret, SCALAR), input(pk, POINT), output(out, 32)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_open(secret: *const u8, sealed: *const u8, out: *mut u8) -> i32 {
    done(open(input(secret, SCALAR), input(sealed, SEALED), output(out, POINT)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed(i: u8) -> [u8; 32] {
        let mut s = [0u8; 32];
        s[0] = i;
        s[31] = 7;
        s
    }

    /// A seed shorter than 32 bytes is input of the wrong size: refused
    /// with None, as every other, and never a panic across the C or
    /// wasm boundary.
    #[test]
    fn a_short_seed_is_refused() {
        let secret = seed(1);
        let mut out = vec![0u8; 4096];
        for short in [&[][..], &[7u8; 16][..], &[7u8; 31][..]] {
            assert_eq!(key_proof(&secret, b"seat", short, &mut out), None, "{} bytes", short.len());
            assert_eq!(split(&secret, 3, short, &mut out), None, "{} bytes", short.len());
            assert_eq!(share_bytes(&[1, 2, 3], 3, 2, short, &mut out), None, "{} bytes", short.len());
        }
        assert_eq!(key_proof(&secret, b"seat", &seed(2), &mut out), Some(KEY_PROOF), "and 32 bytes is a seed");
    }

    #[test]
    fn a_whole_deal_round_trips_and_every_size_is_what_it_says() {
        let secrets: Vec<[u8; 32]> = (1..=4).map(seed).collect();
        let mut pks = vec![0u8; 4 * POINT];
        for (i, s) in secrets.iter().enumerate() {
            assert_eq!(keygen(s, &mut pks[i * POINT..(i + 1) * POINT]), Some(POINT));
            let mut proof = vec![0u8; KEY_PROOF];
            assert_eq!(key_proof(s, b"seat", &seed(9), &mut proof), Some(KEY_PROOF));
            assert!(verify_key(&pks[i * POINT..(i + 1) * POINT], b"seat", &proof));
            assert!(!verify_key(&pks[i * POINT..(i + 1) * POINT], b"other", &proof), "a proof is bound to its name");
        }
        let mut joint = vec![0u8; POINT];
        assert_eq!(aggregate(&pks, &mut joint), Some(POINT));
        let mut deck = vec![0u8; DECK_BYTES];
        assert_eq!(initial_deck(&joint, &mut deck), Some(DECK_BYTES));
        let mut deck2 = deck.clone();
        assert_eq!(initial_deck(&joint, &mut deck2), Some(DECK_BYTES));
        assert_eq!(deck, deck2, "the initial deck is the same for everyone");

        let mut proof_len = 0;
        for s in 0..4 {
            let mut next = vec![0u8; DECK_BYTES];
            let mut proof = vec![0u8; 16384];
            let n = shuffle(&joint, &deck, &seed(20 + s), &mut next, &mut proof).expect("shuffle");
            proof_len = n;
            assert!(verify_shuffle(&joint, &deck, &next, &proof[..n]));
            assert!(!verify_shuffle(&joint, &next, &deck, &proof[..n]), "not the other way round");
            deck = next;
        }
        eprintln!("shuffle proof: {proof_len} bytes");

        // Everyone opens every card: the deck is a permutation of 0..52.
        // A seat makes its tokens for the whole deck in one batch, with
        // one argument for the lot, which is how a hand does it.
        let mut batched = Vec::new();
        for (i, s) in secrets.iter().enumerate() {
            let mut out = vec![0u8; tokens_len(DECK)];
            assert_eq!(reveal_tokens(s, &deck, &seed(40 + i as u8), &mut out), Some(tokens_len(DECK)));
            assert!(verify_tokens(&pks[i * POINT..(i + 1) * POINT], &deck, &out), "the batch checks");
            batched.push(out);
        }
        let mut seen = [false; DECK];
        for c in 0..DECK {
            let masked = &deck[c * MASKED..(c + 1) * MASKED];
            let mut tokens = vec![0u8; 4 * POINT];
            for (i, s) in secrets.iter().enumerate() {
                // The single-token call and the batch agree, card for card.
                let mut one = vec![0u8; TOKEN];
                assert_eq!(reveal_token(s, masked, &seed(40 + i as u8), &mut one), Some(TOKEN));
                assert!(verify_token(&pks[i * POINT..(i + 1) * POINT], masked, &one));
                let from_batch = &batched[i][c * POINT..(c + 1) * POINT];
                assert_eq!(&one[..POINT], from_batch, "seat {i}, card {c}: one token, two ways");
                tokens[i * POINT..(i + 1) * POINT].copy_from_slice(from_batch);
            }
            let card = unmask(&pks, &tokens, masked).expect("a card");
            assert!(!seen[card], "card {card} dealt twice");
            seen[card] = true;
            // Without one token the card stays closed.
            assert_eq!(unmask(&pks[..3 * POINT], &tokens[..3 * POINT], masked), None);
        }
        assert!(seen.iter().all(|s| *s));

        // A batch with one token bent is refused, and the bend is the
        // only thing that changed.
        let mut bent = batched[0].clone();
        bent[7 * POINT] ^= 1;
        assert!(!verify_tokens(&pks[..POINT], &deck, &bent), "a bent token fails the batch");
        // As is a batch offered for a different deck, or by another key.
        assert!(!verify_tokens(&pks[POINT..2 * POINT], &deck, &batched[0]), "not that seat's batch");
        assert!(!verify_tokens(&pks[..POINT], &deck[..(DECK - 1) * MASKED], &batched[0]), "not those cards");

        // A token sealed to seat 1 is opened by seat 1 alone, and it is
        // the token seat 0 owes for that card.
        let masked = &deck[..MASKED];
        let mut token = vec![0u8; TOKEN];
        reveal_token(&secrets[0], masked, &seed(50), &mut token).unwrap();
        let mut sealed = vec![0u8; SEALED + SEAL_PROOF];
        assert_eq!(
            seal(&secrets[0], &pks[POINT..2 * POINT], masked, &seed(51), &mut sealed),
            Some(SEALED + SEAL_PROOF)
        );
        let mut opened = vec![0u8; POINT];
        assert_eq!(open(&secrets[1], &sealed, &mut opened), Some(POINT));
        assert_eq!(opened, token[..POINT], "what comes out is the reveal token itself");
        let mut wrong = vec![0u8; POINT];
        open(&secrets[2], &sealed, &mut wrong).unwrap();
        assert_ne!(wrong, token[..POINT]);

        // And anybody can check that it is, without opening it, so a
        // passer who seals the receiver something else is caught by
        // every third party.
        assert!(verify_seal(&pks[..POINT], &pks[POINT..2 * POINT], masked, &sealed));
        assert!(!verify_seal(&pks[2 * POINT..3 * POINT], &pks[POINT..2 * POINT], masked, &sealed), "not another seat's token");
        assert!(!verify_seal(&pks[..POINT], &pks[2 * POINT..3 * POINT], masked, &sealed), "not sealed to another seat");
        assert!(!verify_seal(&pks[..POINT], &pks[POINT..2 * POINT], &deck[MASKED..2 * MASKED], &sealed), "not another card");
        for i in [0usize, SEALED - 1, SEALED, SEALED + SEAL_PROOF - 1] {
            let mut bent = sealed.clone();
            bent[i] ^= 1;
            assert!(!verify_seal(&pks[..POINT], &pks[POINT..2 * POINT], masked, &bent), "a bent byte at {i}");
        }

        // The fault itself: a passer that keeps the argument and sends
        // a ciphertext of something else. The receiver gets a point
        // that is not the token, and now everyone can say so.
        let mut lie = sealed.clone();
        {
            let honest = read::<Masked>(&sealed[..SEALED]).unwrap();
            let elsewhere = read::<Masked>(&deck[MASKED..2 * MASKED]).unwrap();
            let c2 = (honest.1.into_group() + elsewhere.1.into_group()).into_affine();
            write(&el_gamal::Ciphertext::<Curve>(honest.0, c2), &mut lie[..SEALED]).unwrap();
        }
        let mut got = vec![0u8; POINT];
        open(&secrets[1], &lie, &mut got).unwrap();
        assert_ne!(got, token[..POINT], "the receiver would be left with nothing that opens");
        assert!(!verify_seal(&pks[..POINT], &pks[POINT..2 * POINT], masked, &lie), "and the table refuses it");

        // A shared secret is the same from either side and different
        // for a third.
        let (mut ab, mut ba, mut ac) = (vec![0u8; 32], vec![0u8; 32], vec![0u8; 32]);
        assert_eq!(shared_secret(&secrets[0], &pks[POINT..2 * POINT], &mut ab), Some(32));
        assert_eq!(shared_secret(&secrets[1], &pks[..POINT], &mut ba), Some(32));
        assert_eq!(shared_secret(&secrets[0], &pks[2 * POINT..3 * POINT], &mut ac), Some(32));
        assert_eq!(ab, ba);
        assert_ne!(ab, ac);
    }

    /// A token sealed to a seat opens from the shares of that seat's
    /// key too — which it has to, since a pass to a seat that then
    /// leaves is a ciphertext only that seat's key could open, and the
    /// key is nobody's.
    #[test]
    fn a_seal_opens_from_the_shares_of_the_key_it_was_sealed_to() {
        let secrets: Vec<[u8; 32]> = (1..=2).map(seed).collect();
        let mut pks = vec![0u8; 2 * POINT];
        for (i, s) in secrets.iter().enumerate() {
            keygen(s, &mut pks[i * POINT..(i + 1) * POINT]).unwrap();
        }
        let mut joint = vec![0u8; POINT];
        aggregate(&pks, &mut joint).unwrap();
        let mut deck = vec![0u8; DECK_BYTES];
        initial_deck(&joint, &mut deck).unwrap();
        let masked = &deck[3 * MASKED..4 * MASKED];

        // Seat 0 seals its token for that card to seat 1, then seat 1
        // leaves and its key is split.
        let mut sealed = vec![0u8; SEALED + SEAL_PROOF];
        seal(&secrets[0], &pks[POINT..], masked, &seed(30), &mut sealed).unwrap();
        let mut whole = vec![0u8; POINT];
        open(&secrets[1], &sealed, &mut whole).unwrap();

        let mut shares = vec![0u8; 2 * SCALAR];
        split(&secrets[1], 2, &seed(31), &mut shares).unwrap();
        let mut parts = vec![0u8; 2 * POINT];
        for i in 0..2 {
            let share = &shares[i * SCALAR..(i + 1) * SCALAR];
            let mut part = vec![0u8; TOKEN];
            // A seal is a ciphertext of a card's shape, so a share's
            // part of opening it is a token over the seal itself.
            assert_eq!(share_token(share, &sealed[..SEALED], &seed(32 + i as u8), &mut part), Some(TOKEN));
            let mut share_pk = vec![0u8; POINT];
            share_key(share, &mut share_pk).unwrap();
            assert!(verify_token(&share_pk, &sealed[..SEALED], &part), "the part proves against its share's key");
            parts[i * POINT..(i + 1) * POINT].copy_from_slice(&part[..POINT]);
        }
        let mut got = vec![0u8; POINT];
        assert_eq!(open_shared(&sealed[..SEALED], &parts, &mut got), Some(POINT));
        assert_eq!(got, whole, "the same token the key itself would have opened");
        assert_ne!(
            open_shared(&sealed[..SEALED], &parts[..POINT], &mut got.clone()).map(|_| got.clone()),
            None,
            "one part alone gives something"
        );
    }

    /// And into more than two, for a table with no jury to escrow to,
    /// where every other person holds a share and all of them are
    /// needed: the shares' keys still add to the seat's, and every
    /// share's token is needed to open a card.
    #[test]
    fn a_key_splits_into_as_many_shares_as_a_table_needs() {
        let secret = seed(3);
        let mut pk = vec![0u8; POINT];
        keygen(&secret, &mut pk).unwrap();
        for shares in 2..=4usize {
            let mut out = vec![0u8; shares * SCALAR];
            assert_eq!(split(&secret, shares, &seed(80 + shares as u8), &mut out), Some(shares * SCALAR));
            let mut pks = vec![0u8; shares * POINT];
            for i in 0..shares {
                share_key(&out[i * SCALAR..(i + 1) * SCALAR], &mut pks[i * POINT..(i + 1) * POINT]).unwrap();
            }
            let mut sum = vec![0u8; POINT];
            aggregate(&pks, &mut sum).unwrap();
            assert_eq!(sum, pk, "{shares} shares add to the key");
            // And no smaller set does.
            let mut short = vec![0u8; POINT];
            aggregate(&pks[..(shares - 1) * POINT], &mut short).unwrap();
            assert_ne!(short, pk, "{} of {shares} is not the key", shares - 1);
        }
        assert_eq!(split(&secret, 1, &seed(90), &mut [0u8; SCALAR]), None, "a split is into two or more");
    }

    /// A departed seat's card, opened by the holders of its key's two
    /// shares — without either of them, or anybody, ever holding the
    /// key.
    #[test]
    fn a_split_key_opens_a_card_without_being_put_back_together() {
        let secrets: Vec<[u8; 32]> = (1..=4).map(seed).collect();
        let mut pks = vec![0u8; 4 * POINT];
        for (i, s) in secrets.iter().enumerate() {
            keygen(s, &mut pks[i * POINT..(i + 1) * POINT]).unwrap();
        }
        let mut joint = vec![0u8; POINT];
        aggregate(&pks, &mut joint).unwrap();
        let mut deck = vec![0u8; DECK_BYTES];
        initial_deck(&joint, &mut deck).unwrap();
        let masked = &deck[7 * MASKED..8 * MASKED];

        // Seat 0 is gone, and its key was split in two at the deal.
        let mut shares = vec![0u8; 2 * SCALAR];
        assert_eq!(split(&secrets[0], 2, &seed(60), &mut shares), Some(2 * SCALAR));
        let (a, b) = (&shares[..SCALAR], &shares[SCALAR..]);
        assert_ne!(a, b);
        let mut share_pks = vec![0u8; 2 * POINT];
        assert_eq!(share_key(a, &mut share_pks[..POINT]), Some(POINT));
        assert_eq!(share_key(b, &mut share_pks[POINT..]), Some(POINT));
        let mut rebuilt = vec![0u8; POINT];
        aggregate(&share_pks, &mut rebuilt).unwrap();
        assert_eq!(rebuilt, pks[..POINT], "the shares' keys add to the seat's key");

        // Five tokens where there were four: the two shares, and the
        // three seats still here.
        let mut all_pks = share_pks.clone();
        all_pks.extend_from_slice(&pks[POINT..]);
        let mut tokens = vec![0u8; 5 * TOKEN];
        assert_eq!(share_token(a, masked, &seed(61), &mut tokens[..TOKEN]), Some(TOKEN));
        assert_eq!(share_token(b, masked, &seed(62), &mut tokens[TOKEN..2 * TOKEN]), Some(TOKEN));
        for (i, secret) in secrets.iter().enumerate().take(4).skip(1) {
            let at = (i + 1) * TOKEN;
            reveal_token(secret, masked, &seed(63 + i as u8), &mut tokens[at..at + TOKEN]).unwrap();
        }
        // A share's token is proved against that share's key, and
        // against nothing else — so a share-holder cannot pass off
        // somebody else's part as its own.
        assert!(verify_token(&share_pks[..POINT], masked, &tokens[..TOKEN]));
        assert!(!verify_token(&pks[..POINT], masked, &tokens[..TOKEN]), "not against the seat's whole key");
        assert!(!verify_token(&share_pks[POINT..], masked, &tokens[..TOKEN]), "nor the other share's");

        // Opening takes the tokens alone: a proof is checked when the
        // token arrives, as just above, and what is kept is the token.
        let bare = |t: &[u8]| -> Vec<u8> {
            let mut out = Vec::new();
            for i in 0..t.len() / TOKEN {
                out.extend_from_slice(&t[i * TOKEN..i * TOKEN + POINT]);
            }
            out
        };
        let card = unmask(&all_pks, &bare(&tokens), masked).expect("a card");
        assert_eq!(card, 7, "the initial deck is masked by one, so this is card seven");

        // And it is the card the whole key would have opened.
        let mut whole = vec![0u8; 4 * TOKEN];
        for (i, s) in secrets.iter().enumerate() {
            reveal_token(s, masked, &seed(70 + i as u8), &mut whole[i * TOKEN..(i + 1) * TOKEN]).unwrap();
        }
        assert_eq!(unmask(&pks, &bare(&whole), masked), Some(card), "the same card, by a key nobody held");

        // One share is not the key: without the other, no card.
        let mut short = tokens[..TOKEN].to_vec();
        short.extend_from_slice(&tokens[2 * TOKEN..]);
        let mut short_pks = share_pks[..POINT].to_vec();
        short_pks.extend_from_slice(&pks[POINT..]);
        assert_eq!(unmask(&short_pks, &bare(&short), masked), None, "one share opens nothing");
    }
}

#[cfg(test)]
mod seal_tests {
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

#[cfg(test)]
mod transcript_tests {
    use super::*;

    /// The reference crate hashes a projective point's Jacobian
    /// coordinates into its transcripts, which a serialisation round
    /// trip does not preserve; the vendored copy normalises them.
    #[test]
    fn a_key_proof_survives_its_bytes() {
        let f = fixed();
        let secret = [3u8; 32];
        let (pk, sk) = keys(&secret).unwrap();
        let name = to_bytes![b"seat".as_slice()].unwrap();
        let mut rng = rng_from(&[9u8; 32]).unwrap();
        let proof = Protocol::prove_key_ownership(&mut rng, &f.pp, &pk, &sk, &name).unwrap();
        assert!(Protocol::verify_key_ownership(&f.pp, &pk, &name, &proof).is_ok(), "in memory");
        let mut pk_bytes = vec![0u8; POINT];
        write(&pk, &mut pk_bytes).unwrap();
        let pk2: Affine = read(&pk_bytes).unwrap();
        assert_eq!(pk, pk2, "pk survives bytes");
        let mut proof_bytes = vec![0u8; 256];
        let n = write(&proof, &mut proof_bytes).unwrap();
        eprintln!("key proof size {n}");
        let proof2: KeyProof = read(&proof_bytes[..n]).unwrap();
        assert!(Protocol::verify_key_ownership(&f.pp, &pk2, &name, &proof2).is_ok(), "through bytes");
    }
}

#[cfg(test)]
mod wire {
    use super::*;
    use std::time::Instant;

    fn seed(i: u8) -> [u8; 32] {
        let mut s = [0u8; 32];
        s[0] = i;
        s[31] = 7;
        s
    }

    /// The field bytes live in, on its own: that gf_mul and gf_inv are
    /// the field they claim to be, before anything is built on them.
    #[test]
    fn a_byte_is_a_field() {
        assert_eq!(gf_inv(0), None, "zero has no inverse");
        for a in 1..=255u8 {
            assert_eq!(gf_mul(a, gf_inv(a).unwrap()), 1, "{a} times its inverse is one");
            assert_eq!(gf_mul(a, 1), a);
            assert_eq!(gf_mul(a, 0), 0);
            for b in 1..=255u8 {
                assert_eq!(gf_mul(a, b), gf_mul(b, a));
                // Distributive over xor, which is what addition is here.
                assert_eq!(gf_mul(a, b ^ 7), gf_mul(a, b) ^ gf_mul(a, 7));
            }
        }
    }

    /// A seat's secret in shares: any t rebuild it, t-1 say nothing,
    /// and a juror arriving later is given one of its own.
    #[test]
    fn any_t_of_n_shares_rebuild_a_secret_and_a_newcomer_is_given_one() {
        let secret = seed(11);
        const N: usize = 6;
        const T: usize = 2;
        let len = secret.len();
        let mut shares = vec![0u8; N * len];
        assert_eq!(share_bytes(&secret, N, T, &seed(12), &mut shares), Some(N * len));
        let share = |s: &[u8], i: u8| s[(i as usize - 1) * len..i as usize * len].to_vec();

        // Nothing in a share is the secret, and no two are the same.
        for i in 1..=N as u8 {
            assert_ne!(share(&shares, i), secret.to_vec(), "share {i} is not the secret");
            for j in i + 1..=N as u8 {
                assert_ne!(share(&shares, i), share(&shares, j));
            }
        }

        // Whoever answers, scaled by what their share is worth among
        // them, and summed.
        let rebuild = |have: &[u8], shares: &[u8], at: u8| -> Vec<u8> {
            let mut parts = vec![0u8; have.len() * len];
            for (n, &i) in have.iter().enumerate() {
                let c = bytes_lagrange(have, i, at).unwrap();
                bytes_scale(&share(shares, i), c, &mut parts[n * len..(n + 1) * len]).unwrap();
            }
            let mut out = vec![0u8; len];
            bytes_sum(&parts, len, &mut out).unwrap();
            out
        };

        for pair in [[1u8, 2], [2, 5], [3, 6], [1, 6]] {
            assert_eq!(rebuild(&pair, &shares, 0), secret.to_vec(), "shares {pair:?} rebuild it");
        }
        assert_eq!(rebuild(&[1, 3, 5], &shares, 0), secret.to_vec(), "more than two is the same secret");
        assert_eq!(rebuild(&[4], &shares, 0), share(&shares, 4), "one share alone is only itself");
        assert_ne!(rebuild(&[4], &shares, 0), secret.to_vec(), "and it is not the secret");

        // Share seven, made by two holders out of their own: each
        // sends what its share is worth towards seven, and the
        // newcomer sums them. Neither ever holds the secret.
        let have: [u8; 2] = [2, 5];
        let seventh = rebuild(&have, &shares, 7);
        let mut wider = shares.clone();
        wider.extend_from_slice(&seventh);
        for pair in [[7u8, 1], [7, 4], [3, 7]] {
            assert_eq!(rebuild(&pair, &wider, 0), secret.to_vec(), "the newcomer's share answers beside {pair:?}");
        }

        // At a threshold of three, two say nothing and three answer.
        let mut three = vec![0u8; N * len];
        share_bytes(&secret, N, 3, &seed(13), &mut three).unwrap();
        assert_ne!(rebuild(&[1, 2], &three, 0), secret.to_vec(), "two of a threshold of three is not enough");
        assert_eq!(rebuild(&[1, 2, 4], &three, 0), secret.to_vec());

        // And the guards.
        let mut out = vec![0u8; len];
        assert_eq!(share_bytes(&secret, 3, 1, &seed(14), &mut out), None, "a threshold of one is no threshold");
        assert_eq!(share_bytes(&secret, 2, 3, &seed(14), &mut shares), None, "nor more than there are shares");
        assert_eq!(share_bytes(&[], 3, 2, &seed(14), &mut shares), None);
        assert_eq!(bytes_lagrange(&[1, 2], 3, 0), None, "an index outside the set");
        assert_eq!(bytes_lagrange(&[1, 1], 1, 0), None, "a repeat");
        assert_eq!(bytes_lagrange(&[0, 1], 1, 0), None, "zero is the secret, not a share");
        assert_eq!(bytes_sum(&[0u8; 5], 2, &mut out), None, "parts that are not whole shares");
    }

    /// Any t of n open a card, t-1 do not, and a juror who arrives
    /// later is given a share of its own without the key ever being
    /// put back together.
    #[test]
    fn a_threshold_of_shares_opens_a_card_and_a_newcomer_is_given_one() {
        let secrets: Vec<[u8; 32]> = (1..=4).map(seed).collect();
        let mut pks = vec![0u8; 4 * POINT];
        for (i, s) in secrets.iter().enumerate() {
            keygen(s, &mut pks[i * POINT..(i + 1) * POINT]).unwrap();
        }
        let mut joint = vec![0u8; POINT];
        aggregate(&pks, &mut joint).unwrap();
        let mut deck = vec![0u8; DECK_BYTES];
        initial_deck(&joint, &mut deck).unwrap();
        let masked = &deck[7 * MASKED..8 * MASKED];

        // Seat 0's key in six shares, any two of which answer.
        const N: usize = 6;
        const T: usize = 2;
        let mut shares = vec![0u8; N * SCALAR];
        assert_eq!(split_threshold(&secrets[0], N, T, &seed(80), &mut shares), Some(N * SCALAR));
        let share = |i: usize| &shares[(i - 1) * SCALAR..i * SCALAR];
        let mut share_keys = vec![0u8; N * POINT];
        for i in 1..=N {
            share_key(share(i), &mut share_keys[(i - 1) * POINT..i * POINT]).unwrap();
        }

        // The card, opened by the jurors at `have` plus the three
        // seats still here — with every scaled token checked by
        // anybody, against a key anybody can work out.
        let open = |have: &[u8], shares: &[u8], share_keys: &[u8]| -> Option<usize> {
            let mut tokens = Vec::new();
            let mut keys = Vec::new();
            for &i in have {
                let mut coefficient = vec![0u8; SCALAR];
                lagrange(have, i, 0, &mut coefficient).unwrap();
                // What the holder sends: its share, times what that
                // share is worth in this set.
                let mut scaled = vec![0u8; SCALAR];
                scalar_mul(&shares[(i as usize - 1) * SCALAR..i as usize * SCALAR], &coefficient, &mut scaled).unwrap();
                let mut token = vec![0u8; TOKEN];
                share_token(&scaled, masked, &seed(90 + i), &mut token).unwrap();
                // What anybody checks it against: the share's own
                // published key, scaled by the same public coefficient.
                let mut against = vec![0u8; POINT];
                point_scale(&share_keys[(i as usize - 1) * POINT..i as usize * POINT], &coefficient, &mut against).unwrap();
                assert!(verify_token(&against, masked, &token), "juror {i}'s scaled token checks");
                assert!(!verify_token(&share_keys[..POINT], masked, &token) || i == 1, "and against nothing else");
                tokens.extend_from_slice(&token[..POINT]);
                keys.extend_from_slice(&against);
            }
            tokens.reserve(3 * POINT);
            for (i, s) in secrets.iter().enumerate().skip(1) {
                let mut whole = vec![0u8; TOKEN];
                reveal_token(s, masked, &seed(70 + i as u8), &mut whole).unwrap();
                tokens.extend_from_slice(&whole[..POINT]);
                keys.extend_from_slice(&pks[i * POINT..(i + 1) * POINT]);
            }
            unmask(&keys, &tokens, masked)
        };

        // The card the whole key would have opened.
        let mut whole = vec![0u8; 4 * POINT];
        for (i, s) in secrets.iter().enumerate() {
            let mut t = vec![0u8; TOKEN];
            reveal_token(s, masked, &seed(60 + i as u8), &mut t).unwrap();
            whole[i * POINT..(i + 1) * POINT].copy_from_slice(&t[..POINT]);
        }
        let card = unmask(&pks, &whole, masked).expect("a card");

        // Any two of the six, whichever two.
        for pair in [[1u8, 2], [2, 5], [3, 6], [1, 6]] {
            assert_eq!(open(&pair, &shares, &share_keys), Some(card), "shares {pair:?} open it");
        }
        // And more than two is the same card, not a different one.
        assert_eq!(open(&[1, 3, 5], &shares, &share_keys), Some(card));
        // One is nothing: its part alone is not the seat's token.
        assert_ne!(open(&[4], &shares, &share_keys), Some(card), "one share opens nothing");

        // A juror arriving later is given share seven, made by two
        // holders out of their own and sent sealed. Neither of them
        // ever holds the key, and what each sends is worth nothing by
        // itself.
        let have: [u8; 2] = [2, 5];
        let mut parts = vec![0u8; have.len() * SCALAR];
        for (n, &i) in have.iter().enumerate() {
            let mut coefficient = vec![0u8; SCALAR];
            lagrange(&have, i, 7, &mut coefficient).unwrap();
            scalar_mul(
                &shares[(i as usize - 1) * SCALAR..i as usize * SCALAR],
                &coefficient,
                &mut parts[n * SCALAR..(n + 1) * SCALAR],
            )
            .unwrap();
        }
        let mut seventh = vec![0u8; SCALAR];
        assert_eq!(scalar_sum(&parts, &mut seventh), Some(SCALAR));

        // It is a share like any other: it opens the card beside one
        // of the originals, and its key is the one anybody checks it
        // against.
        let mut wider = shares.clone();
        wider.extend_from_slice(&seventh);
        let mut wider_keys = share_keys.clone();
        wider_keys.resize((N + 1) * POINT, 0);
        share_key(&seventh, &mut wider_keys[N * POINT..]).unwrap();
        for pair in [[7u8, 1], [7, 4], [3, 7]] {
            assert_eq!(open(&pair, &wider, &wider_keys), Some(card), "the newcomer's share {pair:?} answers");
        }

        // A coefficient is for the set it was made for: used in
        // another set it is the wrong weight and opens nothing.
        let mut wrong = vec![0u8; SCALAR];
        lagrange(&[1, 2], 1, 0, &mut wrong).unwrap();
        let mut right = vec![0u8; SCALAR];
        lagrange(&[1, 3], 1, 0, &mut right).unwrap();
        assert_ne!(wrong, right, "the weight depends on who else is answering");

        // And the guards: an index outside the set, a repeat, a zero.
        let mut out = vec![0u8; SCALAR];
        assert_eq!(lagrange(&[1, 2], 3, 0, &mut out), None);
        assert_eq!(lagrange(&[1, 1], 1, 0, &mut out), None);
        assert_eq!(lagrange(&[0, 1], 0, 0, &mut out), None);
        assert_eq!(split_threshold(&secrets[0], 3, 1, &seed(81), &mut shares), None, "a threshold of one is no threshold");
        assert_eq!(split_threshold(&secrets[0], 2, 3, &seed(81), &mut shares), None, "nor more than there are shares");
    }

    /// What the deck's m x n factorisation costs on the wire: the
    /// argument's bytes, and the time to make and check one. Run with
    /// --nocapture, changing M and N above.
    #[test]
    fn shuffle_argument_size() {
        let secrets: Vec<[u8; 32]> = (1..=4).map(seed).collect();
        let mut pks = vec![0u8; 4 * POINT];
        for (i, s) in secrets.iter().enumerate() {
            keygen(s, &mut pks[i * POINT..(i + 1) * POINT]).unwrap();
        }
        let mut joint = vec![0u8; POINT];
        aggregate(&pks, &mut joint).unwrap();
        let mut deck = vec![0u8; DECK_BYTES];
        initial_deck(&joint, &mut deck).unwrap();
        let mut next = vec![0u8; DECK_BYTES];
        let mut proof = vec![0u8; 262144];
        let t0 = Instant::now();
        let n = shuffle(&joint, &deck, &seed(3), &mut next, &mut proof).expect("shuffle");
        let made = t0.elapsed();
        let t1 = Instant::now();
        assert!(verify_shuffle(&joint, &deck, &next, &proof[..n]));
        let checked = t1.elapsed();
        println!(
            "m={} n={}: argument {} bytes ({} x 32), deck {} bytes; make {:?}, check {:?}",
            M, N, n, n / 32, DECK_BYTES, made, checked
        );
    }
}
