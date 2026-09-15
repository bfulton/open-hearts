// The relay core on its own, with no sockets in the way:
//
//   node --test service/do
//
// What the Dart suites prove over real sockets is proved here about
// the pieces — the signature check, the filters, what is forwarded and
// what is written down, and the two things only an object that
// hibernates needs: subscriptions that survive being put to sleep, and
// a bound on what one socket can make it carry.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { createRelay, maxSubscriptions, memoryStore, schnorrVerifier } from './relay.mjs';
import { wasmPath } from './host.mjs';
import { keys, signing } from './sign.mjs';

const wasm = readFileSync(wasmPath);
const verify = await schnorrVerifier(wasm);
const sign = await signing(wasm);

/// A socket that keeps what it was told, in order.
const socket = () => ({
  said: [],
  send(text) {
    this.said.push(JSON.parse(text));
  },
  /// Everything of one kind: `of('EVENT')`.
  of(what) {
    return this.said.filter((m) => m[0] === what);
  },
});

const beat = (key, at = 1000) =>
  sign.event(key, { kind: 24246, content: JSON.stringify({ kind: 'here', status: 'online' }), tags: [['t', 'online']], created_at: at });
const note = (key, at) => sign.event(key, { kind: 1, content: `n${at}`, created_at: at });

test('a forged event is refused, and reaches nobody', async () => {
  const relay = createRelay({ verify });
  const a = socket();
  const b = socket();
  relay.open(a);
  relay.open(b);
  await relay.message(b, JSON.stringify(['REQ', 'all', { kinds: [1] }]));

  const event = await note(keys[0], 1000);
  await relay.message(a, JSON.stringify(['EVENT', { ...event, content: 'something else' }]));
  const [ok] = a.of('OK');
  assert.equal(ok[2], false);
  assert.match(ok[3], /invalid/);

  // The id recomputed from the tampered content does not match, so it
  // is not even the same event; one signed for another author's key is
  // the other half of the same check.
  const forged = { ...event, pubkey: keys[1].public };
  await relay.message(a, JSON.stringify(['EVENT', forged]));
  assert.equal(a.of('OK')[1][2], false);

  // A key that is not 64 hex characters, claimed by an event the real
  // key signed. The wasm is given the bytes to check in a buffer it
  // keeps between calls, so a short key writes over only part of the
  // one before it and the rest of a real key would still be sitting
  // there: the shape is checked before anything is written.
  const clipped = { secret: keys[0].secret, public: keys[0].public.slice(0, 62) };
  await relay.message(a, JSON.stringify(['EVENT', await sign.event(clipped, { kind: 1, content: 'clipped', created_at: 1001 })]));
  assert.equal(a.of('OK')[2][2], false);

  assert.equal(b.of('EVENT').length, 0);
  assert.equal(relay.stored, 0);
});

test('a signed event is taken, stored if it is a kind that is stored, and forwarded to whoever asked for it', async () => {
  const relay = createRelay({ verify });
  const a = socket();
  const b = socket();
  relay.open(a);
  relay.open(b);
  await relay.message(b, JSON.stringify(['REQ', 'notes', { kinds: [1] }]));
  const event = await note(keys[0], 1000);
  await relay.message(a, JSON.stringify(['EVENT', event]));
  assert.deepEqual(a.of('OK')[0], ['OK', event.id, true, '']);
  assert.deepEqual(b.of('EVENT')[0], ['EVENT', 'notes', event]);
  assert.equal(relay.stored, 1);

  // Said twice is taken once.
  await relay.message(a, JSON.stringify(['EVENT', event]));
  const again = a.of('OK')[1];
  assert.equal(again[2], true);
  assert.match(again[3], /duplicate/);
  assert.equal(relay.stored, 1);
});

