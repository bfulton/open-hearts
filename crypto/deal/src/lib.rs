//! The verifiable deal (docs/03-fair-deal.md): Barnett–Smart mental
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

use ark_ec::{AffineCurve, ProjectiveCurve};
use ark_ff::{to_bytes, PrimeField, UniformRand};
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::{One, Zero};
use barnett_smart_card_protocol::discrete_log_cards::{self, DLCards, Parameters};
use barnett_smart_card_protocol::BarnettSmartProtocol;
use proof_essentials::homomorphic_encryption::el_gamal::Plaintext;
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
pub const DECK_BYTES: usize = DECK * MASKED;

/// The Bayer–Groth argument sees the deck as an m × n matrix.
const M: usize = 2;
const N: usize = 26;

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

fn rng_from(seed: &[u8]) -> ChaCha20Rng {
    let mut s = [0u8; 32];
    s.copy_from_slice(&seed[..32]);
    ChaCha20Rng::from_seed(s)
}

/// A seat's keys from its 32-byte secret: the reference crate's own
/// key generation, driven by a generator seeded with the secret, so
/// the same secret always gives the same pair and nothing here needs
/// the parameters' private generator.
fn keys(secret: &[u8]) -> Option<(Affine, Scalar)> {
    if secret.len() < 32 {
        return None;
    }
    Protocol::player_keygen(&mut rng_from(secret), &fixed().pp).ok()
}

fn write<T: CanonicalSerialize>(v: &T, out: &mut [u8]) -> Option<usize> {
    let n = v.serialized_size();
    if out.len() < n {
        return None;
    }
    v.serialize(&mut out[..n]).ok()?;
    Some(n)
}

fn read<T: CanonicalDeserialize>(bytes: &[u8]) -> Option<T> {
    T::deserialize(bytes).ok()
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
    let mut rng = rng_from(seed);
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
        acc += pk.into_projective();
    }
    write(&acc.into_affine(), out)
}

