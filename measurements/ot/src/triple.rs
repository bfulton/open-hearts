//! The authentication on top of the transfers: an **authenticated AND
//! triple**, which is what doc 04's garbling spends one of per AND gate
//! of the circuit a bot-held seat costs.
//!
//! Transfers are the floor and this is the rest of it, built exactly as
//! Wang, Ranellucci and Katz describe (*Authenticated Garbling and
//! Efficient Maliciously Secure Two-Party Computation*, CCS 2017,
//! [eprint 2017/030](https://eprint.iacr.org/2017/030)): Π_HaAND for
//! the cross terms of a product, Π_LaAND for a triple that is right but
//! leaks a little, and Π_aAND, which buckets B leaky triples into one
//! that does not leak.
//!
//! An authenticated bit costs nothing beyond the transfer under it. A
//! correlated transfer hands the receiver a row and the sender a row
//! that differ by the sender's secret exactly where the receiver's
//! choice bit is set, and that *is* the IT-MAC: the choice is the bit,
//! the receiver's row is the MAC, the sender's row is the key, the
//! sender's secret is the global key. So the aBits in what follows are
//! counted in transfers, at the κ bits a transfer already costs.
//!
//! **This is a benchmark, not a protocol**, on the same terms as the
//! extension it sits on: both parties run in one process over shared
//! memory, nothing is reviewed, and what is wanted is the number. The
//! random oracle is a chain of fixed-key AES, which is the primitive a
//! real implementation would reach for and is one block cipher call per
//! block either way; the count of those calls is reported, because that
//! is what a browser pays for.
//!
//! One correction to the paper, forced by its own equations. Figure 8
//! step 3 prints `u = v1 ⊕ x1y1`, which would make z2 alone the whole
//! product and leave [z1] — which step 1 draws and step 4 checks —
//! doing nothing. The check in step 4 holds exactly when
//! z1 ⊕ z2 = x ∧ y (work the four cases of x1, x2 through T and V and
//! it falls out), and F_aAND in Figure 7 says the same. So the term is
//! `u = v1 ⊕ x1y1 ⊕ z1`, which is what is implemented here, and the
//! tests below are what say it is right.

use rand::{RngCore, SeedableRng};
use rand_chacha::ChaCha12Rng;

use crate::{bit, cot, Cost, Mmo, BLOCK, KAPPA};

type Block = [u8; BLOCK];

/// How many leaky triples go into one that is not. A bucket of B leaves
/// a leak of about 2^-ρ for a batch of the right size: at ρ = 40 the
/// paper's Table 4 puts B = 4 from 3.1K triples upward and B = 3 only
/// past 280K, and a bot-held seat is 53,726 — so four.
pub const BUCKET: usize = 4;

/// Where the time went, in milliseconds, and what it cost.
#[derive(Default, Clone, Copy)]
pub struct TripleCost {
    /// The transfers underneath, and the KOS check over them.
    pub abits: f64,
    /// How much of that was the KOS check, which is shift-and-xor here
    /// and a few instructions on a core that has them (../README.md).
    pub abits_check: f64,
    /// How many of the bits on the wire were those transfers.
    pub abit_bits: usize,
    /// The cross terms of the product (Π_HaAND).
    pub haand: f64,
    /// The two halves of Π_LaAND's check, which is most of it.
    pub check: f64,
    /// Bucketing leaky triples into ones that are not (Π_aAND).
    pub bucket: f64,
    /// Bits on the wire, both directions.
    pub bits: usize,
    /// Block cipher calls, which is what a browser pays for.
    pub aes: usize,
    /// Correlated transfers consumed, which is what the wire mostly is.
    pub transfers: usize,
    pub triples: usize,
}

/// One authenticated bit, held by both parties at once because this is
/// one process. The owner has `v` and `mac`; the other party has `key`;
/// and `mac = key ⊕ v·Δ` for the *other* party's global key Δ.
#[derive(Clone, Copy, Default)]
struct Auth {
    v: bool,
    mac: Block,
    key: Block,
}

fn xor(a: Block, b: Block) -> Block {
    let mut out = [0u8; BLOCK];
    for i in 0..BLOCK {
        out[i] = a[i] ^ b[i];
    }
    out
}

/// Δ where the bit is set, nothing where it is not.
fn times(d: Block, b: bool) -> Block {
    if b {
        d
    } else {
        [0u8; BLOCK]
    }
}