test('filters: kinds, a tag, an author prefix, since and until, and a limit from the newest end', async () => {
  const relay = createRelay({ verify });
  const writer = socket();
  relay.open(writer);
  const notes = [];
  for (let i = 0; i < 4; i++) {
    const event = await note(keys[i % 2], 1000 + i);
    notes.push(event);
    await relay.message(writer, JSON.stringify(['EVENT', event]));
  }
  const tagged = await sign.event(keys[0], { kind: 1, content: 'tagged', tags: [['t', 'T1']], created_at: 1010 });
  await relay.message(writer, JSON.stringify(['EVENT', tagged]));

  const ask = async (filter, id = 'q') => {
    const reader = socket();
    relay.open(reader);
    await relay.message(reader, JSON.stringify(['REQ', id, filter]));
    return reader.of('EVENT').map((m) => m[2].content);
  };
  assert.deepEqual(await ask({ kinds: [1], since: 1002 }), ['n1002', 'n1003', 'tagged']);
  assert.deepEqual(await ask({ kinds: [1], until: 1001 }), ['n1000', 'n1001']);
  assert.deepEqual(await ask({ kinds: [1], limit: 2 }), ['n1003', 'tagged']);
  assert.deepEqual(await ask({ '#t': ['T1'] }), ['tagged']);
  assert.deepEqual(await ask({ '#t': ['T2'] }), []);
  assert.deepEqual(await ask({ authors: [keys[1].public.slice(0, 8)] }), ['n1001', 'n1003']);
  assert.deepEqual(await ask({ ids: [notes[2].id] }), ['n1002']);
  assert.deepEqual(await ask({ kinds: [2] }), []);

  // History is answered, and then said to be over — a client waits for
  // that mark before it counts anybody as missing.
  const reader = socket();
  relay.open(reader);
  await relay.message(reader, JSON.stringify(['REQ', 'e', { kinds: [1] }]));
  assert.deepEqual(reader.said.at(-1), ['EOSE', 'e']);
  assert.equal(reader.said.filter((m) => m[0] === 'EOSE').length, 1);

  // And a filter that is not one is said to be bad, rather than
  // quietly answered with everything.
  const wrong = socket();
  relay.open(wrong);
  await relay.message(wrong, JSON.stringify(['REQ', 'x', { kinds: 'no' }]));
  assert.deepEqual(wrong.said, [['NOTICE', 'bad filter']]);
});

test('a beat reaches the other socket, and is never written down', async () => {
  const written = [];
  const kept = memoryStore();
  const store = {
    get size() {
      return kept.size;
    },
    add(event) {
      written.push(event);
      return kept.add(event);
    },
    matching: (...args) => kept.matching(...args),
    ids: () => kept.ids(),
  };
  const relay = createRelay({ verify, store });
  const a = socket();
  const b = socket();
  relay.open(a);
  relay.open(b);
  await relay.message(a, JSON.stringify(['REQ', 'online', { kinds: [24246], '#t': ['online'] }]));
  await relay.message(b, JSON.stringify(['REQ', 'online', { kinds: [24246], '#t': ['online'] }]));

  const mine = await beat(keys[0]);
  await relay.message(a, JSON.stringify(['EVENT', mine]));
  // The other device hears it — that is the whole of presence — and so
  // does the one that sent it, which is how a client knows its relay
  // is still carrying what it says.
  assert.deepEqual(b.of('EVENT')[0], ['EVENT', 'online', mine]);
  assert.deepEqual(a.of('EVENT')[0], ['EVENT', 'online', mine]);

  // Nothing of it is kept: an ephemeral kind is forwarded and
  // forgotten, which is why an object carrying presence writes nothing
  // and has nothing to sweep.
  assert.deepEqual(written, []);
  assert.equal(relay.stored, 0);

  // A late device hears nothing of a beat that has been and gone, and
  // is told so at once.
  const late = socket();
  relay.open(late);
  await relay.message(late, JSON.stringify(['REQ', 'online', { kinds: [24246], '#t': ['online'] }]));
  assert.deepEqual(late.said, [['EOSE', 'online']]);
});

test('what is kept is bounded as it is written: the oldest goes, nothing sweeps', async () => {
  const relay = createRelay({ verify, store: memoryStore(3) });
  const a = socket();
  relay.open(a);
  for (let i = 0; i < 5; i++) await relay.message(a, JSON.stringify(['EVENT', await note(keys[0], 1000 + i)]));
  assert.equal(relay.stored, 3);
  const reader = socket();
  relay.open(reader);
  await relay.message(reader, JSON.stringify(['REQ', 'q', { kinds: [1] }]));
  assert.deepEqual(reader.of('EVENT').map((m) => m[2].content), ['n1002', 'n1003', 'n1004']);
});

