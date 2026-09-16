//! Oblivious transfer extension, to price what doc 04's computation
//! would spend before it computes anything.
//!
//! Authenticated garbling needs one authenticated AND triple per AND
//! gate of the circuit, and a triple is built from oblivious transfers.
//! The transfers themselves are nearly free after a fixed start:
//! IKNP extends κ = 128 real (public-key) transfers into as many as you
//! like, each costing a few symmetric operations and κ bits on the
//! wire, and the KOS check makes the extension safe against a receiver
//! that cheats. That per-transfer cost is what this measures.
//!
//! **This is a benchmark, not a protocol.** Both sides run in one
//! process over shared memory, the base transfers are handed over
//! rather than performed, and nothing here has been reviewed to be used
//! for anything. What it is for is the number: how long a transfer
//! takes on a core and in a browser, and how many bytes it puts on the
//! wire. The base transfers it skips are κ public-key operations once
//! per pair, which against tens of thousands of extended ones is noise.
//!
//! The steps, for a receiver with choice bits `r` and a sender with a
//! secret `s`, both κ bits wide:
//!
//! - the receiver expands its seed pairs into two κ × m bit matrices
//!   and sends their difference masked by `r` — κ bits an transfer, and
//!   the only thing that goes on the wire;
//! - the sender expands the seeds it holds and reconstructs a matrix
//!   `Q` whose rows differ from the receiver's `T` by `r_j · s`;
//! - both transpose, so each transfer is one row of κ bits;
//! - the check: the receiver proves its rows were built from a
//!   consistent `r` rather than chosen;
//! - and each row is hashed to the key the transfer hands over.

pub mod triple;

use aes::cipher::{BlockEncrypt, KeyInit};
use aes::Aes128;
use rand::{RngCore, SeedableRng};
use rand_chacha::ChaCha12Rng;

pub const KAPPA: usize = 128;
pub const BLOCK: usize = 16;

/// Where the time went, in milliseconds, and what went on the wire.
#[derive(Default, Clone, Copy)]
pub struct Cost {
    pub expand: f64,
    pub transpose: f64,
    pub check: f64,
    pub hash: f64,
    pub sent: usize,
}

/// AES-128 in counter mode as the generator: the standard choice, and
/// the one a real implementation would make for the same reason — it is
/// a block cipher call per sixteen bytes and nothing else.
pub(crate) fn expand_into(seed: &[u8; BLOCK], out: &mut [u8]) {
    let cipher = Aes128::new(seed.into());
    let mut block = [0u8; BLOCK];
    for (counter, chunk) in out.chunks_mut(BLOCK).enumerate() {
        block[..8].copy_from_slice(&(counter as u64).to_le_bytes());
        block[8..].fill(0);
        let mut b = block.into();
        cipher.encrypt_block(&mut b);
        chunk.copy_from_slice(&b[..chunk.len()]);
    }
}

/// The eight-by-eight bit transpose (Hacker's Delight), the inner step
/// of turning κ columns of m bits into m rows of κ bits.
fn transpose8(mut x: u64) -> u64 {
    let mut t = (x ^ (x >> 7)) & 0x00AA00AA00AA00AA;
    x = x ^ t ^ (t << 7);
    t = (x ^ (x >> 14)) & 0x0000CCCC0000CCCC;
    x = x ^ t ^ (t << 14);
    t = (x ^ (x >> 28)) & 0x00000000F0F0F0F0;
    x ^ t ^ (t << 28)
}

/// `cols` is κ rows of `m / 8` bytes; `rows` becomes m rows of κ / 8.
fn transpose(cols: &[u8], rows: &mut [u8], m: usize) {
    let stride = m / 8;
    let width = KAPPA / 8;
    for i0 in (0..KAPPA).step_by(8) {
        for j0 in (0..stride).step_by(1) {
            let mut block = [0u8; 8];
            for (d, b) in block.iter_mut().enumerate() {
                *b = cols[(i0 + d) * stride + j0];
            }
            let out = transpose8(u64::from_le_bytes(block)).to_le_bytes();
            for (e, b) in out.iter().enumerate() {
                rows[(j0 * 8 + e) * width + i0 / 8] = *b;
            }
        }
    }
}