impl Auth {
    /// Two bits of the same owner, added: the shares, the MACs and the
    /// keys all add, because the MAC relation is linear.
    fn add(self, o: Auth) -> Auth {
        Auth { v: self.v ^ o.v, mac: xor(self.mac, o.mac), key: xor(self.key, o.key) }
    }

    /// A public bit added in. The owner flips its share and keeps its
    /// MAC; the key holder folds `d·Δ` into the key, which is the same
    /// relation again.
    fn add_public(self, d: bool, delta: Block) -> Auth {
        Auth { v: self.v ^ d, mac: self.mac, key: xor(self.key, times(delta, d)) }
    }

    /// Multiplied by a public bit: itself, or the authenticated zero.
    fn times_public(self, d: bool) -> Auth {
        if d {
            self
        } else {
            Auth::default()
        }
    }
}

/// The random oracle, over one block and over two. Fixed-key AES, with
/// the tweak keeping one use apart from another — and every call
/// counted, because a browser has no AES instruction and this is where
/// its seconds go.
fn hash1(mmo: &Mmo, a: Block, tweak: u64, aes: &mut usize) -> Block {
    *aes += 1;
    mmo.of(&a, tweak)
}

fn hash2(mmo: &Mmo, a: Block, b: Block, tweak: u64, aes: &mut usize) -> Block {
    let inner = hash1(mmo, b, tweak ^ (1 << 63), aes);
    hash1(mmo, xor(a, inner), tweak, aes)
}

fn lsb(b: Block) -> bool {
    b[0] & 1 == 1
}

/// `n` authenticated bits owned by one party under the other's global
/// key, and that key. One correlated transfer each: the rows the
/// transfer leaves are the MAC and the key already.
fn a_bits(n: usize, rng: &mut ChaCha12Rng, cost: &mut Cost, now: &dyn Fn() -> f64) -> (Vec<Auth>, Block) {
    let m = n.div_ceil(8) * 8;
    let c = cot(m, rng, cost, now);
    let width = KAPPA / 8;
    let mut out = Vec::with_capacity(n);
    for j in 0..n {
        let mut mac = [0u8; BLOCK];
        let mut key = [0u8; BLOCK];
        mac.copy_from_slice(&c.macs[j * width..(j + 1) * width]);
        key.copy_from_slice(&c.keys[j * width..(j + 1) * width]);
        out.push(Auth { v: bit(&c.choices, j), mac, key });
    }
    (out, c.delta)
}

/// A triple that is right but leaks: z1 ⊕ z2 = (x1 ⊕ x2) ∧ (y1 ⊕ y2),
/// with a selective-failure attack still open on one input.
#[derive(Clone, Copy)]
struct Leaky {
    x1: Auth,
    y1: Auth,
    z1: Auth,
    x2: Auth,
    y2: Auth,
    z2: Auth,
}

/// Π_LaAND's check, one half of it: the party holding the MACs on
/// `xp, yp, zp` proves the triple is an AND to the party holding the
/// keys, without either learning the other's share of x.
///
/// The verifier builds T and U from its keys and its own shares; the
/// prover builds V from its MACs, not knowing which of the two the
/// verifier will open, and encrypts both to the verifier's own
/// authenticated bit. Equal only if z1 ⊕ z2 = x ∧ y.
#[allow(clippy::too_many_arguments)]
fn half_check(
    mmo: &Mmo,
    tweak: u64,
    aes: &mut usize,
    bits: &mut usize,
    rng: &mut ChaCha12Rng,
    delta_v: Block,
    delta_p: Block,
    xp: Auth,
    yp: Auth,
    zp: Auth,
    xv: Auth,
    yv: bool,
    zv: bool,
) -> bool {
    // The verifier. Every two-block hash here is the same oracle the
    // prover uses, so they share a tweak.
    let kz = xor(zp.key, times(delta_v, zv));
    let kyz = xor(xor(yp.key, zp.key), times(delta_v, yv ^ zv));
    let t0 = hash2(mmo, xp.key, kz, tweak, aes);
    let u0 = xor(t0, hash2(mmo, xor(xp.key, delta_v), kyz, tweak, aes));
    let t1 = hash2(mmo, xp.key, kyz, tweak, aes);
    let u1 = xor(t1, hash2(mmo, xor(xp.key, delta_v), kz, tweak, aes));
    let u = if xv.v { u1 } else { u0 };
    *bits += KAPPA;

    // The prover, which does not know which one it is answering, so it
    // answers both and lets the verifier's own bit open one.
    let mut r = [0u8; BLOCK];
    rng.fill_bytes(&mut r);
    let v0 = hash2(mmo, xp.mac, zp.mac, tweak, aes);
    let v1 = hash2(mmo, xp.mac, xor(zp.mac, yp.mac), tweak, aes);
    let h = hash1(mmo, xv.key, tweak + 1, aes);
    let hd = hash1(mmo, xor(xv.key, delta_p), tweak + 1, aes);
    let (w0, w1) = if xp.v {
        (xor(xor(h, v1), xor(u, r)), xor(xor(hd, v0), xor(u, r)))
    } else {
        (xor(xor(h, v0), r), xor(xor(hd, v1), r))
    };
    *bits += 2 * KAPPA;

    // And the verifier again, opening the one it can. The comparison
    // itself goes through a batched equality at the end of the run.
    let w = if xv.v { w1 } else { w0 };
    let t = if xv.v { t1 } else { t0 };
    xor(xor(w, hash1(mmo, xv.mac, tweak + 1, aes)), t) == r
}

