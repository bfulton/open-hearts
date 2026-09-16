//! The bot inside the computation: authenticated garbling, so a hand
//! can be played by a seat nobody holds and seen by nobody at all.
//!
//! [Doc 04](../../../docs/04-live-play.md) puts a departed seat's
//! thirteen cards in as fragments that are never reassembled, runs the
//! bot policy over them, and takes out one position — which was going
//! face up anyway. This is that computation: Wang, Ranellucci and
//! Katz's Π_2pc ([eprint 2017/030](https://eprint.iacr.org/2017/030),
//! Figure 2) over the netlist `packages/engine/tool/circuit_dump.dart`
//! writes out of the bot.
//!
//! The shape of it. Every wire carries a mask λ = r ⊕ s, r known only
//! to one party and s only to the other, and both authenticated
//! ([`crate::triple`]). The evaluator only ever sees z ⊕ λ, which tells
//! it nothing, and a label. XOR and NOT are free — the masks and
//! labels add — and an AND gate costs a garbled table of four rows,
//! each row an authenticated bit and a label the evaluator can only
//! open with the labels it holds. A row it opens carries its own MAC,
//! so a garbler that corrupts one is caught rather than believed:
//! **that** is what makes this malicious security and not the
//! semi-honest kind doc 04 says must not be built.
//!
//! **This is a benchmark, not a protocol**, on the same terms as the
//! preprocessing under it: both parties run in one process over shared
//! memory, so nothing here *enforces* that a party cannot read the
//! other's state — it only computes what each would hold and what each
//! would send. Nothing has been reviewed to be used for anything, and
//! the hash is a fixed-key AES chain standing in for the random oracle.

use rand::{RngCore, SeedableRng};
use rand_chacha::ChaCha12Rng;

use crate::triple::{self, a_bits, times, two_keys, xor, Auth, TripleCost};
use crate::{Cost, Mmo, BLOCK, KAPPA};

type Block = [u8; BLOCK];

pub const XOR: u8 = 0;
pub const AND: u8 = 1;
pub const INV: u8 = 2;

pub struct Gate {
    pub op: u8,
    pub a: usize,
    pub b: usize,
    pub out: usize,
}

/// A circuit as `circuit_dump.dart` writes it: wires 0 and 1 are the
/// constants, a gate never has one as an operand, and the gates are in
/// build order, which is a topological one.
pub struct Netlist {
    pub wires: usize,
    pub inputs: Vec<usize>,
    /// Which party feeds each input: false the garbler, true the
    /// evaluator. A secret of the computation is one of each, xored
    /// inside the circuit, so neither holds it.
    pub owners: Vec<bool>,
    pub outputs: Vec<usize>,
    pub gates: Vec<Gate>,
    pub ands: usize,
    /// The test the dump came with: what each input carries, and what
    /// the bot itself chose for it.
    pub values: Vec<bool>,
    pub expect: Vec<bool>,
}

fn bits_of(s: &str) -> Vec<bool> {
    s.trim().chars().map(|c| c == '1').collect()
}

impl Netlist {
    pub fn parse(text: &str) -> Netlist {
        let mut net = Netlist {
            wires: 0,
            inputs: vec![],
            owners: vec![],
            outputs: vec![],
            gates: vec![],
            ands: 0,
            values: vec![],
            expect: vec![],
        };
        let mut a = vec![];
        let mut b = vec![];
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut f = line.split_whitespace();
            let head = f.next().unwrap();
            match head {
                "wires" => net.wires = f.next().unwrap().parse().unwrap(),
                "gates" => net.gates.reserve(f.next().unwrap().parse().unwrap()),
                "ands" => net.ands = f.next().unwrap().parse().unwrap(),
                "inputs" => {
                    f.next();
                    net.inputs = f.map(|w| w.parse().unwrap()).collect();
                }
                "outputs" => {
                    f.next();
                    net.outputs = f.map(|w| w.parse().unwrap()).collect();
                }
                "owners" => net.owners = bits_of(f.next().unwrap()),
                "a" => a = bits_of(f.next().unwrap()),
                "b" => b = bits_of(f.next().unwrap()),
                "expect" => net.expect = bits_of(f.next().unwrap()),
                "X" | "A" | "N" => {
                    let w: Vec<usize> = f.map(|x| x.parse().unwrap()).collect();
                    let op = match head {
                        "X" => XOR,
                        "A" => AND,
                        _ => INV,
                    };
                    net.gates.push(Gate { op, a: w[0], b: w[1], out: w[2] });
                }
                _ => panic!("a line this does not know: {line}"),
            }
        }
        // The two shares interleave, one input wire each, in the order
        // the circuit asked for them.
        net.values = a.iter().zip(b.iter()).flat_map(|(x, y)| [*x, *y]).collect();
        assert_eq!(net.values.len(), net.inputs.len(), "a value for every input");
        assert_eq!(net.owners.len(), net.inputs.len(), "an owner for every input");
        assert_eq!(net.gates.iter().filter(|g| g.op == AND).count(), net.ands, "the AND count is the AND count");
        net
    }

    /// The circuit in the clear, for a test to check the garbled run
    /// against. Nothing in the protocol does this.
    pub fn evaluate(&self, values: &[bool]) -> Vec<bool> {
        let mut w = vec![false; self.wires];
        w[1] = true;
        for (i, &wire) in self.inputs.iter().enumerate() {
            w[wire] = values[i];
        }
        for g in &self.gates {
            w[g.out] = match g.op {
                XOR => w[g.a] ^ w[g.b],
                AND => w[g.a] & w[g.b],
                _ => !w[g.a],
            };
        }
        self.outputs.iter().map(|&o| w[o]).collect()
    }
}

