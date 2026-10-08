// The browser's deal (app/web/deal.wasm, as committed) held to the
// golden vectors: every call of the deal on fixed seeds, with what the
// library built on arkworks 0.3 answered, byte for byte — keys, proofs,
// the deck, shuffles and their arguments, tokens, seals, shares, and the
// same calls with an argument bent or oddly encoded
// (crypto/deal/tests/golden.rs, which writes and replays the same file
// natively; packages/deal replays it over FFI).
//
// A wasm that answers every call the same can sit at a table with a
// device running the older one, and checks every record it wrote.
//
//   node --test e2e/deal_golden.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const vectors = JSON.parse(readFileSync(`${here}../crypto/deal/tests/golden/vectors.json`, 'utf8'));
const { instance } = await WebAssembly.instantiate(readFileSync(`${here}../app/web/deal.wasm`), {});
const e = instance.exports;
e.deal_setup();

const POINT = 32, SCALAR = 32, MASKED = 64, DECK = 52 * 64, TOKEN = 128, SEALED = 64, SEAL_PROOF = 160;
const tokensLen = (n) => n * POINT + 96;

const unhex = (h) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const values = Object.fromEntries(Object.entries(vectors.values).map(([k, v]) => [k, unhex(v)]));

// Inputs copied into the module's memory, an output buffer, the call,
// and what it wrote: as deal_web.dart calls it.
function run(inputs, outLen, f) {
  const held = [];
  const place = (n) => {
    const p = e.deal_alloc(Math.max(1, n));
    held.push([p, Math.max(1, n)]);
    return p;
  };
  try {
    const ins = inputs.map((b) => {
      const p = place(b.length);
      new Uint8Array(e.memory.buffer).set(b, p);
      return p;
    });
    const out = place(outLen);
    const extra = place(DECK);
    const ret = f(ins, out, extra);
    const mem = new Uint8Array(e.memory.buffer);
    return { ret, out: mem.slice(out, out + Math.max(0, ret)), extra: mem.slice(extra, extra + DECK) };
  } finally {
    for (const [p, n] of held) e.deal_free(p, n);
  }
}

