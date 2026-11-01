//! The deal's operations, over slices: a seat's key and its proof,
//! the deck and its shuffles, the tokens that open a card, and a
//! passed card sealed to the seat it goes to.

use super::*;

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
/// bytes. The escrow in packages/deal does not use it: its pieces are
/// wrapped in the secret the two seats' table keys share
/// (Signer.sharedSecretWith).
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(proof_len, 4120, "the 4 × 13 argument (M, N)");

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

    /// A shuffle argument comes from another seat, and each vector in
    /// it is as long as its written length says. One cut short or
    /// emptied is an argument that does not hold. It is never a panic,
    /// which under panic = "abort" would end the process checking it:
    /// the house, or a verifier.
    #[test]
    fn a_shuffle_argument_with_a_vector_cut_short_is_refused() {
        let mut joint = vec![0u8; POINT];
        keygen(&seed(1), &mut joint).unwrap();
        let mut deck = vec![0u8; DECK_BYTES];
        initial_deck(&joint, &mut deck).unwrap();
        let mut next = vec![0u8; DECK_BYTES];
        let mut out = vec![0u8; 16384];
        let n = shuffle(&joint, &deck, &seed(2), &mut next, &mut out).unwrap();
        let proof = &out[..n];
        assert!(verify_shuffle(&joint, &deck, &next, proof));

        // Every vector in an M × N argument: where its length is
        // written (eight bytes, little-endian, then the elements), how
        // many elements an honest one has, and the size of one.
        let vectors = [
            (0, M, POINT),          // the shuffle's commitments
            (136, M, POINT),
            (304, M, POINT),        // the Hadamard argument's
            (504, 2 * M + 1, POINT), // its zero argument's
            (800, N, SCALAR),
            (1224, N, SCALAR),
            (1840, N, SCALAR),      // the single-value argument's
            (2264, N, SCALAR),
            (2784, 2 * M, POINT),   // the multi-exponentiation argument's
            (3048, 2 * M, MASKED),
            (3696, N, SCALAR),
        ];
        for (at, count, size) in vectors {
            assert_eq!(u64::from_le_bytes(proof[at..at + 8].try_into().unwrap()), count as u64, "{count} elements at {at}");
            let body = at + 8;
            for keep in [0, count - 1] {
                // Fewer elements and the rest of the argument as it was,
                // padded back to an honest argument's length.
                let mut bent = proof[..at].to_vec();
                bent.extend((keep as u64).to_le_bytes());
                bent.extend(&proof[body..body + keep * size]);
                bent.extend(&proof[body + count * size..]);
                bent.resize(proof.len(), 0);
                assert!(!verify_shuffle(&joint, &deck, &next, &bent), "{keep} of the {count} elements at {at}");
            }
        }
    }

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
        assert_eq!(n, KEY_PROOF);
        let proof2: KeyProof = read(&proof_bytes[..n]).unwrap();
        assert!(Protocol::verify_key_ownership(&f.pp, &pk2, &name, &proof2).is_ok(), "through bytes");
    }
}
