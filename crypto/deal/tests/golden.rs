//! The deal's wire, held to what the library said before.
//!
//! `golden/vectors.json` is every operation of the deal called on fixed
//! seeds, with what the library answered, byte for byte: keys and their
//! proofs, the table's key, the deck, four shuffles with their
//! arguments, tokens one at a time and in batches, seals, opened cards,
//! splits and shares — and the same calls with an argument bent, or
//! encoded in a way no honest device writes, with what the library said
//! to those. Everything a device sends or keeps is in there, so a
//! library that answers every call the same is one an older device can
//! sit at a table with, and one that reads every record the older one
//! wrote.
//!
//! The file was written once, by the library built on arkworks 0.3,
//! and is not to be written again: it is what the library is held to,
//! not a picture of what it does now. The same file is replayed by the
//! Dart binding (packages/deal, test/golden_test.dart) and by the
//! browser's committed wasm (e2e/deal_golden.test.mjs).
//!
//!     cargo test --release --test golden          # replay
//!     DEAL_GOLDEN=write cargo test --release --test golden -- --nocapture
//!                                                 # write it (only ever once)
//!
//! A call is `{op, args, ret, out}`: `ret` is what the flat interface
//! returns (bytes written, 1 or 0 for a check, a card's index, or -1),
//! and `out` names the bytes written, kept among `values`. An argument
//! is an integer, or the name of a value — `name^N` is that value with
//! the low bit of byte N flipped.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use deal::*;
use serde_json::{json, Value};

const VECTORS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/golden/vectors.json");

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        write!(s, "{x:02x}").unwrap();
    }
    s
}

fn unhex(s: &str) -> Vec<u8> {
    assert!(s.len().is_multiple_of(2), "odd hex");
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex")).collect()
}

#[derive(Clone)]
enum Arg {
    Bytes(String),
    Int(usize),
}

/// What one call answers: the flat interface's return value and the
/// bytes it wrote.
fn call(op: &str, a: &[Vec<u8>], n: &[usize]) -> (i64, Option<Vec<u8>>) {
    fn w(r: Option<usize>, out: Vec<u8>) -> (i64, Option<Vec<u8>>) {
        match r {
            Some(k) => (k as i64, Some(out[..k].to_vec())),
            None => (-1, None),
        }
    }
    fn b(ok: bool) -> (i64, Option<Vec<u8>>) {
        (ok as i64, None)
    }
    let buf = |k: usize| vec![0u8; k];
    match op {
        "keygen" => {
            let mut o = buf(POINT);
            w(keygen(&a[0], &mut o), o)
        }
        "key_proof" => {
            let mut o = buf(KEY_PROOF);
            w(key_proof(&a[0], &a[1], &a[2], &mut o), o)
        }
        "verify_key" => b(verify_key(&a[0], &a[1], &a[2])),
        "aggregate" => {
            let mut o = buf(POINT);
            w(aggregate(&a[0], &mut o), o)
        }
        "initial_deck" => {
            let mut o = buf(DECK_BYTES);
            w(initial_deck(&a[0], &mut o), o)
        }
        "shuffle" => {
            // The new deck, then the argument; the return is the
            // argument's length, as deal_shuffle's is.
            let mut deck = buf(DECK_BYTES);
            let mut proof = buf(16384);
            match shuffle(&a[0], &a[1], &a[2], &mut deck, &mut proof) {
                Some(k) => {
                    deck.extend_from_slice(&proof[..k]);
                    (k as i64, Some(deck))
                }
                None => (-1, None),
            }
        }
        "verify_shuffle" => b(verify_shuffle(&a[0], &a[1], &a[2], &a[3])),
        "reveal_token" => {
            let mut o = buf(TOKEN);
            w(reveal_token(&a[0], &a[1], &a[2], &mut o), o)
        }
        "verify_token" => b(verify_token(&a[0], &a[1], &a[2])),
        "reveal_tokens" => {
            let mut o = buf(tokens_len(a[1].len() / MASKED));
            w(reveal_tokens(&a[0], &a[1], &a[2], &mut o), o)
        }
        "verify_tokens" => b(verify_tokens(&a[0], &a[1], &a[2])),
        "split" => {
            let mut o = buf(n[0] * SCALAR);
            w(split(&a[0], n[0], &a[1], &mut o), o)
        }
        "share_bytes" => {
            let mut o = buf(n[0] * a[0].len());
            w(share_bytes(&a[0], n[0], n[1], &a[1], &mut o), o)
        }
        "bytes_lagrange" => (bytes_lagrange(&a[0], n[0] as u8, n[1] as u8).map(i64::from).unwrap_or(-1), None),
        "bytes_scale" => {
            let mut o = buf(a[0].len());
            w(bytes_scale(&a[0], n[0] as u8, &mut o), o)
        }
        "bytes_sum" => {
            let mut o = buf(n[0]);
            w(bytes_sum(&a[0], n[0], &mut o), o)
        }
        "split_threshold" => {
            let mut o = buf(n[0] * SCALAR);
            w(split_threshold(&a[0], n[0], n[1], &a[1], &mut o), o)
        }
        "lagrange" => {
            let mut o = buf(SCALAR);
            w(lagrange(&a[0], n[0] as u8, n[1] as u8, &mut o), o)
        }
        "scalar_mul" => {
            let mut o = buf(SCALAR);
            w(scalar_mul(&a[0], &a[1], &mut o), o)
        }
        "scalar_sum" => {
            let mut o = buf(SCALAR);
            w(scalar_sum(&a[0], &mut o), o)
        }
        "point_scale" => {
            let mut o = buf(POINT);
            w(point_scale(&a[0], &a[1], &mut o), o)
        }
        "share_key" => {
            let mut o = buf(POINT);
            w(share_key(&a[0], &mut o), o)
        }
        "share_token" => {
            let mut o = buf(TOKEN);
            w(share_token(&a[0], &a[1], &a[2], &mut o), o)
        }
        "open_shared" => {
            let mut o = buf(POINT);
            w(open_shared(&a[0], &a[1], &mut o), o)
        }
        "unmask" => (unmask(&a[0], &a[1], &a[2]).map(|c| c as i64).unwrap_or(-1), None),
        "seal" => {
            let mut o = buf(SEALED + SEAL_PROOF);
            w(seal(&a[0], &a[1], &a[2], &a[3], &mut o), o)
        }
        "verify_seal" => b(verify_seal(&a[0], &a[1], &a[2], &a[3])),
        "open" => {
            let mut o = buf(POINT);
            w(open(&a[0], &a[1], &mut o), o)
        }
        "shared_secret" => {
            let mut o = buf(32);
            w(shared_secret(&a[0], &a[1], &mut o), o)
        }
        _ => panic!("no such op {op}"),
    }
}

