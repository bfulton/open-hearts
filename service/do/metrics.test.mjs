// What the operator watches of the relay object (doc 06, "Watching it
// run"): counts a minute, never who. node --test service/do
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { objectRelay, schnorrVerifier, tallied, tally } from './relay.mjs';
import { wasmPath } from './host.mjs';
import { keys, signing } from './sign.mjs';

const wasm = readFileSync(wasmPath);
const verify = await schnorrVerifier(wasm);
const sign = await signing(wasm);

const socket = () => ({ said: [], send(text) { this.said.push(JSON.parse(text)); } });
const beat = (key, at) => sign.event(key, { kind: 24246, content: '{"kind":"here"}', tags: [['t', 'online']], created_at: at });

test('what became of each message is counted, and the counts are a line a minute', async () => {
  let t = 0;
  const points = [];
  const counts = tally({ writeDataPoint: (p) => points.push(p) }, { now: () => t });
  const relay = objectRelay(verify, { now: () => t, count: (what, n) => counts.count(what, n) });
  const a = socket();
  const b = socket();
  relay.open(a);
  relay.open(b);
  counts.count('opened', 2);
  await relay.message(b, JSON.stringify(['REQ', 's', { kinds: [24246] }]));
  const one = await beat(keys[0], 1000);
  await relay.message(a, JSON.stringify(['EVENT', one]));
  await relay.message(a, JSON.stringify(['EVENT', one]));
  await relay.message(a, JSON.stringify(['EVENT', { ...one, sig: '00'.repeat(64) }]));
  await relay.message(a, 'not json');
  // A kind this object does not carry: the relays proper keep those.
  await relay.message(a, JSON.stringify(['EVENT', await sign.event(keys[1], { kind: 1, content: 'stored', created_at: 1 })]));
  assert.equal(points.length, 0, 'inside the minute, nothing written');
  assert.deepEqual(
    Object.fromEntries(Object.entries(counts.counts).filter(([, v]) => v)),
    // One listener: b asked for presence, a only spoke.
    { opened: 2, subscriptions: 1, events: 1, delivered: 1, duplicate: 1, invalid: 1, malformed: 1, refused: 1 },
  );

  t = 60000;
  counts.count('closed');
  assert.equal(points.length, 1, 'a minute on, one line');
  const [p] = points;
  assert.deepEqual(p.blobs, ['relay'], 'no tag, no key');
  assert.equal(p.doubles.length, tallied.length + 1);
  assert.equal(p.doubles[tallied.indexOf('events')], 1);
  assert.equal(p.doubles[tallied.indexOf('closed')], 1);
  assert.equal(p.doubles.at(-1), 60, 'the seconds it covers');
  assert.ok(!JSON.stringify(p).includes(one.pubkey), 'never who');
});

test('a flood is counted as what it is, before it costs a signature', async () => {
  let t = 0;
  const counts = tally(null, { now: () => t });
  const relay = objectRelay(verify, { now: () => t, count: (what, n) => counts.count(what, n) });
  const a = socket();
  relay.open(a);
  for (let i = 0; i < 40; i++) await relay.message(a, JSON.stringify(['EVENT', await beat(keys[0], 2000 + i)]));
  assert.ok(counts.counts.rateLimited > 0);
  assert.equal(counts.counts.events + counts.counts.rateLimited, 40);
  await relay.message(a, 'x'.repeat(70000));
  assert.equal(counts.counts.tooBig, 1);
});

test('no dataset is no writing, and a quiet minute writes no line', () => {
  let t = 0;
  const points = [];
  const counts = tally({ writeDataPoint: (p) => points.push(p) }, { now: () => t });
  t = 120000;
  counts.flush();
  assert.equal(points.length, 0);
  tally(null).count('opened');
});
