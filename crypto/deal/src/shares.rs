//! Shares: a seat's key and its secret, held in parts by others at
//! the table, so that a seat that has gone can still be opened and
//! audited without anybody ever holding what it held. The key splits
//! in the field it lives in, all of its shares needed ([split]) or
//! any t of n ([split_threshold]); the secret, being bytes, over the
//! field bytes live in ([share_bytes]).

use super::*;

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

// ---- a key in any t of n ---------------------------------------------------

/// A seat's key in [n] Shamir shares over the same scalar field, any
/// [t] of which rebuild it — where [split] makes shares that are all
/// needed at once.
///
/// A threshold because escrow among several holders, as a v2 game's
/// jury was, rests on enough of them being reachable when a bot seat
/// has to be opened. "Any two of them" keeps one holder alone from
/// being anything, with room to lose people.
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
/// index's share — which is how a holder brought on later is given
/// one without anybody rebuilding the key.
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

#[cfg(test)]
mod tests {
    use super::*;

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
    /// and a holder arriving later is given one of its own.
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

    /// Any t of n open a card, t-1 do not, and a holder who arrives
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

        // The card, opened by the holders at `have` plus the three
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
                assert!(verify_token(&against, masked, &token), "holder {i}'s scaled token checks");
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

        // A holder arriving later is given share seven, made by two
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

    /// And into more than two, for a table with no custodian to escrow to,
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