/// The byte arguments and the integer ones of a call, in their order
/// within each kind (no op mixes them in a way the order matters across).
fn resolve(values: &BTreeMap<String, Vec<u8>>, args: &[Arg]) -> (Vec<Vec<u8>>, Vec<usize>) {
    let mut bytes = Vec::new();
    let mut ints = Vec::new();
    for a in args {
        match a {
            Arg::Int(i) => ints.push(*i),
            Arg::Bytes(r) => {
                let (name, flip) = match r.split_once('^') {
                    Some((n, at)) => (n, Some(at.parse::<usize>().expect("flip offset"))),
                    None => (r.as_str(), None),
                };
                let mut v = values.get(name).unwrap_or_else(|| panic!("no value {name}")).clone();
                if let Some(at) = flip {
                    v[at] ^= 1;
                }
                bytes.push(v);
            }
        }
    }
    (bytes, ints)
}

// ---- writing them ---------------------------------------------------------

struct Rec {
    values: BTreeMap<String, Vec<u8>>,
    calls: Vec<Value>,
}

fn s(x: &str) -> Arg {
    Arg::Bytes(x.to_string())
}
fn i(x: usize) -> Arg {
    Arg::Int(x)
}

impl Rec {
    fn val(&mut self, name: &str, v: &[u8]) -> Arg {
        assert!(!name.contains('^'));
        if let Some(old) = self.values.insert(name.to_string(), v.to_vec()) {
            assert_eq!(old, v, "{name} named twice");
        }
        s(name)
    }

    /// Calls [op] and records it, naming what it wrote [out].
    fn call(&mut self, op: &str, args: &[Arg], out: Option<&str>) -> (i64, Option<Vec<u8>>) {
        let (a, n) = resolve(&self.values, args);
        let (ret, bytes) = call(op, &a, &n);
        let mut c = json!({
            "op": op,
            "args": args.iter().map(|x| match x { Arg::Int(i) => json!(i), Arg::Bytes(r) => json!(r) }).collect::<Vec<_>>(),
            "ret": ret,
        });
        if let Some(b) = &bytes {
            let name = out.map(str::to_string).unwrap_or_else(|| format!("out{}", self.calls.len()));
            self.val(&name, b);
            c["out"] = json!(name);
        }
        self.calls.push(c);
        (ret, bytes)
    }