/// Carry-less multiplication in GF(2^128), for the check's random
/// combination. Shift and xor: a core with a carry-less multiply
/// instruction, and a browser with wasm's SIMD, both do far better,
/// which is why the check is timed on its own.
fn gf_mul(a: u128, b: u128) -> u128 {
    let mut hi = 0u128;
    let mut lo = 0u128;
    for i in 0..128 {
        if (b >> i) & 1 == 1 {
            lo ^= a << i;
            if i > 0 {
                hi ^= a >> (128 - i);
            }
        }
    }
    // Fold the top half down: modulo x^128 + x^7 + x^2 + x + 1, every
    // x^(128+i) is x^(7+i) + x^(2+i) + x^(1+i) + x^i. What that spills
    // past the top again is at most seven bits, and folding those
    // cannot spill.
    lo ^= hi ^ (hi << 1) ^ (hi << 2) ^ (hi << 7);
    let spill = (hi >> 127) ^ (hi >> 126) ^ (hi >> 121);
    lo ^ spill ^ (spill << 1) ^ (spill << 2) ^ (spill << 7)
}

/// The hash that turns a row into the key a transfer hands over:
/// fixed-key AES, the construction every implementation of this uses.
pub(crate) struct Mmo(Aes128);

impl Mmo {
    pub(crate) fn new() -> Self {
        Mmo(Aes128::new(&[0x4f; BLOCK].into()))
    }

    pub(crate) fn of(&self, row: &[u8], tweak: u64) -> [u8; BLOCK] {
        let mut x = [0u8; BLOCK];
        x.copy_from_slice(row);
        for (b, t) in x[..8].iter_mut().zip(tweak.to_le_bytes()) {
            *b ^= t;
        }
        let mut b = x.into();
        self.0.encrypt_block(&mut b);
        let mut out = [0u8; BLOCK];
        for i in 0..BLOCK {
            out[i] = b[i] ^ x[i];
        }
        out
    }
}

pub(crate) fn bit(bytes: &[u8], i: usize) -> bool {
    (bytes[i / 8] >> (i % 8)) & 1 == 1
}

/// What a batch of transfers leaves behind. `macs` and `keys` are m
/// rows of κ bits, and row j of one is row j of the other xor `delta`
/// exactly where `choices` has bit j set.
///
/// Which is an authenticated bit already: the receiver's choice is the
/// bit, its row is the MAC, the sender's row is the key, and the
/// sender's secret is the global key the MAC is under. Nothing else
/// goes on the wire to authenticate a bit — the κ bits a transfer
/// costs are the whole of it, and that is why the triple below counts
/// its authenticated bits in transfers.
pub(crate) struct Cot {
    pub choices: Vec<u8>,
    pub macs: Vec<u8>,
    pub keys: Vec<u8>,
    pub delta: [u8; KAPPA / 8],
}

/// `m` correlated transfers, both sides, adding to `cost` as it goes.
pub(crate) fn cot(m: usize, rng: &mut ChaCha12Rng, cost: &mut Cost, now: &dyn Fn() -> f64) -> Cot {
    assert!(m % 8 == 0, "a whole number of bytes of choices");
    let stride = m / 8;
    let width = KAPPA / 8;

    // What the base transfers would have left behind: the receiver
    // holds both seeds of every pair, the sender the one its secret
    // chose.
    let mut pairs = vec![[[0u8; BLOCK]; 2]; KAPPA];
    for p in pairs.iter_mut() {
        rng.fill_bytes(&mut p[0]);
        rng.fill_bytes(&mut p[1]);
    }
    let mut s = [0u8; KAPPA / 8];
    rng.fill_bytes(&mut s);
    let mut choices = vec![0u8; stride];
    rng.fill_bytes(&mut choices);

    // The receiver expands, and sends the difference masked by its
    // choices — the whole of what this protocol puts on the wire.
    let at = now();
    let mut t_cols = vec![0u8; KAPPA * stride];
    let mut u_cols = vec![0u8; KAPPA * stride];
    let mut scratch = vec![0u8; stride];
    for i in 0..KAPPA {
        let t = &mut t_cols[i * stride..(i + 1) * stride];
        expand_into(&pairs[i][0], t);
        expand_into(&pairs[i][1], &mut scratch);
        let u = &mut u_cols[i * stride..(i + 1) * stride];
        for j in 0..stride {
            u[j] = t[j] ^ scratch[j] ^ choices[j];
        }
    }
    cost.sent += u_cols.len();

    // The sender expands the seeds it has and folds in what it was
    // sent, where its secret says to.
    let mut q_cols = vec![0u8; KAPPA * stride];
    for i in 0..KAPPA {
        let q = &mut q_cols[i * stride..(i + 1) * stride];
        expand_into(&pairs[i][usize::from(bit(&s, i))], q);
        if bit(&s, i) {
            for j in 0..stride {
                q[j] ^= u_cols[i * stride + j];
            }
        }
    }
    cost.expand += now() - at;

    let at = now();
    let mut t_rows = vec![0u8; m * width];
    let mut q_rows = vec![0u8; m * width];
    transpose(&t_cols, &mut t_rows, m);
    transpose(&q_cols, &mut q_rows, m);
    cost.transpose += now() - at;

    // The check: a random combination of the receiver's rows and
    // choices, which the sender can only match if the rows were built
    // from one consistent choice per row.
    let at = now();
    let mut chi_seed = [0u8; BLOCK];
    rng.fill_bytes(&mut chi_seed);
    let mut chis = vec![0u8; m * BLOCK];
    expand_into(&chi_seed, &mut chis);
    let mut x = 0u128;
    let mut t_acc = 0u128;
    let mut q_acc = 0u128;
    let s_word = u128::from_le_bytes(s);
    for j in 0..m {
        let chi = u128::from_le_bytes(chis[j * BLOCK..(j + 1) * BLOCK].try_into().unwrap());
        let t_row = u128::from_le_bytes(t_rows[j * width..(j + 1) * width].try_into().unwrap());
        let q_row = u128::from_le_bytes(q_rows[j * width..(j + 1) * width].try_into().unwrap());
        if bit(&choices, j) {
            x ^= chi;
        }
        t_acc ^= gf_mul(chi, t_row);
        q_acc ^= gf_mul(chi, q_row);
    }
    assert_eq!(q_acc, t_acc ^ gf_mul(x, s_word), "the check holds for an honest receiver");
    cost.sent += 3 * BLOCK;
    cost.check += now() - at;

    Cot { choices, macs: t_rows, keys: q_rows, delta: s }
}