// [bytes, ints] -> { ret, out }, one per op of the flat interface.
const ops = {
  keygen: ([s]) => run([s], POINT, ([a], o) => e.deal_keygen(a, o)),
  key_proof: ([s, name, seed]) => run([s, name, seed], 64, ([a, b, c], o) => e.deal_key_proof(a, b, name.length, c, o)),
  verify_key: ([pk, name, proof]) => run([pk, name, proof], 0, ([a, b, c]) => e.deal_verify_key(a, b, name.length, c)),
  aggregate: ([pks]) => run([pks], POINT, ([a], o) => e.deal_aggregate(a, pks.length / POINT, o)),
  initial_deck: ([j]) => run([j], DECK, ([a], o) => e.deal_initial_deck(a, o)),
  shuffle: ([j, deck, seed]) => {
    const r = run([j, deck, seed], 16384, ([a, b, c], o, x) => e.deal_shuffle(a, b, c, x, o, 16384));
    return r.ret < 0 ? r : { ret: r.ret, out: new Uint8Array([...r.extra, ...r.out]) };
  },
  verify_shuffle: ([j, a, b, p]) => run([j, a, b, p], 0, ([w, x, y, z]) => e.deal_verify_shuffle(w, x, y, z, p.length)),
  reveal_token: ([s, m, seed]) => run([s, m, seed], TOKEN, ([a, b, c], o) => e.deal_reveal_token(a, b, c, o)),
  verify_token: ([pk, m, t]) => run([pk, m, t], 0, ([a, b, c]) => e.deal_verify_token(a, b, c)),
  reveal_tokens: ([s, cards, seed]) =>
    run([s, cards, seed], tokensLen(cards.length / MASKED), ([a, b, c], o) => e.deal_reveal_tokens(a, b, cards.length / MASKED, c, o)),
  verify_tokens: ([pk, cards, t]) => run([pk, cards, t], 0, ([a, b, c]) => e.deal_verify_tokens(a, b, cards.length / MASKED, c)),
  split: ([s, seed], [n]) => run([s, seed], n * SCALAR, ([a, b], o) => e.deal_split(a, n, b, o)),
  share_bytes: ([s, seed], [n, t]) => run([s, seed], n * s.length, ([a, b], o) => e.deal_share_bytes(a, s.length, n, t, b, o)),
  bytes_lagrange: ([have], [index, at]) => run([have], 0, ([a]) => e.deal_bytes_lagrange(a, have.length, index, at)),
  bytes_scale: ([share], [by]) => run([share], share.length, ([a], o) => e.deal_bytes_scale(a, share.length, by, o)),
  bytes_sum: ([parts], [len]) => run([parts], len, ([a], o) => e.deal_bytes_sum(a, parts.length / len, len, o)),
  split_threshold: ([s, seed], [n, t]) => run([s, seed], n * SCALAR, ([a, b], o) => e.deal_split_threshold(a, n, t, b, o)),
  lagrange: ([have], [index, at]) => run([have], SCALAR, ([a], o) => e.deal_lagrange(a, have.length, index, at, o)),
  scalar_mul: ([x, y]) => run([x, y], SCALAR, ([a, b], o) => e.deal_scalar_mul(a, b, o)),
  scalar_sum: ([parts]) => run([parts], SCALAR, ([a], o) => e.deal_scalar_sum(a, parts.length / SCALAR, o)),
  point_scale: ([p, s]) => run([p, s], POINT, ([a, b], o) => e.deal_point_scale(a, b, o)),
  share_key: ([s]) => run([s], POINT, ([a], o) => e.deal_share_key(a, o)),
  share_token: ([s, m, seed]) => run([s, m, seed], TOKEN, ([a, b, c], o) => e.deal_share_token(a, b, c, o)),
  open_shared: ([sealed, parts]) => run([sealed, parts], POINT, ([a, b], o) => e.deal_open_shared(a, b, parts.length / POINT, o)),
  unmask: ([pks, tokens, m]) => run([pks, tokens, m], 0, ([a, b, c]) => e.deal_unmask(a, b, pks.length / POINT, c)),
  seal: ([s, to, m, seed]) => run([s, to, m, seed], SEALED + SEAL_PROOF, ([a, b, c, d], o) => e.deal_seal(a, b, c, d, o)),
  verify_seal: ([owner, to, m, sealed]) => run([owner, to, m, sealed], 0, ([a, b, c, d]) => e.deal_verify_seal(a, b, c, d)),
  open: ([s, sealed]) => run([s, sealed], POINT, ([a, b], o) => e.deal_open(a, b, o)),
  shared_secret: ([s, pk]) => run([s, pk], 32, ([a, b], o) => e.deal_shared_secret(a, b, o)),
};

function resolve(args) {
  const bytes = [];
  const ints = [];
  for (const a of args) {
    if (typeof a === 'number') {
      ints.push(a);
      continue;
    }
    const [name, at] = a.split('^');
    const v = new Uint8Array(values[name] ?? assert.fail(`no value ${name}`));
    if (at !== undefined) v[Number(at)] ^= 1;
    bytes.push(v);
  }
  return [bytes, ints];
}

test('the committed wasm answers every golden call as the library did', () => {
  const wrong = [];
  for (const [k, c] of vectors.calls.entries()) {
    const [bytes, ints] = resolve(c.args);
    const { ret, out } = ops[c.op](bytes, ints);
    if (ret !== c.ret) {
      wrong.push(`call ${k} ${c.op} ${c.args.join(' ')}: returned ${ret}, was ${c.ret}`);
      continue;
    }
    if (c.out !== undefined && Buffer.compare(Buffer.from(out), Buffer.from(values[c.out])) !== 0) {
      wrong.push(`call ${k} ${c.op} ${c.args.join(' ')}: wrote other bytes than ${c.out}`);
    }
  }
  assert.deepEqual(wrong, [], `${wrong.length} of ${vectors.calls.length} calls answer differently`);
});

test('every op of the flat interface is among them', () => {
  const seen = new Set(vectors.calls.map((c) => c.op));
  assert.deepEqual([...Object.keys(ops)].filter((op) => !seen.has(op)), []);
});