    fn must(&mut self, op: &str, args: &[Arg], out: &str) -> Vec<u8> {
        let (ret, bytes) = self.call(op, args, Some(out));
        assert!(ret >= 0, "{op} -> {out} failed");
        bytes.unwrap()
    }

    fn check(&mut self, op: &str, args: &[Arg], expect: bool) {
        let (ret, _) = self.call(op, args, None);
        assert_eq!(ret, expect as i64, "{op} {:?}", args.iter().map(|a| match a { Arg::Bytes(s) => s.clone(), Arg::Int(i) => i.to_string() }).collect::<Vec<_>>());
    }

    /// A check that holds, and the same check with each byte argument
    /// bent at [offsets] (as fractions of its length): recorded with
    /// whatever the library says to each.
    fn check_bent(&mut self, op: &str, args: &[Arg], offsets: &[f64]) {
        self.check(op, args, true);
        for (k, a) in args.iter().enumerate() {
            let Arg::Bytes(name) = a else { continue };
            let len = self.values[name].len();
            let mut seen = Vec::new();
            for f in offsets {
                let at = (((len - 1) as f64) * f) as usize;
                if seen.contains(&at) {
                    continue;
                }
                seen.push(at);
                let mut bent = args.to_vec();
                bent[k] = s(&format!("{name}^{at}"));
                self.call(op, &bent, None);
            }
        }
    }
}

fn seed(tag: u8, i: u8) -> [u8; 32] {
    let mut s = [0u8; 32];
    for (k, b) in s.iter_mut().enumerate() {
        *b = (k as u8).wrapping_mul(29).wrapping_add(tag).wrapping_mul(i.wrapping_add(3)) ^ 0x5a;
    }
    s[0] = tag;
    s[1] = i;
    s
}

fn concat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