/// The product half of Π_LaAND: Π_HaAND for the cross terms, then the
/// product itself. The check is [`la_check`], a pass of its own, as it
/// would be in an implementation that batches — and as it has to be
/// here, or the clock reading either side of it would cost more than
/// the step it was timing.
#[allow(clippy::too_many_arguments)]
fn la_and(
    mmo: &Mmo,
    tweak: u64,
    cost: &mut TripleCost,
    rng: &mut ChaCha12Rng,
    delta_a: Block,
    delta_b: Block,
    x1: Auth,
    y1: Auth,
    z1: Auth,
    x2: Auth,
    y2: Auth,
    r: Auth,
) -> Leaky {
    // Π_HaAND: shares of the two cross terms, x2·y1 and x1·y2, from
    // the authenticated bits themselves — the MAC relation is a
    // one-out-of-two transfer already, so this is two bits each way.
    let aes = &mut cost.aes;
    let s1 = rng.next_u32() & 1 == 1;
    let a0 = lsb(hash1(mmo, x2.key, tweak, aes)) ^ s1;
    let a1 = lsb(hash1(mmo, xor(x2.key, delta_a), tweak, aes)) ^ s1 ^ y1.v;
    let s2 = (if x2.v { a1 } else { a0 }) ^ lsb(hash1(mmo, x2.mac, tweak, aes));
    let t1 = rng.next_u32() & 1 == 1;
    let b0 = lsb(hash1(mmo, x1.key, tweak + 1, aes)) ^ t1;
    let b1 = lsb(hash1(mmo, xor(x1.key, delta_b), tweak + 1, aes)) ^ t1 ^ y2.v;
    let t2 = (if x1.v { b1 } else { b0 }) ^ lsb(hash1(mmo, x1.mac, tweak + 1, aes));
    let v1 = s1 ^ t2;
    let v2 = s2 ^ t1;
    cost.bits += 4;

    // The product itself: one bit each way, and z2 authenticated by
    // spending the random [r] it was masked with.
    let u = v1 ^ (x1.v & y1.v) ^ z1.v;
    let z2v = u ^ (x2.v & y2.v) ^ v2;
    let d = r.v ^ z2v;
    let z2 = r.add_public(d, delta_a);
    cost.bits += 2;

    Leaky { x1, y1, z1, x2, y2, z2 }
}

/// Both halves of Π_LaAND's check on one triple.
fn la_check(mmo: &Mmo, tweak: u64, cost: &mut TripleCost, rng: &mut ChaCha12Rng, delta_a: Block, delta_b: Block, t: &Leaky) -> bool {
    let bits = &mut cost.bits;
    let ok_b = half_check(mmo, tweak + 2, &mut cost.aes, bits, rng, delta_b, delta_a, t.x1, t.y1, t.z1, t.x2, t.y2.v, t.z2.v);
    let ok_a = half_check(mmo, tweak + 4, &mut cost.aes, bits, rng, delta_a, delta_b, t.x2, t.y2, t.z2, t.x1, t.y1.v, t.z1.v);
    ok_a && ok_b
}