/// The deck before anyone shuffles: every card masked under the joint
/// key with the masking factor one, which everyone can recompute.
pub fn initial_deck(joint: &[u8], out: &mut [u8]) -> Option<usize> {
    let f = fixed();
    let joint = read::<Affine>(joint)?;
    let mut rng = rng_from(&[0u8; 32]);
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
    let mut rng = rng_from(seed);
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
    let mut rng = rng_from(seed);
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

/// Opens a masked card with every seat's token (each checked against
/// its key): the card's index, 0 to 51, or none if a token is bad or
/// the result is no card.
pub fn unmask(pks: &[u8], tokens: &[u8], masked: &[u8]) -> Option<usize> {
    let f = fixed();
    let masked = read::<Masked>(masked)?;
    let n = pks.len() / POINT;
    if tokens.len() < n * TOKEN {
        return None;
    }
    let mut key = Vec::with_capacity(n);
    for i in 0..n {
        let pk = read::<Affine>(&pks[i * POINT..(i + 1) * POINT])?;
        let t = &tokens[i * TOKEN..(i + 1) * TOKEN];
        let token = read::<Token>(&t[..POINT])?;
        let proof = read::<RevealProof>(&t[POINT..])?;
        key.push((token, proof, pk));
    }
    let card = Protocol::unmask(&f.pp, &key, &masked).ok()?;
    f.cards.iter().position(|c| *c == card)
}

/// A token for another seat's eyes only — a passed card — ElGamal
/// encrypted to that seat's key: the protocol's own masking, under
/// that key alone, with randomness from [seed].
pub fn seal(pk: &[u8], token: &[u8], seed: &[u8], out: &mut [u8]) -> Option<usize> {
    let f = fixed();
    let pk = read::<Affine>(pk)?;
    let token = read::<Token>(&token[..POINT])?;
    let mut rng = rng_from(seed);
    let r = Scalar::rand(&mut rng);
    let (sealed, _) = Protocol::mask(&mut rng, &f.pp, &pk, &Plaintext::<Curve>(token.0), &r).ok()?;
    write(&sealed, out)
}

/// A secret two seats share and nobody else can compute: the hash of
/// the point [pk] times this seat's key. Both sides get the same 32
/// bytes; what a seat keeps for another — a share of its deal secret,
/// held against its leaving — is encrypted with it (packages/deal).
pub fn shared_secret(secret: &[u8], pk: &[u8], out: &mut [u8]) -> Option<usize> {
    use blake2::{Blake2s, Digest};
    let (_, sk) = keys(secret)?;
    let pk = read::<Affine>(pk)?;
    let point = pk.mul(sk.into_repr()).into_affine();
    let mut bytes = Vec::with_capacity(POINT);
    point.serialize(&mut bytes).ok()?;
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
    let s = c.0.mul(sk.into_repr()).into_affine();
    let m = c.1 + (-s);
    write(&Plaintext::<Curve>(m), out)
}

// ---- the flat interface -----------------------------------------------------
//
// Every function takes pointers and lengths into memory the caller
// owns (from `deal_alloc`), returns the bytes written or -1, and never
// keeps a reference. The same symbols serve wasm and the VM's FFI.

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

#[no_mangle]
pub unsafe extern "C" fn deal_keygen(secret: *const u8, out: *mut u8) -> i32 {
    done(keygen(input(secret, SCALAR), output(out, POINT)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_key_proof(secret: *const u8, name: *const u8, name_len: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(key_proof(input(secret, SCALAR), input(name, name_len), input(seed, 32), output(out, KEY_PROOF)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_verify_key(pk: *const u8, name: *const u8, name_len: usize, proof: *const u8) -> i32 {
    verify_key(input(pk, POINT), input(name, name_len), input(proof, KEY_PROOF)) as i32
}

#[no_mangle]
pub unsafe extern "C" fn deal_aggregate(pks: *const u8, count: usize, out: *mut u8) -> i32 {
    done(aggregate(input(pks, count * POINT), output(out, POINT)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_initial_deck(joint: *const u8, out: *mut u8) -> i32 {
    done(initial_deck(input(joint, POINT), output(out, DECK_BYTES)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_shuffle(joint: *const u8, deck_in: *const u8, seed: *const u8, deck_out: *mut u8, proof_out: *mut u8, proof_cap: usize) -> i32 {
    done(shuffle(input(joint, POINT), input(deck_in, DECK_BYTES), input(seed, 32), output(deck_out, DECK_BYTES), output(proof_out, proof_cap)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_verify_shuffle(joint: *const u8, deck_in: *const u8, deck_out: *const u8, proof: *const u8, proof_len: usize) -> i32 {
    verify_shuffle(input(joint, POINT), input(deck_in, DECK_BYTES), input(deck_out, DECK_BYTES), input(proof, proof_len)) as i32
}

#[no_mangle]
pub unsafe extern "C" fn deal_reveal_token(secret: *const u8, masked: *const u8, seed: *const u8, out: *mut u8) -> i32 {
    done(reveal_token(input(secret, SCALAR), input(masked, MASKED), input(seed, 32), output(out, TOKEN)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_verify_token(pk: *const u8, masked: *const u8, token: *const u8) -> i32 {
    verify_token(input(pk, POINT), input(masked, MASKED), input(token, TOKEN)) as i32
}

#[no_mangle]
pub unsafe extern "C" fn deal_unmask(pks: *const u8, tokens: *const u8, count: usize, masked: *const u8) -> i32 {
    done(unmask(input(pks, count * POINT), input(tokens, count * TOKEN), input(masked, MASKED)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_seal(pk: *const u8, token: *const u8, seed: *const u8, out: *mut u8) -> i32 {
    done(seal(input(pk, POINT), input(token, POINT), input(seed, 32), output(out, SEALED)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_shared_secret(secret: *const u8, pk: *const u8, out: *mut u8) -> i32 {
    done(shared_secret(input(secret, SCALAR), input(pk, POINT), output(out, 32)))
}

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
        let mut seen = vec![false; DECK];
        for c in 0..DECK {
            let masked = &deck[c * MASKED..(c + 1) * MASKED];
            let mut tokens = vec![0u8; 4 * TOKEN];
            for (i, s) in secrets.iter().enumerate() {
                assert_eq!(reveal_token(s, masked, &seed(40 + i as u8), &mut tokens[i * TOKEN..(i + 1) * TOKEN]), Some(TOKEN));
                assert!(verify_token(&pks[i * POINT..(i + 1) * POINT], masked, &tokens[i * TOKEN..(i + 1) * TOKEN]));
            }
            let card = unmask(&pks, &tokens, masked).expect("a card");
            assert!(!seen[card], "card {card} dealt twice");
            seen[card] = true;
            // Without one token the card stays closed.
            assert_eq!(unmask(&pks[..3 * POINT], &tokens[..3 * TOKEN], masked), None);
        }
        assert!(seen.iter().all(|s| *s));

        // A token sealed to seat 1 is opened by seat 1 alone.
        let masked = &deck[..MASKED];
        let mut token = vec![0u8; TOKEN];
        reveal_token(&secrets[0], masked, &seed(50), &mut token).unwrap();
        let mut sealed = vec![0u8; SEALED];
        assert_eq!(seal(&pks[POINT..2 * POINT], &token, &seed(51), &mut sealed), Some(SEALED));
        let mut opened = vec![0u8; POINT];
        assert_eq!(open(&secrets[1], &sealed, &mut opened), Some(POINT));
        assert_eq!(opened, token[..POINT]);
        let mut wrong = vec![0u8; POINT];
        open(&secrets[2], &sealed, &mut wrong).unwrap();
        assert_ne!(wrong, token[..POINT]);

        // A shared secret is the same from either side and different
        // for a third.
        let (mut ab, mut ba, mut ac) = (vec![0u8; 32], vec![0u8; 32], vec![0u8; 32]);
        assert_eq!(shared_secret(&secrets[0], &pks[POINT..2 * POINT], &mut ab), Some(32));
        assert_eq!(shared_secret(&secrets[1], &pks[..POINT], &mut ba), Some(32));
        assert_eq!(shared_secret(&secrets[0], &pks[2 * POINT..3 * POINT], &mut ac), Some(32));
        assert_eq!(ab, ba);
        assert_ne!(ab, ac);
    }
}

#[cfg(test)]
mod transcript_tests {
    use super::*;

    /// The reference crate hashed a projective point's Jacobian
    /// coordinates into its transcripts, which a serialisation round
    /// trip does not preserve; the vendored copy normalises. This is
    /// the regression test for that.
    #[test]
    fn a_key_proof_survives_its_bytes() {
        let f = fixed();
        let secret = [3u8; 32];
        let (pk, sk) = keys(&secret).unwrap();
        let name = to_bytes![b"seat".as_slice()].unwrap();
        let mut rng = rng_from(&[9u8; 32]);
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