fn write_vectors() -> Value {
    let mut r = Rec { values: BTreeMap::new(), calls: Vec::new() };
    let few = [0.0, 0.5, 1.0];
    let more = [0.0, 0.13, 0.37, 0.5, 0.71, 1.0];

    // Four seats: keys, their proofs bound to a name.
    let mut pks = Vec::new();
    for k in 0..4u8 {
        r.val(&format!("secret{k}"), &seed(1, k));
        r.val(&format!("name{k}"), format!("seat {k} at table 59594eb654e90c56").as_bytes());
        r.val(&format!("keyseed{k}"), &seed(2, k));
        let pk = r.must("keygen", &[s(&format!("secret{k}"))], &format!("pk{k}"));
        r.must("key_proof", &[s(&format!("secret{k}")), s(&format!("name{k}")), s(&format!("keyseed{k}"))], &format!("keyproof{k}"));
        pks.push(pk);
    }
    r.check_bent("verify_key", &[s("pk0"), s("name0"), s("keyproof0")], &more);
    for k in 1..4 {
        r.check("verify_key", &[s(&format!("pk{k}")), s(&format!("name{k}")), s(&format!("keyproof{k}"))], true);
    }
    r.check("verify_key", &[s("pk1"), s("name0"), s("keyproof0")], false);
    r.check("verify_key", &[s("pk0"), s("name1"), s("keyproof0")], false);
    // A name of no bytes, and a long one.
    r.val("noname", b"");
    r.val("longname", &[7u8; 300]);
    r.must("key_proof", &[s("secret0"), s("noname"), s("keyseed0")], "keyproof0_noname");
    r.check("verify_key", &[s("pk0"), s("noname"), s("keyproof0_noname")], true);
    r.must("key_proof", &[s("secret0"), s("longname"), s("keyseed1")], "keyproof0_long");
    r.check("verify_key", &[s("pk0"), s("longname"), s("keyproof0_long")], true);

    // The table's key, and smaller sums.
    let pks_all = concat(&[&pks[0], &pks[1], &pks[2], &pks[3]]);
    r.val("pks", &pks_all);
    r.val("pks3", &pks_all[..3 * POINT]);
    r.val("pks12", &pks_all[POINT..3 * POINT]);
    r.val("none", b"");
    r.must("aggregate", &[s("pks")], "joint");
    r.must("aggregate", &[s("pks3")], "joint3");
    r.must("aggregate", &[s("pks12")], "joint12");
    r.must("aggregate", &[s("none")], "agg_empty");

    // The deck, and four shuffles one after another.
    r.must("initial_deck", &[s("joint")], "deck0");
    for k in 0..4u8 {
        r.val(&format!("shuffleseed{k}"), &seed(3, k));
        let out = r.must("shuffle", &[s("joint"), s(&format!("deck{k}")), s(&format!("shuffleseed{k}"))], &format!("shuffled{k}"));
        r.val(&format!("deck{}", k + 1), &out[..DECK_BYTES]);
        r.val(&format!("shuffleproof{k}"), &out[DECK_BYTES..]);
        let args = [s("joint"), s(&format!("deck{k}")), s(&format!("deck{}", k + 1)), s(&format!("shuffleproof{k}"))];
        if k == 0 {
            r.check_bent("verify_shuffle", &args, &more);
        } else {
            r.check_bent("verify_shuffle", &args, &few);
        }
    }
    r.check("verify_shuffle", &[s("joint"), s("deck1"), s("deck0"), s("shuffleproof0")], false);
    r.check("verify_shuffle", &[s("joint3"), s("deck0"), s("deck1"), s("shuffleproof0")], false);
    r.check("verify_shuffle", &[s("joint"), s("deck1"), s("deck2"), s("shuffleproof0")], false);
    {
        // The argument with bytes after it (a reader stops where the
        // argument does), and with its first vector's length changed.
        let p = r.values["shuffleproof1"].clone();
        let mut longer = p.clone();
        longer.extend_from_slice(&[0u8; 17]);
        r.val("shuffleproof1_trailing", &longer);
        r.call("verify_shuffle", &[s("joint"), s("deck1"), s("deck2"), s("shuffleproof1_trailing")], None);
        let mut shorter = p.clone();
        shorter.truncate(p.len() - 1);
        r.val("shuffleproof1_short", &shorter);
        r.call("verify_shuffle", &[s("joint"), s("deck1"), s("deck2"), s("shuffleproof1_short")], None);
        for (name, at, v) in [("len_plus", 0usize, 5u8), ("len_huge", 7, 0x7f)] {
            let mut q = p.clone();
            q[at] = q[at].wrapping_add(v);
            r.val(&format!("shuffleproof1_{name}"), &q);
            r.call("verify_shuffle", &[s("joint"), s("deck1"), s("deck2"), s(&format!("shuffleproof1_{name}"))], None);
        }
    }
    let deck = r.values["deck4"].clone();

    // Tokens: one at a time with a proof each, for a few cards.
    for c in [0usize, 7, 51] {
        let m = format!("card{c}");
        r.val(&m, &deck[c * MASKED..(c + 1) * MASKED]);
        for k in 0..4u8 {
            r.val(&format!("tokenseed{k}_{c}"), &seed(4 + c as u8, k));
            r.must("reveal_token", &[s(&format!("secret{k}")), s(&m), s(&format!("tokenseed{k}_{c}"))], &format!("token{k}_{c}"));
        }
        let args = [s("pk0"), s(&m), s(&format!("token0_{c}"))];
        if c == 7 {
            r.check_bent("verify_token", &args, &more);
        } else {
            r.check("verify_token", &args, true);
        }
        r.check("verify_token", &[s("pk1"), s(&m), s(&format!("token0_{c}"))], false);
        let tokens: Vec<u8> = (0..4).flat_map(|k| r.values[&format!("token{k}_{c}")][..POINT].to_vec()).collect();
        r.val(&format!("tokens_{c}"), &tokens);
        r.val(&format!("tokens3_{c}"), &tokens[..3 * POINT]);
        r.call("unmask", &[s("pks"), s(&format!("tokens_{c}")), s(&m)], None);
        r.call("unmask", &[s("pks3"), s(&format!("tokens3_{c}")), s(&m)], None);
    }

    // In batches: each seat's thirteen, and one seat's whole deck.
    for k in 0..4u8 {
        let hand = format!("hand{k}");
        r.val(&hand, &deck[k as usize * 13 * MASKED..(k as usize + 1) * 13 * MASKED]);
        r.val(&format!("batchseed{k}"), &seed(9, k));
        r.must("reveal_tokens", &[s(&format!("secret{k}")), s(&hand), s(&format!("batchseed{k}"))], &format!("batch{k}"));
        let args = [s(&format!("pk{k}")), s(&hand), s(&format!("batch{k}"))];
        if k == 1 {
            r.check_bent("verify_tokens", &args, &more);
        } else {
            r.check("verify_tokens", &args, true);
        }
    }
    r.check("verify_tokens", &[s("pk0"), s("hand1"), s("batch1")], false);
    r.check("verify_tokens", &[s("pk1"), s("hand0"), s("batch1")], false);
    r.val("deckall", &deck);
    r.must("reveal_tokens", &[s("secret2"), s("deckall"), s("batchseed2")], "batchdeck2");
    r.check_bent("verify_tokens", &[s("pk2"), s("deckall"), s("batchdeck2")], &few);
    r.val("one_card", &deck[5 * MASKED..6 * MASKED]);
    r.must("reveal_tokens", &[s("secret3"), s("one_card"), s("batchseed3")], "batchone3");
    r.check("verify_tokens", &[s("pk3"), s("one_card"), s("batchone3")], true);
    // Hand 0 opened card by card: seat 0's tokens from its batch over
    // the hand, seat 2's from its batch over the deck, the others' one
    // at a time.
    for c in 0..13usize {
        let m = format!("h0c{c}");
        r.val(&m, &deck[c * MASKED..(c + 1) * MASKED]);
        let mut toks = Vec::new();
        for k in 0..4u8 {
            let t = if k == 0 {
                r.values["batch0"][c * POINT..(c + 1) * POINT].to_vec()
            } else if k == 2 {
                r.values["batchdeck2"][c * POINT..(c + 1) * POINT].to_vec()
            } else {
                r.val(&format!("h0seed{k}_{c}"), &seed(20 + c as u8, k));
                r.must("reveal_token", &[s(&format!("secret{k}")), s(&m), s(&format!("h0seed{k}_{c}"))], &format!("h0tok{k}_{c}"))[..POINT].to_vec()
            };
            toks.extend_from_slice(&t);
        }
        r.val(&format!("h0toks{c}"), &toks);
        r.call("unmask", &[s("pks"), s(&format!("h0toks{c}")), s(&m)], None);
    }

    // A pass: seat 0's token for a card, sealed to seat 1.
    r.val("sealseed", &seed(40, 0));
    r.must("seal", &[s("secret0"), s("pk1"), s("card7"), s("sealseed")], "sealed01");
    r.check_bent("verify_seal", &[s("pk0"), s("pk1"), s("card7"), s("sealed01")], &more);
    r.check("verify_seal", &[s("pk2"), s("pk1"), s("card7"), s("sealed01")], false);
    r.check("verify_seal", &[s("pk0"), s("pk2"), s("card7"), s("sealed01")], false);
    r.check("verify_seal", &[s("pk0"), s("pk1"), s("card0"), s("sealed01")], false);
    let sealed = r.values["sealed01"][..SEALED].to_vec();
    r.val("sealed01_c", &sealed);
    r.must("open", &[s("secret1"), s("sealed01_c")], "opened01");
    r.must("open", &[s("secret2"), s("sealed01_c")], "opened01_wrong");
    r.must("shared_secret", &[s("secret0"), s("pk1")], "shared01");
    r.must("shared_secret", &[s("secret1"), s("pk0")], "shared10");
    r.must("shared_secret", &[s("secret0"), s("pk2")], "shared02");

    // A departed seat's key in shares that add up, and the seal opened
    // from them.
    for (n, tag) in [(2usize, 50u8), (3, 51)] {
        r.val(&format!("splitseed{n}"), &seed(tag, 0));
        let shares = r.must("split", &[s("secret1"), i(n), s(&format!("splitseed{n}"))], &format!("split{n}"));
        let mut keys = Vec::new();
        let mut parts = Vec::new();
        for k in 0..n {
            r.val(&format!("share{n}_{k}"), &shares[k * SCALAR..(k + 1) * SCALAR]);
            keys.extend(r.must("share_key", &[s(&format!("share{n}_{k}"))], &format!("sharekey{n}_{k}")));
            r.val(&format!("sharetokseed{n}_{k}"), &seed(tag, k as u8 + 1));
            let t = r.must(
                "share_token",
                &[s(&format!("share{n}_{k}")), s("sealed01_c"), s(&format!("sharetokseed{n}_{k}"))],
                &format!("sharetok{n}_{k}"),
            );
            let args = [s(&format!("sharekey{n}_{k}")), s("sealed01_c"), s(&format!("sharetok{n}_{k}"))];
            if n == 2 && k == 0 {
                r.check_bent("verify_token", &args, &few);
            } else {
                r.check("verify_token", &args, true);
            }
            parts.extend_from_slice(&t[..POINT]);
        }
        r.val(&format!("sharekeys{n}"), &keys);
        r.must("aggregate", &[s(&format!("sharekeys{n}"))], &format!("sharekeysum{n}"));
        r.val(&format!("parts{n}"), &parts);
        r.must("open_shared", &[s("sealed01_c"), s(&format!("parts{n}"))], &format!("openshared{n}"));
        r.val(&format!("parts{n}_short"), &parts[..POINT]);
        r.must("open_shared", &[s("sealed01_c"), s(&format!("parts{n}_short"))], &format!("openshared{n}_short"));
    }
    r.call("split", &[s("secret1"), i(1), s("splitseed2")], None);

    // A threshold of the jury: six shares, any two.
    r.val("thresholdseed", &seed(60, 0));
    let th = r.must("split_threshold", &[s("secret0"), i(6), i(2), s("thresholdseed")], "threshold");
    let mut tkeys = Vec::new();
    for k in 0..6usize {
        r.val(&format!("tshare{}", k + 1), &th[k * SCALAR..(k + 1) * SCALAR]);
        tkeys.push(r.must("share_key", &[s(&format!("tshare{}", k + 1))], &format!("tsharekey{}", k + 1)));
    }
    for (set, tag) in [(vec![1u8, 2], 61u8), (vec![2, 5], 62), (vec![1, 3, 5], 63)] {
        let name = set.iter().map(|x| x.to_string()).collect::<Vec<_>>().join("");
        r.val(&format!("have{name}"), &set);
        let mut toks = r.values["tokens_7"][POINT..].to_vec();
        let mut keys = r.values["pks"][POINT..].to_vec();
        let mut toks_first = Vec::new();
        let mut keys_first = Vec::new();
        for &x in &set {
            let coef = r.must("lagrange", &[s(&format!("have{name}")), i(x as usize), i(0)], &format!("lag{name}_{x}"));
            let _ = coef;
            r.must("scalar_mul", &[s(&format!("tshare{x}")), s(&format!("lag{name}_{x}"))], &format!("scaled{name}_{x}"));
            r.val(&format!("scaledseed{name}_{x}"), &seed(tag, x));
            let t = r.must(
                "share_token",
                &[s(&format!("scaled{name}_{x}")), s("card7"), s(&format!("scaledseed{name}_{x}"))],
                &format!("scaledtok{name}_{x}"),
            );
            let against = r.must("point_scale", &[s(&format!("tsharekey{x}")), s(&format!("lag{name}_{x}"))], &format!("against{name}_{x}"));
            r.check("verify_token", &[s(&format!("against{name}_{x}")), s("card7"), s(&format!("scaledtok{name}_{x}"))], true);
            toks_first.extend_from_slice(&t[..POINT]);
            keys_first.extend_from_slice(&against);
        }
        toks_first.append(&mut toks);
        keys_first.append(&mut keys);
        r.val(&format!("ttoks{name}"), &toks_first);
        r.val(&format!("tkeys{name}"), &keys_first);
        r.call("unmask", &[s(&format!("tkeys{name}")), s(&format!("ttoks{name}")), s("card7")], None);
    }
    // A newcomer's share, seven, from shares two and five.
    let mut parts = Vec::new();
    for x in [2u8, 5] {
        r.must("lagrange", &[s("have25"), i(x as usize), i(7)], &format!("lag25_{x}_to7"));
        parts.extend(r.must("scalar_mul", &[s(&format!("tshare{x}")), s(&format!("lag25_{x}_to7"))], &format!("to7_{x}")));
    }
    r.val("to7", &parts);
    r.must("scalar_sum", &[s("to7")], "tshare7");
    r.must("share_key", &[s("tshare7")], "tsharekey7");
    r.val("have_bad", &[1u8, 1]);
    r.call("lagrange", &[s("have_bad"), i(1), i(0)], None);
    r.val("have_zero", &[0u8, 1]);
    r.call("lagrange", &[s("have_zero"), i(1), i(0)], None);
    r.call("lagrange", &[s("have12"), i(3), i(0)], None);
    r.call("split_threshold", &[s("secret0"), i(3), i(1), s("thresholdseed")], None);

    // A secret's bytes in shares, in the field bytes live in.
    r.val("bytesseed", &seed(70, 0));
    let bs = r.must("share_bytes", &[s("secret3"), i(6), i(2), s("bytesseed")], "bytesshares");
    for k in 0..6usize {
        r.val(&format!("bshare{}", k + 1), &bs[k * 32..(k + 1) * 32]);
    }
    let mut parts = Vec::new();
    for x in [2u8, 5] {
        let (c, _) = r.call("bytes_lagrange", &[s("have25"), i(x as usize), i(0)], None);
        parts.extend(r.must("bytes_scale", &[s(&format!("bshare{x}")), i(c as usize)], &format!("bscaled{x}")));
    }
    r.val("bparts", &parts);
    r.must("bytes_sum", &[s("bparts"), i(32)], "bsecret");
    r.call("bytes_lagrange", &[s("have_bad"), i(1), i(0)], None);
    r.must("share_bytes", &[s("secret3"), i(5), i(3), s("bytesseed")], "bytesshares3");

    // Encodings no honest device writes, and what the library said to
    // each: the same answer, to the bit, keeps two libraries agreeing
    // about a record even where one is lied to.
    let pk0 = r.values["pk0"].clone();
    let mut odd: Vec<(String, Vec<u8>)> = Vec::new();
    let mut inf = vec![0u8; 32];
    inf[31] = 0x40;
    odd.push(("inf".into(), inf.clone()));
    let mut inf_x = inf.clone();
    inf_x[0] = 1;
    odd.push(("inf_x1".into(), inf_x));
    let mut both = pk0.clone();
    both[31] |= 0xc0;
    odd.push(("pk0_bothflags".into(), both));
    let mut neg = pk0.clone();
    neg[31] ^= 0x80;
    odd.push(("pk0_negated".into(), neg));
    for bit in [0x10u8, 0x20] {
        let mut hi = pk0.clone();
        hi[31] ^= bit;
        odd.push((format!("pk0_bit{bit:x}"), hi));
    }
    // The base field's modulus, and one past it; the scalar field's.
    let p = unhex("0100000000000000000000000000000000000000000000001100000000000008");
    let rr = unhex("2f4dc6ad41a2661e32b2e7ca6d1281b7ffffffffffffffff1000000000000008");
    odd.push(("x_p".into(), p.clone()));
    let mut p1 = p.clone();
    p1[0] += 1;
    odd.push(("x_p1".into(), p1.clone()));
    let mut p_neg = p.clone();
    p_neg[31] |= 0x80;
    odd.push(("x_p_neg".into(), p_neg));
    odd.push(("ones".into(), vec![0xff; 32]));
    let mut ones_clear = vec![0xffu8; 32];
    ones_clear[31] = 0x0f;
    odd.push(("ones_clear".into(), ones_clear));
    for x in 0..8u8 {
        let mut v = vec![0u8; 32];
        v[0] = x;
        odd.push((format!("x{x}"), v.clone()));
        v[31] = 0x80;
        odd.push((format!("x{x}_neg"), v));
    }
    odd.push(("r".into(), rr.clone()));
    let mut r_minus = rr.clone();
    r_minus[0] -= 1;
    odd.push(("r_minus1".into(), r_minus));
    let mut r_plus = rr.clone();
    r_plus[0] += 1;
    odd.push(("r_plus1".into(), r_plus));
    odd.push(("zero".into(), vec![0u8; 32]));
    let mut one = vec![0u8; 32];
    one[0] = 1;
    odd.push(("one".into(), one));
    for (name, v) in &odd {
        r.val(name, v);
    }
    for (name, _) in &odd {
        // As a point.
        r.call("aggregate", &[s(name)], None);
        r.call("point_scale", &[s(name), s("one")], None);
        r.call("verify_key", &[s(name), s("name0"), s("keyproof0")], None);
        r.call("shared_secret", &[s("secret0"), s(name)], None);
        // As a scalar.
        r.call("scalar_sum", &[s(name)], None);
        r.call("scalar_mul", &[s(name), s("one")], None);
        r.call("point_scale", &[s("pk0"), s(name)], None);
        r.call("share_key", &[s(name)], None);
    }
    // A key at infinity, a deck under it, a shuffle of it.
    r.must("initial_deck", &[s("inf")], "deck_inf");
    r.val("shuffleseed_inf", &seed(80, 0));
    let (ret, out) = r.call("shuffle", &[s("inf"), s("deck_inf"), s("shuffleseed_inf")], Some("shuffled_inf"));
    if let Some(out) = out {
        r.val("deck_inf1", &out[..DECK_BYTES]);
        r.val("proof_inf", &out[DECK_BYTES..DECK_BYTES + ret as usize]);
        r.call("verify_shuffle", &[s("inf"), s("deck_inf"), s("deck_inf1"), s("proof_inf")], None);
    }
    // A card at infinity, and a token for it.
    let infcard = [inf.clone(), inf.clone()].concat();
    r.val("card_inf", &infcard);
    r.val("tokseed_inf", &seed(81, 0));
    if let (_, Some(_)) = r.call("reveal_token", &[s("secret0"), s("card_inf"), s("tokseed_inf")], Some("token_inf")) {
        r.call("verify_token", &[s("pk0"), s("card_inf"), s("token_inf")], None);
    }
    r.call("reveal_tokens", &[s("secret0"), s("card_inf"), s("tokseed_inf")], None);
    r.call("seal", &[s("secret0"), s("inf"), s("card7"), s("sealseed")], None);
    r.call("open", &[s("secret0"), s("card_inf")], None);
    // A token with a flag in it, and the batch with its argument's
    // points at infinity.
    let mut toks = r.values["tokens_7"].clone();
    toks[31] ^= 0x80;
    r.val("tokens_7_negfirst", &toks);
    r.call("unmask", &[s("pks"), s("tokens_7_negfirst"), s("card7")], None);
    let mut b = r.values["batch1"].clone();
    let at = 13 * POINT;
    b[at..at + 32].copy_from_slice(&inf);
    r.val("batch1_infa1", &b);
    r.call("verify_tokens", &[s("pk1"), s("hand1"), s("batch1_infa1")], None);

    json!({
        "about": "The deal's every call on fixed seeds, as the library built on arkworks 0.3 answered it (crypto/deal/tests/golden.rs). Written once; never written again.",
        "values": r.values.iter().map(|(k, v)| (k.clone(), json!(hex(v)))).collect::<serde_json::Map<_, _>>(),
        "calls": r.calls,
    })
}