/// Where the time went, in milliseconds, and what it cost.
#[derive(Default, Clone, Copy)]
pub struct GarbleCost {
    /// The triples and the authenticated bits under everything.
    pub preprocess: f64,
    /// Building the garbled tables and sending them.
    pub garble: f64,
    /// Opening one row a gate.
    pub evaluate: f64,
    /// Bits on the wire, both directions, preprocessing included.
    pub bits: usize,
    /// How many of those were the preprocessing.
    pub preprocess_bits: usize,
    pub aes: usize,
    pub ands: usize,
}

fn lsb(b: Block) -> bool {
    b[0] & 1 == 1
}

fn hash(mmo: &Mmo, x: Block, tweak: u64, aes: &mut usize) -> Block {
    *aes += 1;
    mmo.of(&x, tweak)
}

/// The random oracle a garbled row is masked with: the two labels and
/// the gate's own place in the circuit, into a bit and two blocks.
fn row_hash(mmo: &Mmo, la: Block, lb: Block, gamma: usize, i: usize, aes: &mut usize) -> (bool, Block, Block) {
    let t = ((gamma as u64) << 2) | i as u64;
    let seed = xor(la, hash(mmo, lb, t ^ (1 << 62), aes));
    (
        lsb(hash(mmo, seed, t ^ (1 << 60), aes)),
        hash(mmo, seed, t, aes),
        hash(mmo, seed, t ^ (1 << 61), aes),
    )
}

/// What each party holds about one wire.
#[derive(Clone, Copy, Default)]
struct Wire {
    /// The garbler's share of the mask, authenticated to the evaluator.
    r: Auth,
    /// The evaluator's share, authenticated to the garbler.
    s: Auth,
    /// The garbler's label for zero; for one it is this xor Δ_A.
    l0: Block,
}

/// One garbled AND gate: four rows, each a bit and two blocks, of
/// which the evaluator can open exactly one.
struct Rows {
    bit: [bool; 4],
    mac: [Block; 4],
    label: [Block; 4],
    /// What the evaluator holds for each row, which never travels.
    s: [bool; 4],
    s_mac: [Block; 4],
    r_key: [Block; 4],
    s_key: [Block; 4],
}

/// Π_2pc over [net], with [values] fed by whichever party owns each
/// input. Returns the output bits and what the whole of it cost.
pub fn compute(net: &Netlist, values: &[bool], bucket: usize, seed: u64, now: &dyn Fn() -> f64) -> (Vec<bool>, GarbleCost) {
    run(net, values, bucket, seed, now, None)
}

