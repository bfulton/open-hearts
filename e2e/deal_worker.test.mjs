// The deal's Web Worker (app/web/deal_worker.js), in node's own test
// runner: node --test e2e/deal_worker.test.mjs
//
// Run in a thread of its own, as a browser runs it, with only what a
// worker has and node does not put in: `self`, its `postMessage`, and
// a fetch that reads files. What goes in and out is structured-cloned
// across the thread, as a browser's is. Its answers are held to the
// same wasm called directly on this thread — which is what the page's
// own binding, deal_web.dart, does — including for inputs tampered
// with, where a check that said yes would be the whole deal gone.
import assert from 'node:assert/strict';
import { test, after } from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';
import { randomBytes } from 'node:crypto';

const here = fileURLToPath(new URL('.', import.meta.url));
const script = `${here}../app/web/deal_worker.js`;

// What a browser gives a worker and node does not.
const shim = `
const { parentPort, workerData } = require('node:worker_threads');
const { readFile } = require('node:fs/promises');
const { fileURLToPath } = require('node:url');
const vm = require('node:vm');
globalThis.self = globalThis;
self.location = { href: workerData.href };
self.postMessage = (m, transfer) => parentPort.postMessage(m, transfer);
globalThis.fetch = async (url) => {
  try {
    const bytes = await readFile(fileURLToPath(String(url)));
    return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length) };
  } catch {
    return { ok: false, status: 404 };
  }
};
parentPort.on('message', (data) => self.onmessage({ data }));
vm.runInThisContext(workerData.source, { filename: workerData.href });
`;

function startWorker(query = '') {
  const w = new Worker(shim, {
    eval: true,
    workerData: { href: pathToFileURL(script).href + query, source: readFileSync(script, 'utf8') },
  });
  const waiting = new Map();
  let next = 0;
  w.on('message', (m) => {
    waiting.get(m.id)?.(m);
    waiting.delete(m.id);
  });
  return {
    job: (op, args) =>
      new Promise((resolve) => {
        const id = next++;
        waiting.set(id, resolve);
        w.postMessage({ id, op, args });
      }),
    close: () => w.terminate(),
  };
}

// The same module on this thread, called the way deal_web.dart calls it.
const { instance } = await WebAssembly.instantiate(readFileSync(`${here}../app/web/deal.wasm`), {});
const e = instance.exports;
e.deal_setup();
function direct(inputs, outLen, f) {
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
    const n = f(ins, out);
    return n < 0 ? null : new Uint8Array(e.memory.buffer).slice(out, out + n);
  } finally {
    for (const [p, n] of held) e.deal_free(p, n);
  }
}
const bytes = (n) => new Uint8Array(randomBytes(n));
const keygen = (s) => direct([s], 32, ([a], o) => e.deal_keygen(a, o));
const aggregate = (pks) => {
  const all = new Uint8Array(pks.length * 32);
  pks.forEach((p, i) => all.set(p, i * 32));
  return direct([all], 32, ([a], o) => e.deal_aggregate(a, pks.length, o));
};
const initialDeck = (joint) => direct([joint], 52 * 64, ([j], o) => e.deal_initial_deck(j, o));
const revealTokens = (secret, cards, seed) =>
  direct([secret, cards, seed], (cards.length / 64) * 32 + 96, ([s, c, sd], o) => e.deal_reveal_tokens(s, c, cards.length / 64, sd, o));
const flipped = (b, at) => {
  const c = new Uint8Array(b);
  c[at] ^= 1;
  return c;
};
const holds = (answer) => {
  assert.equal(answer.error, undefined, answer.error);
  assert.equal(answer.out.length, 1);
  assert.equal(answer.out[0].length, 1);
  return answer.out[0][0] === 1;
};

const secrets = [0, 1, 2, 3].map(() => bytes(32));
const pks = secrets.map(keygen);
const joint = aggregate(pks);
const w = startWorker();
after(() => w.close());

test('the deck before anyone shuffles is the one the page would make', async () => {
  const a = await w.job('initialDeck', [joint]);
  assert.equal(a.error, undefined, a.error);
  assert.deepEqual(a.out[0], initialDeck(joint));
});

test('a shuffle made there checks out, and one tampered with does not', async () => {
  const deck = initialDeck(joint);
  const s = await w.job('shuffle', [joint, deck, bytes(32)]);
  assert.equal(s.error, undefined, s.error);
  const [after, proof] = s.out;
  assert.equal(after.length, 52 * 64);
  assert.ok(proof.length > 0 && proof.length < 16384);
  // Checked by the module on this thread, not only by the worker.
  const here = direct([joint, deck, after, proof], 0, ([j, b, a, p]) => (e.deal_verify_shuffle(j, b, a, p, proof.length) === 1 ? 0 : -1));
  assert.notEqual(here, null, 'the page\'s own check holds');
  assert.equal(holds(await w.job('verifyShuffle', [joint, deck, after, proof])), true);
  assert.equal(holds(await w.job('verifyShuffle', [joint, deck, flipped(after, 100), proof])), false, 'another deck');
  assert.equal(holds(await w.job('verifyShuffle', [joint, deck, after, flipped(proof, 40)])), false, 'another argument');
  assert.equal(holds(await w.job('verifyShuffle', [joint, after, after, proof])), false, 'another deck before');
});

test('a seat\'s tokens are the page\'s, byte for byte, and a wrong one fails the batch', async () => {
  const deck = initialDeck(joint);
  const cards = deck.slice(13 * 64);
  const seed = bytes(32);
  const t = await w.job('revealTokens', [secrets[0], cards, seed]);
  assert.equal(t.error, undefined, t.error);
  assert.deepEqual(t.out[0], revealTokens(secrets[0], cards, seed));
  assert.equal(holds(await w.job('verifyTokens', [pks[0], cards, t.out[0]])), true);
  assert.equal(holds(await w.job('verifyTokens', [pks[1], cards, t.out[0]])), false, 'another seat\'s key');
  assert.equal(holds(await w.job('verifyTokens', [pks[0], cards, flipped(t.out[0], 5)])), false, 'a token changed');
});

test('what is not the shape of a job is an error, not an answer', async () => {
  assert.match((await w.job('verifyShuffle', [joint, bytes(10), bytes(52 * 64), bytes(8)])).error, /deck before/);
  assert.match((await w.job('verifyTokens', [pks[0], bytes(65), bytes(128)])).error, /masked cards/);
  assert.match((await w.job('keygen', [secrets[0]])).error, /no such job/);
  assert.match((await w.job('toString', [])).error, /no such job/);
});

test('a wasm that is not there fails every job, and says why', async () => {
  const lost = startWorker('?wasm=nothing-here.wasm');
  try {
    assert.match((await lost.job('initialDeck', [joint])).error, /nothing-here\.wasm is not served/);
    assert.match((await lost.job('verifyTokens', [pks[0], bytes(64), bytes(128)])).error, /not served/);
  } finally {
    await lost.close();
  }
});