// ---- replaying them -------------------------------------------------------

fn read_vectors() -> (BTreeMap<String, Vec<u8>>, Vec<Value>) {
    let text = std::fs::read_to_string(VECTORS).expect("golden/vectors.json");
    let v: Value = serde_json::from_str(&text).expect("json");
    let values = v["values"].as_object().unwrap().iter().map(|(k, h)| (k.clone(), unhex(h.as_str().unwrap()))).collect();
    (values, v["calls"].as_array().unwrap().clone())
}

#[test]
fn every_call_answers_as_it_did() {
    if std::env::var("DEAL_GOLDEN").as_deref() == Ok("write") {
        let v = write_vectors();
        std::fs::create_dir_all(std::path::Path::new(VECTORS).parent().unwrap()).unwrap();
        std::fs::write(VECTORS, serde_json::to_string_pretty(&v).unwrap() + "\n").unwrap();
        eprintln!("wrote {} calls", v["calls"].as_array().unwrap().len());
        return;
    }
    let (values, calls) = read_vectors();
    let mut wrong = Vec::new();
    let mut ops = BTreeMap::<String, (usize, usize)>::new();
    for (k, c) in calls.iter().enumerate() {
        let op = c["op"].as_str().unwrap();
        let args: Vec<Arg> = c["args"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| match a {
                Value::String(s) => Arg::Bytes(s.clone()),
                Value::Number(n) => Arg::Int(n.as_u64().unwrap() as usize),
                _ => panic!("arg"),
            })
            .collect();
        let (a, n) = resolve(&values, &args);
        let (ret, out) = call(op, &a, &n);
        let want = c["ret"].as_i64().unwrap();
        let e = ops.entry(op.to_string()).or_default();
        e.0 += 1;
        if want == 1 && op.starts_with("verify") {
            e.1 += 1;
        }
        if ret != want {
            wrong.push(format!("call {k} {op} {:?}: returned {ret}, was {want}", c["args"]));
            continue;
        }
        if let Some(name) = c["out"].as_str() {
            if out.as_deref() != Some(&values[name][..]) {
                wrong.push(format!("call {k} {op} {:?}: wrote other bytes than {name}", c["args"]));
            }
        }
    }
    for (op, (n, held)) in &ops {
        eprintln!("{op:16} {n:4} calls{}", if op.starts_with("verify") { format!(", {held} held") } else { String::new() });
    }
    assert!(wrong.is_empty(), "{} of {} calls answer differently:\n{}", wrong.len(), calls.len(), wrong.join("\n"));
    // Every op the flat interface has is in the file.
    for op in [
        "keygen", "key_proof", "verify_key", "aggregate", "initial_deck", "shuffle", "verify_shuffle", "reveal_token", "verify_token",
        "reveal_tokens", "verify_tokens", "split", "share_bytes", "bytes_lagrange", "bytes_scale", "bytes_sum", "split_threshold", "lagrange",
        "scalar_mul", "scalar_sum", "point_scale", "share_key", "share_token", "open_shared", "unmask", "seal", "verify_seal", "open",
        "shared_secret",
    ] {
        assert!(ops.contains_key(op), "{op} is not in the vectors");
    }
}