/// Π_aAND's combining step: two leaky triples into one, which halves
/// what a selective failure could have learned. The y's are made equal
/// by opening their difference — two authenticated bits, whose MACs go
/// into the batch checked at the end — and the z's are corrected by it.
fn combine(a: Leaky, b: Leaky, bits: &mut usize) -> Leaky {
    let d = (a.y1.v ^ b.y1.v) ^ (a.y2.v ^ b.y2.v);
    *bits += 2;
    Leaky {
        x1: a.x1.add(b.x1),
        y1: a.y1,
        z1: a.z1.add(b.z1).add(b.x1.times_public(d)),
        x2: a.x2.add(b.x2),
        y2: a.y2,
        z2: a.z2.add(b.z2).add(b.x2.times_public(d)),
    }
}

/// `n` authenticated AND triples at bucket size `bucket`, both sides,
/// timed by phase. Every triple that comes out is checked to be one.
pub fn triples(n: usize, bucket: usize, seed: u64, now: &dyn Fn() -> f64) -> TripleCost {
    let mut rng = ChaCha12Rng::seed_from_u64(seed);
    let mut cost = TripleCost { triples: n, ..Default::default() };
    let leaky = n * bucket;

    // Six authenticated bits a leaky triple: x, y and z on one side,
    // x, y and the mask r on the other. One batch each way, so the
    // KOS check amortises the way it would in a real run.
    let at = now();
    let mut transfers = Cost::default();
    let (a_pool, delta_b) = a_bits(3 * leaky, &mut rng, &mut transfers, now);
    let (b_pool, delta_a) = a_bits(3 * leaky, &mut rng, &mut transfers, now);
    cost.abits = now() - at;
    cost.abits_check = transfers.check;
    cost.transfers = 6 * leaky;
    cost.abit_bits = transfers.sent * 8;
    cost.bits += cost.abit_bits;

    let mmo = Mmo::new();
    let at = now();
    let mut objects = Vec::with_capacity(leaky);
    for i in 0..leaky {
        objects.push(la_and(
            &mmo,
            (i as u64) << 3,
            &mut cost,
            &mut rng,
            delta_a,
            delta_b,
            a_pool[3 * i],
            a_pool[3 * i + 1],
            a_pool[3 * i + 2],
            b_pool[3 * i],
            b_pool[3 * i + 1],
            b_pool[3 * i + 2],
        ));
    }
    cost.haand = now() - at;

    let at = now();
    for (i, t) in objects.iter().enumerate() {
        assert!(
            la_check(&mmo, (i as u64) << 3, &mut cost, &mut rng, delta_a, delta_b, t),
            "the leaky check holds for honest parties"
        );
    }
    cost.check = now() - at;

    // Bucketing. The partition is random in the protocol because an
    // adversary must not be able to steer which leaky triples share a
    // bucket; a shuffle by the same generator stands in for the coin
    // the two parties would toss.
    let at = now();
    for i in (1..objects.len()).rev() {
        objects.swap(i, (rng.next_u64() % (i as u64 + 1)) as usize);
    }
    let mut out = Vec::with_capacity(n);
    for chunk in objects.chunks(bucket) {
        let mut acc = chunk[0];
        for next in &chunk[1..] {
            acc = combine(acc, *next, &mut cost.bits);
        }
        out.push(acc);
    }
    cost.bucket = now() - at;

    // The MACs opened while bucketing, and the equality the leaky
    // checks compare through, are each one digest a party for the
    // whole batch — nothing per triple, which is why they are added
    // once here rather than counted above.
    cost.bits += 6 * KAPPA;

    for t in &out {
        let x = t.x1.v ^ t.x2.v;
        let y = t.y1.v ^ t.y2.v;
        assert_eq!(t.z1.v ^ t.z2.v, x & y, "every triple that comes out is an AND");
    }
    cost
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What a transfer leaves behind is an authenticated bit: the MAC
    /// is the key xor the bit's own global key, on every one of them.
    #[test]
    fn the_transfers_leave_authenticated_bits() {
        let mut rng = ChaCha12Rng::seed_from_u64(1);
        let mut cost = Cost::default();
        let (pool, delta) = a_bits(512, &mut rng, &mut cost, &|| 0.0);
        for (i, b) in pool.iter().enumerate() {
            assert_eq!(b.mac, xor(b.key, times(delta, b.v)), "bit {i}");
        }
    }

    /// The leaky triple is a triple, and its check holds — over enough
    /// of them that every combination of x1 and x2 is covered many
    /// times, since the four cases take different branches.
    #[test]
    fn every_leaky_triple_is_an_and_and_passes_its_check() {
        let mmo = Mmo::new();
        let mut rng = ChaCha12Rng::seed_from_u64(2);
        let mut cost = Cost::default();
        let (a, delta_b) = a_bits(3 * 400, &mut rng, &mut cost, &|| 0.0);
        let (b, delta_a) = a_bits(3 * 400, &mut rng, &mut cost, &|| 0.0);
        let mut tcost = TripleCost::default();
        let mut seen = [0; 4];
        for i in 0..400 {
            let t = la_and(
                &mmo, (i as u64) << 3, &mut tcost, &mut rng, delta_a, delta_b,
                a[3 * i], a[3 * i + 1], a[3 * i + 2], b[3 * i], b[3 * i + 1], b[3 * i + 2],
            );
            assert!(la_check(&mmo, (i as u64) << 3, &mut tcost, &mut rng, delta_a, delta_b, &t), "the check holds at {i}");
            assert_eq!(t.z1.v ^ t.z2.v, (t.x1.v ^ t.x2.v) & (t.y1.v ^ t.y2.v), "an AND at {i}");
            assert_eq!(t.z2.mac, xor(t.z2.key, times(delta_a, t.z2.v)), "z2 is authenticated at {i}");
            seen[usize::from(t.x1.v) * 2 + usize::from(t.x2.v)] += 1;
        }
        assert!(seen.iter().all(|&c| c > 50), "every case of x1 and x2 was taken: {seen:?}");
    }

    /// And the check is a check: a party that hands over the wrong
    /// product fails it, whichever share it lies about. This is the
    /// test that says the four cases of the equations were transcribed
    /// the right way round — a check that always passes would not.
    #[test]
    fn a_wrong_product_fails_the_check() {
        let mmo = Mmo::new();
        let mut rng = ChaCha12Rng::seed_from_u64(3);
        let mut cost = Cost::default();
        let (a, delta_b) = a_bits(3 * 200, &mut rng, &mut cost, &|| 0.0);
        let (b, delta_a) = a_bits(3 * 200, &mut rng, &mut cost, &|| 0.0);
        let mut tcost = TripleCost::default();
        let mut caught = 0;
        for i in 0..200 {
            let mut t = la_and(
                &mmo, (i as u64) << 3, &mut tcost, &mut rng, delta_a, delta_b,
                a[3 * i], a[3 * i + 1], a[3 * i + 2], b[3 * i], b[3 * i + 1], b[3 * i + 2],
            );
            // Flip PB's share of the product, MAC and all, as a party
            // that wanted the wrong answer would.
            t.z2 = t.z2.add_public(true, delta_a);
            let bits = &mut 0;
            let ok_b = half_check(&mmo, 9, &mut tcost.aes, bits, &mut rng, delta_b, delta_a, t.x1, t.y1, t.z1, t.x2, t.y2.v, t.z2.v);
            let ok_a = half_check(&mmo, 11, &mut tcost.aes, bits, &mut rng, delta_a, delta_b, t.x2, t.y2, t.z2, t.x1, t.y1.v, t.z1.v);
            assert!(!(ok_a && ok_b), "a flipped product got through at {i}");
            caught += 1;
        }
        assert_eq!(caught, 200);
    }

    /// Bucketing keeps what it is given: B leaky triples in, one
    /// triple out, and it is still an AND of the combined inputs.
    #[test]
    fn a_bucket_of_leaky_triples_is_still_a_triple() {
        let cost = triples(64, BUCKET, 4, &|| 0.0);
        assert_eq!(cost.triples, 64);
        assert_eq!(cost.transfers, 64 * BUCKET * 6, "six authenticated bits a leaky triple");
    }

    /// And the wire is what the protocol says it is: the transfers
    /// under the authenticated bits, four bits and two for the
    /// product, and three κ-bit strings for each half of the check.
    #[test]
    fn the_wire_is_what_the_protocol_puts_on_it() {
        let n = 32;
        let cost = triples(n, BUCKET, 5, &|| 0.0);
        let leaky = n * BUCKET;
        let want = 6 * leaky * KAPPA           // an authenticated bit is a transfer
            + 2 * 3 * BLOCK * 8                // the two KOS checks over the batches
            + leaky * (4 + 2)                  // the cross terms, and the product
            + leaky * 2 * 3 * KAPPA            // both halves of the leaky check
            + n * (BUCKET - 1) * 2             // the y's opened while bucketing
            + 6 * KAPPA; // the batched MAC and equality digests
        assert_eq!(cost.bits, want);
    }
}