/// The same, with [corrupt] naming an AND gate whose garbled rows a
/// dishonest garbler tampers with — which is how the test shows the
/// tampering is caught rather than believed.
#[allow(clippy::too_many_arguments)]
pub fn run(
    net: &Netlist,
    values: &[bool],
    bucket: usize,
    seed: u64,
    now: &dyn Fn() -> f64,
    corrupt: Option<usize>,
) -> (Vec<bool>, GarbleCost) {
    let mut rng = ChaCha12Rng::seed_from_u64(seed);
    let (delta_a, delta_b) = two_keys(&mut rng);
    let mmo = Mmo::new();
    let mut cost = GarbleCost { ands: net.ands, ..Default::default() };

    // ---- function-independent ----------------------------------------
    // A fresh mask and label for every wire that cannot derive one —
    // the inputs, and the output of every AND gate — and one triple a
    // gate to multiply the masks with.
    let at = now();
    let fresh = net.inputs.len() + net.ands;
    let mut transfers = Cost::default();
    let r_pool = a_bits(fresh, &mut rng, &mut transfers, now, delta_b);
    let s_pool = a_bits(fresh, &mut rng, &mut transfers, now, delta_a);
    let mut tcost = TripleCost::default();
    let triples = triple::make(net.ands, bucket, &mut rng, &mut tcost, now, delta_a, delta_b);
    cost.preprocess = now() - at;
    cost.preprocess_bits = tcost.bits + transfers.sent * 8;
    cost.bits += cost.preprocess_bits;
    cost.aes += tcost.aes;

    let mut w = vec![Wire::default(); net.wires];
    let mut next = 0;
    let label = |rng: &mut ChaCha12Rng| {
        let mut l = [0u8; BLOCK];
        rng.fill_bytes(&mut l);
        l
    };
    for &wire in &net.inputs {
        w[wire] = Wire { r: r_pool[next], s: s_pool[next], l0: label(&mut rng) };
        next += 1;
    }

    // ---- function-dependent ------------------------------------------
    let at = now();
    let mut tables: Vec<Option<Rows>> = Vec::with_capacity(net.gates.len());
    let mut used = 0;
    for (g_index, g) in net.gates.iter().enumerate() {
        match g.op {
            XOR => {
                let (a, b) = (w[g.a], w[g.b]);
                w[g.out] = Wire { r: a.r.add(b.r), s: a.s.add(b.s), l0: xor(a.l0, b.l0) };
                tables.push(None);
            }
            INV => {
                // The mask is the operand's; the labels swap, so the
                // evaluator keeps its label and flips the bit it holds.
                let a = w[g.a];
                w[g.out] = Wire { r: a.r, s: a.s, l0: xor(a.l0, delta_a) };
                tables.push(None);
            }
            _ => {
                let (a, b) = (w[g.a], w[g.b]);
                w[g.out] = Wire { r: r_pool[next], s: s_pool[next], l0: label(&mut rng) };
                next += 1;
                let gamma = w[g.out];

                // The masks multiplied, out of a random triple: open
                // the two differences and correct. Two bits each way,
                // and the MACs go into the batch checked at the end.
                let t = &triples[used];
                used += 1;
                let d = (a.r.v ^ a.s.v) ^ (t.x1.v ^ t.x2.v);
                let e = (b.r.v ^ b.s.v) ^ (t.y1.v ^ t.y2.v);
                cost.bits += 4;
                let sig_a = t.z1.add(t.y1.times_public(d)).add(t.x1.times_public(e)).add_public(d && e, delta_b);
                let sig_b = t.z2.add(t.y2.times_public(d)).add(t.x2.times_public(e));
                debug_assert_eq!(
                    sig_a.v ^ sig_b.v,
                    (a.r.v ^ a.s.v) & (b.r.v ^ b.s.v),
                    "the triple multiplied the masks"
                );

                // The four rows, as the garbler and the evaluator each
                // compute them (Figure 2, steps 4b and 4c).
                let mut rows = Rows {
                    bit: [false; 4],
                    mac: [[0u8; BLOCK]; 4],
                    label: [[0u8; BLOCK]; 4],
                    s: [false; 4],
                    s_mac: [[0u8; BLOCK]; 4],
                    r_key: [[0u8; BLOCK]; 4],
                    s_key: [[0u8; BLOCK]; 4],
                };
                for i in 0..4 {
                    let (ta, tb) = (i & 2 != 0, i & 1 != 0);
                    // The garbler's side of the row.
                    let mut rv = sig_a.v ^ gamma.r.v;
                    let mut rm = xor(sig_a.mac, gamma.r.mac);
                    let mut sk = xor(sig_b.key, gamma.s.key);
                    // The evaluator's side.
                    let mut sv = sig_b.v ^ gamma.s.v;
                    let mut sm = xor(sig_b.mac, gamma.s.mac);
                    let mut rk = xor(sig_a.key, gamma.r.key);
                    // Crossed, and it has to be: at this row the
                    // evaluator's masked β is 1, so β's true value is
                    // 1 ⊕ λ_β, and what that leaves in the product is
                    // λ_α. The α terms answer to ẑ_β and the β terms
                    // to ẑ_α.
                    if tb {
                        rv ^= a.r.v;
                        rm = xor(rm, a.r.mac);
                        sk = xor(sk, a.s.key);
                        sv ^= a.s.v;
                        sm = xor(sm, a.s.mac);
                        rk = xor(rk, a.r.key);
                    }
                    if ta {
                        rv ^= b.r.v;
                        rm = xor(rm, b.r.mac);
                        sk = xor(sk, b.s.key);
                        sv ^= b.s.v;
                        sm = xor(sm, b.s.mac);
                        rk = xor(rk, b.r.key);
                    }
                    if ta && tb {
                        // The one row where the product is inverted,
                        // and the key that keeps its MAC honest.
                        sv = !sv;
                        sk = xor(sk, delta_a);
                    }
                    rows.s[i] = sv;
                    rows.s_mac[i] = sm;
                    rows.r_key[i] = rk;
                    rows.s_key[i] = sk;

                    // And what goes on the wire: the row, masked by the
                    // pair of labels only an evaluator holding both can
                    // reproduce.
                    let (hb, hm, hl) = row_hash(&mmo, xor(a.l0, times(delta_a, ta)), xor(b.l0, times(delta_a, tb)), g_index, i, &mut cost.aes);
                    rows.bit[i] = rv ^ hb;
                    rows.mac[i] = xor(rm, hm);
                    rows.label[i] = xor(xor(xor(gamma.l0, sk), times(delta_a, rv)), hl);
                }
                // A bit, a MAC and a label, four times.
                cost.bits += 4 * (1 + 2 * KAPPA);
                if corrupt == Some(g_index) {
                    for b in rows.bit.iter_mut() {
                        *b = !*b;
                    }
                }
                tables.push(Some(rows));
            }
        }
    }
    assert_eq!(next, fresh, "a mask for every wire that needs one");
    assert_eq!(used, net.ands, "a triple for every AND gate");
    cost.garble = now() - at;

    // ---- input processing ---------------------------------------------
    // Whoever does not own an input reveals its share of that wire's
    // mask, so the owner can mask its value and hand over the label.
    // What the evaluator ends up holding is the value xor the mask,
    // which is one random bit, and a label that says nothing.
    let at = now();
    let mut masked = vec![false; net.wires];
    let mut held: Vec<Block> = vec![[0u8; BLOCK]; net.wires];
    for (i, &wire) in net.inputs.iter().enumerate() {
        let wi = w[wire];
        if net.owners[i] {
            assert_eq!(wi.r.mac, xor(wi.r.key, times(delta_b, wi.r.v)), "the garbler's share is authentic");
        } else {
            assert_eq!(wi.s.mac, xor(wi.s.key, times(delta_a, wi.s.v)), "the evaluator's share is authentic");
        }
        let z = values[i] ^ wi.r.v ^ wi.s.v;
        masked[wire] = z;
        held[wire] = xor(wi.l0, times(delta_a, z));
        // A share and its MAC one way, the masked bit and its label back.
        cost.bits += 2 + 2 * KAPPA;
    }

    // ---- evaluation ----------------------------------------------------
    for (g_index, g) in net.gates.iter().enumerate() {
        match g.op {
            XOR => {
                masked[g.out] = masked[g.a] ^ masked[g.b];
                held[g.out] = xor(held[g.a], held[g.b]);
            }
            INV => {
                masked[g.out] = !masked[g.a];
                held[g.out] = held[g.a];
            }
            _ => {
                let rows = tables[g_index].as_ref().unwrap();
                let i = usize::from(masked[g.a]) * 2 + usize::from(masked[g.b]);
                let (hb, hm, hl) = row_hash(&mmo, held[g.a], held[g.b], g_index, i, &mut cost.aes);
                let rv = rows.bit[i] ^ hb;
                let rm = xor(rows.mac[i], hm);
                // The row carries its own MAC, so a garbler that
                // corrupted it is caught here rather than believed.
                assert_eq!(rm, xor(rows.r_key[i], times(delta_b, rv)), "the row the evaluator opened is authentic");
                masked[g.out] = rows.s[i] ^ rv;
                held[g.out] = xor(xor(rows.label[i], hl), rows.s_mac[i]);
            }
        }
    }
    cost.evaluate = now() - at;

    // ---- output ---------------------------------------------------------
    // The garbler reveals its share of each output wire's mask, with
    // its MAC, and the evaluator takes the mask off.
    let mut out = Vec::with_capacity(net.outputs.len());
    for &wire in &net.outputs {
        if wire < 2 {
            out.push(wire == 1);
            continue;
        }
        let wi = w[wire];
        assert_eq!(wi.r.mac, xor(wi.r.key, times(delta_b, wi.r.v)), "the output share is authentic");
        out.push(masked[wire] ^ wi.r.v ^ wi.s.v);
        cost.bits += 1 + KAPPA;
    }
    (out, cost)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A netlist built here rather than dumped, so the tests are not
    /// waiting on a file: [and_of] ands together every pair of a and b.
    fn pairs(n: usize) -> Netlist {
        let mut gates = vec![];
        let mut inputs = vec![];
        let mut owners = vec![];
        let mut outputs = vec![];
        let mut wire = 2;
        for _ in 0..n {
            let (a, b) = (wire, wire + 1);
            wire += 2;
            inputs.push(a);
            inputs.push(b);
            owners.push(false);
            owners.push(true);
            gates.push(Gate { op: AND, a, b, out: wire });
            outputs.push(wire);
            wire += 1;
        }
        Netlist { wires: wire, inputs, owners, outputs, gates, ands: n, values: vec![], expect: vec![] }
    }

    /// Every combination of the two parties' bits, through the garbled
    /// circuit, is the AND of them — which is the whole claim.
    #[test]
    fn a_garbled_and_is_an_and() {
        let net = pairs(4);
        for case in 0..16u32 {
            let values: Vec<bool> = (0..8).map(|i| (case >> (i / 2)) & 1 == 1 && i % 2 == 0).collect();
            let (got, _) = compute(&net, &values, 4, 100 + case as u64, &|| 0.0);
            assert_eq!(got, net.evaluate(&values), "case {case}");
        }
    }

    /// XOR and NOT are free, and still right: a circuit of them with
    /// one AND at the end agrees with the same circuit in the clear.
    #[test]
    fn the_free_gates_are_free_and_right() {
        // out = (a0 ^ b0) & !(a1 ^ b1)
        let net = Netlist {
            wires: 10,
            inputs: vec![2, 3, 4, 5],
            owners: vec![false, true, false, true],
            outputs: vec![9],
            gates: vec![
                Gate { op: XOR, a: 2, b: 3, out: 6 },
                Gate { op: XOR, a: 4, b: 5, out: 7 },
                Gate { op: INV, a: 7, b: 7, out: 8 },
                Gate { op: AND, a: 6, b: 8, out: 9 },
            ],
            ands: 1,
            values: vec![],
            expect: vec![],
        };
        for case in 0..16u32 {
            let values: Vec<bool> = (0..4).map(|i| (case >> i) & 1 == 1).collect();
            let (got, cost) = compute(&net, &values, 4, 200 + case as u64, &|| 0.0);
            assert_eq!(got, net.evaluate(&values), "case {case}");
            assert_eq!(cost.ands, 1, "one gate cost anything");
        }
    }

    /// The whole of it: the bot's own policy, garbled, over a hand
    /// split between two parties who each hold half of every card and
    /// neither of whom ever sees one — picking the position the bot
    /// itself picks. `bot.circuit` is written by
    /// `packages/engine/tool/circuit_dump.dart`, which refuses to
    /// write a circuit that disagrees with the bot.
    #[test]
    fn the_garbled_bot_picks_the_card_the_bot_picks() {
        let net = Netlist::parse(include_str!("../bot.circuit"));
        let (got, cost) = compute(&net, &net.values, 4, 7, &|| 0.0);
        assert_eq!(got, net.expect, "the position the bot chose");
        assert_eq!(got, net.evaluate(&net.values), "and the circuit in the clear agrees");
        assert_eq!(got.iter().filter(|b| **b).count(), 1, "exactly one position to open");
        assert_eq!(cost.ands, 2053, "the AND gates the circuit says it has");
    }

    /// Neither share is the hand. Flip one bit of the garbler's share
    /// and the answer moves — which is what says the computation is
    /// over both of them and not over one.
    #[test]
    fn one_party_s_share_is_not_the_hand() {
        let net = Netlist::parse(include_str!("../bot.circuit"));
        let mut theirs = net.values.clone();
        for v in theirs.iter_mut().step_by(2) {
            *v = false;
        }
        assert_ne!(net.evaluate(&theirs), net.expect, "the garbler's share alone says nothing");
    }

    /// And a garbler that tampers with a row is caught by the MAC the
    /// row carries, rather than quietly believed. This is the whole
    /// difference between this and the semi-honest version doc 04 says
    /// must not be built.
    #[test]
    #[should_panic(expected = "the row the evaluator opened is authentic")]
    fn a_tampered_row_is_caught() {
        let net = Netlist::parse(include_str!("../bot.circuit"));
        let first = net.gates.iter().position(|g| g.op == AND).unwrap();
        run(&net, &net.values, 4, 7, &|| 0.0, Some(first));
    }
}