test('a socket that wakes carries its subscriptions with it', async () => {
  const first = createRelay({ verify });
  const a = socket();
  first.open(a);
  await first.message(a, JSON.stringify(['REQ', 'online', { kinds: [24246], '#t': ['online'] }]));
  const carried = first.subscriptionsOf(a);
  assert.deepEqual(carried, { online: [{ kinds: [24246], '#t': ['online'] }] });

  // The object was evicted and built again; the socket is still open
  // and comes back with what it asked for.
  const woken = createRelay({ verify });
  const b = socket();
  woken.open(a, JSON.parse(JSON.stringify(carried)));
  woken.open(b);
  const mine = await beat(keys[0]);
  await woken.message(b, JSON.stringify(['EVENT', mine]));
  assert.deepEqual(a.of('EVENT')[0], ['EVENT', 'online', mine]);
});

test('one socket may ask for only so much, and the oldest goes as the newest arrives', async () => {
  const relay = createRelay({ verify });
  const a = socket();
  relay.open(a);
  for (let i = 0; i <= maxSubscriptions; i++) {
    await relay.message(a, JSON.stringify(['REQ', `s${i}`, { kinds: [1], '#t': [`t${i}`] }]));
  }
  const held = Object.keys(relay.subscriptionsOf(a));
  assert.equal(held.length, maxSubscriptions);
  assert.equal(held.includes('s0'), false);
  assert.equal(held.includes(`s${maxSubscriptions}`), true);

  // And what was dropped is no longer served.
  const event = await sign.event(keys[0], { kind: 1, content: 'first tag', tags: [['t', 't0']] });
  await relay.message(a, JSON.stringify(['EVENT', event]));
  assert.equal(a.of('EVENT').length, 0);

  // A CLOSE leaves room again.
  await relay.message(a, JSON.stringify(['CLOSE', 's1']));
  assert.equal(Object.keys(relay.subscriptionsOf(a)).length, maxSubscriptions - 1);
});

test('nonsense gets a notice, and the connection stays', async () => {
  const relay = createRelay({ verify });
  const a = socket();
  relay.open(a);
  await relay.message(a, 'not json');
  await relay.message(a, JSON.stringify({ hello: true }));
  await relay.message(a, JSON.stringify(['HELLO']));
  await relay.message(a, JSON.stringify(['EVENT']));
  await relay.message(a, JSON.stringify(['REQ', 'x']));
  assert.deepEqual(a.said, [
    ['NOTICE', 'not JSON'],
    ['NOTICE', 'not a message'],
    ['NOTICE', 'unknown message HELLO'],
    ['NOTICE', 'EVENT takes one event'],
    ['NOTICE', 'REQ takes an id and filters'],
  ]);
  assert.equal(relay.connections, 1);
});

test('a policy may turn an event away, with the reason the client is told', async () => {
  const asked = [];
  const relay = createRelay({
    verify,
    refuse: (event) => {
      asked.push(event.id);
      return event.kind === 1 ? 'pow: 28 bits needed' : null;
    },
  });
  const a = socket();
  relay.open(a);
  const refused = await note(keys[0], 1000);
  await relay.message(a, JSON.stringify(['EVENT', refused]));
  assert.deepEqual(a.of('OK')[0], ['OK', refused.id, false, 'pow: 28 bits needed']);
  assert.equal(relay.stored, 0);
  const taken = await beat(keys[0]);
  await relay.message(a, JSON.stringify(['EVENT', taken]));
  assert.equal(a.of('OK')[1][2], true);
  assert.deepEqual(asked, [refused.id, taken.id]);
});

test('a burst from one socket is answered in the order it was sent', async () => {
  const relay = createRelay({ verify });
  const a = socket();
  relay.open(a);
  const events = [];
  for (let i = 0; i < 6; i++) events.push(await note(keys[0], 1000 + i));
  // Nothing is awaited between them: the relay checks a signature
  // before it answers, so without a turn each these would come back
  // in whatever order the checks finished.
  const all = events.map((e) => relay.message(a, JSON.stringify(['EVENT', e])));
  all.push(relay.message(a, JSON.stringify(['REQ', 'q', { kinds: [1] }])));
  await Promise.all(all);
  assert.deepEqual(a.of('OK').map((m) => m[1]), events.map((e) => e.id));
  // The REQ was sent last, so its history holds every event before it.
  assert.deepEqual(a.of('EVENT').map((m) => m[2].content), events.map((e) => e.content));
});
