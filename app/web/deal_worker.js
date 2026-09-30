// The deal's slow calls, off the page's thread (packages/deal,
// lib/src/work.dart says which and why).
//
// The same deal.wasm the page instantiates, an instance of its own,
// driven through its linear memory exactly as deal_web.dart drives
// the page's: inputs copied in, the export called, outputs copied out,
// everything freed. Only the five primitives worth the trip are here;
// the rest are quick and stay on the page.
//
// The page sends it the wasm first, {wasm: bytes} — the bytes it
// fetched when the deal loaded, so that a worker started to replace
// one that failed needs nothing from the network — and it answers
// {ready: true} once the wasm is running, or {unloaded: why}. A job is
// {id, op, args: [Uint8Array]}; the answer is {id, out: [Uint8Array]}
// — a check's is one byte, 1 for holds — or {id, error}, which is a
// bug, here or in what was sent. Jobs are made one at a time in the
// order they come.
'use strict';

const POINT = 32;
const SCALAR = 32;
const SEED = 32;
const MASKED = 64;
const DECK = 52 * MASKED;
const BATCH_PROOF = 2 * POINT + SCALAR;
const PROOF_CAP = 16384;

// The module, compiled once, and the instance jobs are made in: a new
// one after a trap (below).
let module;
let current;
let trapped = false;

async function renew() {
  const instance = await WebAssembly.instantiate(module, {});
  instance.exports.deal_setup();
  current = instance.exports;
  trapped = false;
}

let given;
const loaded = new Promise((resolve) => {
  given = resolve;
})
  .then((bytes) => WebAssembly.compile(bytes))
  .then((m) => {
    module = m;
    return renew();
  });
loaded.then(
  () => self.postMessage({ ready: true }),
  (err) => self.postMessage({ unloaded: String((err && err.message) || err) }),
);

function exact(b, n, what) {
  if (!(b instanceof Uint8Array) || b.length !== n) {
    throw new Error(`${what}: ${b instanceof Uint8Array ? b.length : typeof b} bytes where ${n} go`);
  }
}

function wholeCards(b, what) {
  if (!(b instanceof Uint8Array) || b.length === 0 || b.length % MASKED !== 0) {
    throw new Error(`${what}: not a run of masked cards`);
  }
  return b.length / MASKED;
}

// Copies [inputs] into the module's memory and allocates [outputs]
// (lengths), gives [f] their addresses and a reader over the outputs,
// and frees all of it whatever [f] does. The memory's buffer is
// replaced when the module grows it, so it is read afresh at each use.
function withMemory(e, inputs, outputs, f) {
  const held = [];
  const place = (n) => {
    const size = Math.max(1, n);
    const p = e.deal_alloc(size);
    held.push([p, size]);
    return p;
  };
  try {
    const ins = inputs.map((b) => {
      const p = place(b.length);
      new Uint8Array(e.memory.buffer).set(b, p);
      return p;
    });
    const outs = outputs.map(place);
    const read = (p, n) => new Uint8Array(e.memory.buffer).slice(p, p + n);
    return f(ins, outs, read);
  } finally {
    for (const [p, size] of held) e.deal_free(p, size);
  }
}

const holds = (r) => [new Uint8Array([r === 1 ? 1 : 0])];

// A check of what another seat sent: input nobody here chose. A trap
// in it — the wasm refusing something it could not so much as read —
// is a check that does not hold, as it is on the page, where the
// session takes any throw from a check for a no. It is not the
// worker failing: a seat that could make every worker fail by sending
// something unreadable could put every honest device out of the game.
// The instance it happened in is replaced before the next job, in
// case the trap left anything in it half done.
function check(f) {
  try {
    return holds(f());
  } catch (err) {
    if (!(err instanceof WebAssembly.RuntimeError)) throw err;
    trapped = true;
    return holds(0);
  }
}

const ops = {
  initialDeck(e, [joint]) {
    exact(joint, POINT, 'joint key');
    return withMemory(e, [joint], [DECK], ([j], [out], read) => {
      if (e.deal_initial_deck(j, out) < 0) throw new Error('initial deck failed');
      return [read(out, DECK)];
    });
  },

  shuffle(e, [joint, deck, seed]) {
    exact(joint, POINT, 'joint key');
    exact(deck, DECK, 'deck');
    exact(seed, SEED, 'seed');
    return withMemory(e, [joint, deck, seed], [DECK, PROOF_CAP], ([j, d, s], [deckOut, proofOut], read) => {
      const n = e.deal_shuffle(j, d, s, deckOut, proofOut, PROOF_CAP);
      if (n < 0) throw new Error('shuffle failed');
      return [read(deckOut, DECK), read(proofOut, n)];
    });
  },

  verifyShuffle(e, [joint, before, after, proof]) {
    exact(joint, POINT, 'joint key');
    exact(before, DECK, 'deck before');
    exact(after, DECK, 'deck after');
    if (!(proof instanceof Uint8Array)) throw new Error('proof: not bytes');
    return check(() => withMemory(e, [joint, before, after, proof], [], ([j, b, a, p]) => e.deal_verify_shuffle(j, b, a, p, proof.length)));
  },

  revealTokens(e, [secret, cards, seed]) {
    exact(secret, SCALAR, 'secret');
    exact(seed, SEED, 'seed');
    const n = wholeCards(cards, 'cards');
    return withMemory(e, [secret, cards, seed], [n * POINT + BATCH_PROOF], ([s, c, sd], [out], read) => {
      const w = e.deal_reveal_tokens(s, c, n, sd, out);
      if (w < 0) throw new Error('reveal tokens failed');
      return [read(out, w)];
    });
  },

  verifyTokens(e, [pk, cards, tokens]) {
    exact(pk, POINT, 'key');
    const n = wholeCards(cards, 'cards');
    exact(tokens, n * POINT + BATCH_PROOF, 'tokens');
    return check(() => withMemory(e, [pk, cards, tokens], [], ([k, c, t]) => e.deal_verify_tokens(k, c, n, t)));
  },
};

// One job at a time, in the order they came, each on the instance as
// it stands once the job before it is done.
let line = loaded.catch(() => {});

async function make({ id, op, args }) {
  try {
    await loaded;
    if (trapped) await renew();
    const f = Object.prototype.hasOwnProperty.call(ops, op) ? ops[op] : null;
    if (f === null) throw new Error(`no such job: ${op}`);
    const out = f(current, args);
    self.postMessage({ id, out }, out.map((b) => b.buffer));
  } catch (err) {
    self.postMessage({ id, error: String((err && err.message) || err) });
  }
}

self.onmessage = (event) => {
  if (given !== null) {
    given(event.data.wasm);
    given = null;
    return;
  }
  line = line.then(() => make(event.data));
};
