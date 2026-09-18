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
use ark_ff::{to_bytes, Field, PrimeField, UniformRand};
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::{One, Zero};
use barnett_smart_card_protocol::discrete_log_cards::{self, DLCards, Parameters};
use barnett_smart_card_protocol::{BarnettSmartProtocol, Reveal};
use proof_essentials::homomorphic_encryption::el_gamal::{self, Plaintext};
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

/// The ElGamal generator the parameters were set up with. The
/// protocol's own parameters keep it private and offer no way to ask
/// for it, but a public key is sk·G, so one throwaway pair gives it
/// back exactly: G = sk⁻¹·pk. Drawn once, and checked in the tests
/// against a second pair.
fn generator() -> Affine {
    static G: OnceLock<Affine> = OnceLock::new();
    *G.get_or_init(|| {
        let (pk, sk) = keys(b"open-hearts generator probe v1  ").expect("probe keys");
        pk.mul(sk.inverse().expect("a key's secret is not zero").into_repr()).into_affine()
    })
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
/// A seat's key split in two, so that its cards can be opened without
/// anyone putting the key back together (docs/04-live-play.md,
/// "Playing a seat nobody holds"). The shares add to the key behind
/// [secret]: neither alone is anything, and [share_key] of the two
/// aggregates to the seat's own public key, which is what says a
/// split is a split of *that* key.
///
/// The escrow doc 03 describes splits the secret's bytes, which is
/// enough to rebuild it and no use for anything else. This splits the
/// key itself, in the field it lives in, and that is the difference
/// between a departed seat's hand being opened to whoever rebuilds it
/// and being opened to nobody.
pub fn split(secret: &[u8], shares: usize, seed: &[u8], out: &mut [u8]) -> Option<usize> {
    if shares < 2 || out.len() < shares * SCALAR {
        return None;
    }
    let (_, sk) = keys(secret)?;
    let mut rng = rng_from(seed);
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

/// One share's public key: what that share's token is checked
/// against, and one of the keys the seat's own is the sum of.
pub fn share_key(share: &[u8], out: &mut [u8]) -> Option<usize> {
    let s = read::<Scalar>(share)?;
    write(&generator().mul(s.into_repr()).into_affine(), out)
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
    let pk = generator().mul(sk.into_repr()).into_affine();
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

/// The card behind [masked] given every seat's token. With [check],
/// each token's proof is verified against its key first; without, the
/// tokens are combined as given — for a caller that verified each on
/// arrival, since a proof checked twice is most of the cost of a card.
pub fn unmask(pks: &[u8], tokens: &[u8], masked: &[u8], check: bool) -> Option<usize> {
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
    let card = if check {
        Protocol::unmask(&f.pp, &key, &masked).ok()?
    } else {
        let mut aggregate = Token::zero();
        for (token, _, _) in &key {
            aggregate = aggregate + *token;
        }
        aggregate.reveal(&masked).ok()?
    };
    f.cards.iter().position(|c| *c == card)
}

/// A token for another seat's eyes only — a passed card — ElGamal
/// encrypted to that seat's key, with the argument that it is the right
/// token. Writes [SEALED] bytes of ciphertext and then [SEAL_PROOF] of
/// argument.
///
/// Sealing hides the token from everyone but the seat it is for, which
/// is the point, and which used to mean that nobody else could tell an
/// honest seal from a bad one: a passer could send three cards the
/// receiver would never open, and no third party could say whose fault
/// it was (docs/03-fair-deal.md). The argument says, to anybody, that
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
    let mut rng = rng_from(seed);
    let r = Scalar::rand(&mut rng);

    let token = m.0.mul(sk.into_repr());
    let c1 = g.mul(r.into_repr());
    let c2 = token + to.mul(r.into_repr());
    let sealed: Masked = el_gamal::Ciphertext(c1.into_affine(), c2.into_affine());

    let a = Scalar::rand(&mut rng);
    let b = Scalar::rand(&mut rng);
    let a1 = g.mul(a.into_repr()).into_affine();
    let a2 = g.mul(b.into_repr()).into_affine();
    let a3 = (m.0.mul(a.into_repr()) + to.mul(b.into_repr())).into_affine();
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
    g.mul(z1.into_repr()) == a1.into_projective() + pk.mul(c.into_repr())
        && g.mul(z2.into_repr()) == a2.into_projective() + s.0.mul(c.into_repr())
        && m.0.mul(z1.into_repr()) + to.mul(z2.into_repr())
            == a3.into_projective() + s.1.mul(c.into_repr())
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
    use blake2::{Blake2b, Digest};
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
        sum += read::<Affine>(chunk)?.into_projective();
    }
    let m = c.1 + (-sum.into_affine());
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
pub unsafe extern "C" fn deal_split(secret: *const u8, shares: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(split(input(secret, SCALAR), shares, input(seed, 32), output(out, shares * SCALAR)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_share_key(share: *const u8, out: *mut u8) -> i32 {
    done(share_key(input(share, SCALAR), output(out, POINT)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_share_token(share: *const u8, masked: *const u8, seed: *const u8, out: *mut u8) -> i32 {
    done(share_token(input(share, SCALAR), input(masked, MASKED), input(seed, 32), output(out, TOKEN)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_open_shared(sealed: *const u8, parts: *const u8, count: usize, out: *mut u8) -> i32 {
    done(open_shared(input(sealed, SEALED), input(parts, count * POINT), output(out, POINT)))
}

#[no_mangle]
pub unsafe extern "C" fn deal_verify_token(pk: *const u8, masked: *const u8, token: *const u8) -> i32 {
    verify_token(input(pk, POINT), input(masked, MASKED), input(token, TOKEN)) as i32
}

#[no_mangle]
pub unsafe extern "C" fn deal_unmask(pks: *const u8, tokens: *const u8, count: usize, masked: *const u8, check: u8) -> i32 {
    done(unmask(input(pks, count * POINT), input(tokens, count * TOKEN), input(masked, MASKED), check != 0))
}

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

#[no_mangle]
pub unsafe extern "C" fn deal_verify_seal(pk_owner: *const u8, pk_to: *const u8, masked: *const u8, sealed: *const u8) -> i32 {
    i32::from(verify_seal(
        input(pk_owner, POINT),
        input(pk_to, POINT),
        input(masked, MASKED),
        input(sealed, SEALED + SEAL_PROOF),
    ))
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
            let card = unmask(&pks, &tokens, masked, true).expect("a card");
            assert_eq!(unmask(&pks, &tokens, masked, false), Some(card), "unchecked, the same card");
            assert!(!seen[card], "card {card} dealt twice");
            seen[card] = true;
            // Without one token the card stays closed.
            assert_eq!(unmask(&pks[..3 * POINT], &tokens[..3 * TOKEN], masked, true), None);
        }
        assert!(seen.iter().all(|s| *s));

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

        // And anybody can check that it is, without opening it. This
        // is what closes the hole doc 03 left: a passer who sealed the
        // receiver something else used to be indistinguishable from an
        // honest one to every third party.
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
            let c2 = (honest.1.into_projective() + elsewhere.1.into_projective()).into_affine();
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
        assert_eq!(split(&secret, 1, &seed(90), &mut vec![0u8; SCALAR]), None, "a split is into two or more");
    }

    /// A departed seat's card, opened by the holders of its key's two
    /// shares — without either of them, or anybody, ever holding the
    /// key. This is what lets doc 04's computation mean anything: if
    /// opening a position took the whole key back, the survivors would
    /// learn the whole hand and there would be nothing left to hide.
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
        for i in 1..4 {
            let at = (i + 1) * TOKEN;
            reveal_token(&secrets[i], masked, &seed(63 + i as u8), &mut tokens[at..at + TOKEN]).unwrap();
        }
        // A share's token is proved against that share's key, and
        // against nothing else — so a share-holder cannot pass off
        // somebody else's part as its own.
        assert!(verify_token(&share_pks[..POINT], masked, &tokens[..TOKEN]));
        assert!(!verify_token(&pks[..POINT], masked, &tokens[..TOKEN]), "not against the seat's whole key");
        assert!(!verify_token(&share_pks[POINT..], masked, &tokens[..TOKEN]), "nor the other share's");

        let card = unmask(&all_pks, &tokens, masked, true).expect("a card");
        assert_eq!(card, 7, "the initial deck is masked by one, so this is card seven");

        // And it is the card the whole key would have opened.
        let mut whole = vec![0u8; 4 * TOKEN];
        for (i, s) in secrets.iter().enumerate() {
            reveal_token(s, masked, &seed(70 + i as u8), &mut whole[i * TOKEN..(i + 1) * TOKEN]).unwrap();
        }
        assert_eq!(unmask(&pks, &whole, masked, true), Some(card), "the same card, by a key nobody held");

        // One share is not the key: without the other, no card.
        let mut short = tokens[..TOKEN].to_vec();
        short.extend_from_slice(&tokens[2 * TOKEN..]);
        let mut short_pks = share_pks[..POINT].to_vec();
        short_pks.extend_from_slice(&pks[POINT..]);
        assert_eq!(unmask(&short_pks, &short, masked, true), None, "one share opens nothing");
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
            assert_eq!(g.mul(sk.into_repr()).into_affine(), pk, "pair {i}");
        }
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

    /// What the deck's m x n factorisation costs on the wire and in
    /// the browser: the argument's bytes, and the time to make and
    /// check one. Run with --nocapture, changing M and N above.
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