/// `m` extended transfers, both sides, timed by phase. `now` is the
/// host's clock in milliseconds.
pub fn extend(m: usize, seed: u64, now: &dyn Fn() -> f64) -> Cost {
    let mut rng = ChaCha12Rng::seed_from_u64(seed);
    let mut cost = Cost::default();
    let Cot { choices: _, macs: t_rows, keys: q_rows, delta: s } = cot(m, &mut rng, &mut cost, now);
    let width = KAPPA / 8;

    // And the keys themselves: the sender hashes both of a pair, the
    // receiver the one it chose.
    let at = now();
    let mmo = Mmo::new();
    let mut fold = 0u8;
    for j in 0..m {
        let q = &q_rows[j * width..(j + 1) * width];
        let mut other = [0u8; BLOCK];
        for i in 0..BLOCK {
            other[i] = q[i] ^ s[i];
        }
        fold ^= mmo.of(q, j as u64)[0] ^ mmo.of(&other, j as u64)[0];
        fold ^= mmo.of(&t_rows[j * width..(j + 1) * width], j as u64)[0];
    }
    cost.hash = now() - at;
    // Keeps the hashing from being optimised away.
    assert!(fold == fold);
    cost
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The relation the whole extension rests on: the sender's row and
    /// the receiver's row differ by the sender's secret exactly where
    /// the receiver chose one.
    #[test]
    fn every_row_differs_by_the_secret_where_the_choice_says_so() {
        let m = 1024;
        let stride = m / 8;
        let width = KAPPA / 8;
        let mut rng = ChaCha12Rng::seed_from_u64(7);
        let mut pairs = vec![[[0u8; BLOCK]; 2]; KAPPA];
        for p in pairs.iter_mut() {
            rng.fill_bytes(&mut p[0]);
            rng.fill_bytes(&mut p[1]);
        }
        let mut s = [0u8; KAPPA / 8];
        rng.fill_bytes(&mut s);
        let mut choices = vec![0u8; stride];
        rng.fill_bytes(&mut choices);

        let mut t_cols = vec![0u8; KAPPA * stride];
        let mut u_cols = vec![0u8; KAPPA * stride];
        let mut q_cols = vec![0u8; KAPPA * stride];
        let mut scratch = vec![0u8; stride];
        for i in 0..KAPPA {
            let t = &mut t_cols[i * stride..(i + 1) * stride];
            expand_into(&pairs[i][0], t);
            expand_into(&pairs[i][1], &mut scratch);
            for j in 0..stride {
                u_cols[i * stride + j] = t[j] ^ scratch[j] ^ choices[j];
            }
        }
        for i in 0..KAPPA {
            let q = &mut q_cols[i * stride..(i + 1) * stride];
            expand_into(&pairs[i][usize::from(bit(&s, i))], q);
            if bit(&s, i) {
                for j in 0..stride {
                    q[j] ^= u_cols[i * stride + j];
                }
            }
        }
        let mut t_rows = vec![0u8; m * width];
        let mut q_rows = vec![0u8; m * width];
        transpose(&t_cols, &mut t_rows, m);
        transpose(&q_cols, &mut q_rows, m);

        for j in 0..m {
            let t = &t_rows[j * width..(j + 1) * width];
            let q = &q_rows[j * width..(j + 1) * width];
            for i in 0..BLOCK {
                let want = t[i] ^ if bit(&choices, j) { s[i] } else { 0 };
                assert_eq!(q[i], want, "row {j} byte {i}");
            }
        }
    }

    /// The transpose is its own inverse shape: κ columns of m bits in,
    /// m rows of κ bits out, every bit where it should be.
    #[test]
    fn the_transpose_puts_every_bit_where_it_belongs() {
        let m = 256;
        let stride = m / 8;
        let width = KAPPA / 8;
        let mut cols = vec![0u8; KAPPA * stride];
        let mut rng = ChaCha12Rng::seed_from_u64(3);
        rng.fill_bytes(&mut cols);
        let mut rows = vec![0u8; m * width];
        transpose(&cols, &mut rows, m);
        for i in 0..KAPPA {
            for j in 0..m {
                let from = bit(&cols[i * stride..(i + 1) * stride], j);
                let to = bit(&rows[j * width..(j + 1) * width], i);
                assert_eq!(from, to, "bit ({i}, {j})");
            }
        }
    }

    /// The field multiplication the check leans on, against what it
    /// must be: one is the identity, zero annihilates, and it commutes.
    #[test]
    fn the_field_multiplication_behaves_like_one() {
        let mut rng = ChaCha12Rng::seed_from_u64(11);
        for _ in 0..200 {
            let mut a = [0u8; BLOCK];
            let mut b = [0u8; BLOCK];
            rng.fill_bytes(&mut a);
            rng.fill_bytes(&mut b);
            let (a, b) = (u128::from_le_bytes(a), u128::from_le_bytes(b));
            assert_eq!(gf_mul(a, 1), a);
            assert_eq!(gf_mul(a, 0), 0);
            assert_eq!(gf_mul(a, b), gf_mul(b, a));
            // Associativity is what a wrong reduction breaks.
            let mut c = [0u8; BLOCK];
            rng.fill_bytes(&mut c);
            let c = u128::from_le_bytes(c);
            assert_eq!(gf_mul(gf_mul(a, b), c), gf_mul(a, gf_mul(b, c)));
            // And it distributes.
            assert_eq!(gf_mul(a, b ^ c), gf_mul(a, b) ^ gf_mul(a, c));
        }
    }

    #[test]
    fn a_run_holds_together() {
        let cost = extend(1 << 13, 5, &|| 0.0);
        assert_eq!(cost.sent, (1 << 13) * BLOCK + 3 * BLOCK, "κ bits an transfer, and the check");
    }
}

#[cfg(target_arch = "wasm32")]
mod host {
    extern "C" {
        pub fn now() -> f64;
        pub fn report(id: u32, ms: f64);
    }
}

/// Entry point for the browser host: extends [m] transfers and reports
/// each phase by id — 0 expand, 1 transpose, 2 check, 3 hash, 4 the
/// whole of it, 5 the bytes sent.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn bench(m: u32, seed: u64) {
    let c = extend(m as usize, seed, &|| unsafe { host::now() });
    let all = c.expand + c.transpose + c.check + c.hash;
    for (id, ms) in [(0, c.expand), (1, c.transpose), (2, c.check), (3, c.hash), (4, all), (5, c.sent as f64)] {
        unsafe { host::report(id, ms) };
    }
}

/// And the authentication on top: [n] authenticated AND triples, by id
/// — 6 the transfers under them, 7 the cross terms, 8 the leaky check,
/// 9 bucketing, 10 the whole of it, 11 bits on the wire, 12 block
/// cipher calls, 13 transfers consumed, 14 the KOS check inside 6, 15
/// the bits inside 11 that were the transfers.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn bench_triples(n: u32, bucket: u32, seed: u64) {
    let c = triple::triples(n as usize, bucket as usize, seed, &|| unsafe { host::now() });
    let all = c.abits + c.haand + c.check + c.bucket;
    for (id, v) in [
        (6, c.abits),
        (7, c.haand),
        (8, c.check),
        (9, c.bucket),
        (10, all),
        (11, c.bits as f64),
        (12, c.aes as f64),
        (13, c.transfers as f64),
        (14, c.abits_check),
        (15, c.abit_bits as f64),
    ] {
        unsafe { host::report(id, v) };
    }
}
