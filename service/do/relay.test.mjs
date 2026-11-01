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

import {
  createRelay,
  limitsFrom,
  maxSubscriptions,
  memoryStore,
  objectLimitBounds,
  objectLimits,
  objectLimitsOf,
  objectRelay,
  reactionKind,
  reactionMost,
  reactionRefusal,
  schnorrVerifier,
  socketLine,
  tableLimits,
  tagLabel,
  tagOf,
} from './relay.mjs';
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

test('the tag in the path is what names an object, and only a tag does', () => {
  // Everything this repo puts on a `t` tag: the one presence topic,
  // the standings, a pool, a table id, a room code.
  for (const tag of ['online', 'standings', 'queue:unrated', 'queue:rated:50', 'half-deaf-table', 'AB12CD']) {
    assert.equal(tagOf(`/${tag}`), tag);
  }
  // The root names no object: the worker turns that away, and the node
  // host keeps a relay there for the suites that connect to it.
  assert.equal(tagOf('/'), '');
  assert.equal(tagOf(''), '');
  // A name is one segment and nothing clever: no paths inside it, no
  // way up out of it, nothing that has to be unescaped twice.
  assert.equal(tagOf('/a/b'), null);
  assert.equal(tagOf('/..'), null);
  assert.equal(tagOf('/a%2Fb'), null);
  assert.equal(tagOf('/%zz'), null);
  assert.equal(tagOf(`/${'x'.repeat(129)}`), null);
  // What is escaped is read before it is judged, so a client that
  // writes a pool's colon out as an escape lands on the same object as
  // one that does not.
  assert.equal(tagOf('/queue%3Aunrated'), 'queue:unrated');
  // And this is the mark the app's relay list carries while nobody has
  // put a tag in it: it names no object, on purpose.
  assert.equal(tagOf('/%7Btag%7D'), null);
});

// ---- the object, open to anybody ---------------------------------------
// The object carries presence for everyone on one tag, and anybody who
// can open a socket can say anything on it. What the object itself
// runs is built in relay.mjs (objectRelay) so that these are tests of
// it rather than of a relay configured to look like it.

const listening = async (relay, n) => {
  const all = [];
  for (let i = 0; i < n; i++) {
    const s = socket();
    relay.open(s);
    await relay.message(s, JSON.stringify(['REQ', 'online', { kinds: [24246], '#t': ['online'] }]));
    all.push(s);
  }
  return all;
};

test('the object carries ephemeral kinds and refuses the rest, with the reason', async () => {
  const relay = objectRelay(verify);
  const a = socket();
  relay.open(a);
  const stored = await note(keys[0], 1000);
  await relay.message(a, JSON.stringify(['EVENT', stored]));
  assert.equal(a.of('OK')[0][2], false);
  assert.match(a.of('OK')[0][3], /^blocked: /);
  await relay.message(a, JSON.stringify(['EVENT', await beat(keys[0])]));
  assert.equal(a.of('OK')[1][2], true);
  assert.equal(relay.stored, 0);
});

test('the object reads nothing bigger than presence ever says, and sends nothing on for it', async () => {
  // Cloudflare hands an object messages of up to 32 MiB, and an event
  // that matches presence goes to every device listening: one message
  // of a few megabytes would be hundreds of megabytes out, and seconds of
  // the one thread every device on the tag shares.
  const relay = objectRelay(verify);
  const [listener] = await listening(relay, 1);
  const a = socket();
  relay.open(a);
  const big = await sign.event(keys[0], { kind: 24246, content: 'x'.repeat(objectLimits.message), tags: [['t', 'online']] });
  await relay.message(a, JSON.stringify(['EVENT', big]));
  assert.equal(listener.of('EVENT').length, 0);
  assert.deepEqual(a.said.at(-1), ['NOTICE', 'too big: over this tag\'s message limit']);

  // Anything inside the limit is taken whole, however far past what
  // presence says it is.
  const large = await sign.event(keys[0], { kind: 24246, content: 'x'.repeat(24 * 1024), tags: [['t', 'online']] });
  await relay.message(a, JSON.stringify(['EVENT', large]));
  assert.equal(a.of('OK').at(-1)[2], true);
  assert.equal(listener.of('EVENT').length, 1);
});

test('the object holds a socket to a burst of events, and then a few a second', async () => {
  let clock = 1_000_000;
  const relay = objectRelay(verify, { now: () => clock });
  const [listener] = await listening(relay, 1);
  const a = socket();
  relay.open(a);
  const { burst } = objectLimits;
  const events = [];
  for (let i = 0; i < burst + 5; i++) events.push(await beat(keys[0], 2000 + i));
  // A beat every five seconds is far inside the burst. A flood is not.
  await Promise.all(events.map((e) => relay.message(a, JSON.stringify(['EVENT', e]))));
  const oks = a.of('OK');
  assert.equal(oks.filter((m) => m[2]).length, burst);
  assert.match(oks.at(-1)[3], /^rate-limited: /);
  assert.equal(listener.of('EVENT').length, burst, 'and what was refused went nowhere');
  // The bucket fills again with time, and another socket has its own.
  clock += 1000;
  await relay.message(a, JSON.stringify(['EVENT', await beat(keys[0], 3000)]));
  assert.equal(a.of('OK').at(-1)[2], true);
  const b = socket();
  relay.open(b);
  await relay.message(b, JSON.stringify(['EVENT', await beat(keys[1], 3001)]));
  assert.equal(b.of('OK')[0][2], true);
});

test('what a socket carries through hibernation stays under what an attachment may hold', async () => {
  // serializeAttachment takes 16 KiB; past that it throws, and the
  // socket would wake from hibernation having lost what it asked for.
  const relay = objectRelay(verify);
  const a = socket();
  relay.open(a);
  const filters = Array.from({ length: 200 }, (_, i) => ({ authors: [`${i}`.padStart(64, 'f')] }));
  await relay.message(a, JSON.stringify(['REQ', 'x'.repeat(1000), ...filters]));
  assert.match(a.said.at(-1)[1], /too big/);
  assert.deepEqual(relay.subscriptionsOf(a), {});
  // A client asking for as much as it may, each as large as it may be.
  for (let i = 0; i < maxSubscriptions + 2; i++) {
    const head = JSON.stringify(['REQ', `s${i}`, { '#t': [''] }]).length;
    await relay.message(a, JSON.stringify(['REQ', `s${i}`, { '#t': ['t'.repeat(objectLimits.request - head)] }]));
  }
  assert.equal(Object.keys(relay.subscriptionsOf(a)).length, maxSubscriptions);
  assert.ok(JSON.stringify(relay.subscriptionsOf(a)).length <= 16384);
  // And presence's own subscription is nowhere near it.
  const b = socket();
  relay.open(b);
  await relay.message(b, JSON.stringify(['REQ', 'online', { kinds: [24246], '#t': ['online'] }]));
  assert.deepEqual(b.said, [['EOSE', 'online']]);
});

test('an event goes out to every listener as the same text, made once', async () => {
  const relay = createRelay({ verify });
  const listeners = await listening(relay, 3);
  const a = socket();
  relay.open(a);
  const mine = await beat(keys[0]);
  await relay.message(a, JSON.stringify(['EVENT', mine]));
  for (const l of listeners) assert.deepEqual(l.of('EVENT'), [['EVENT', 'online', mine]]);
});

test('the operator moves the object\'s limits within their bounds, and no further', () => {
  assert.deepEqual(objectLimitsOf(null), objectLimits);
  for (const [name, [least, most]] of Object.entries(objectLimitBounds)) {
    assert.equal(objectLimitsOf({ [name]: least })[name], least);
    assert.equal(objectLimitsOf({ [name]: most })[name], most);
    for (const bad of [least - 1, most + 1, 1.5, String(most), null]) {
      assert.equal(objectLimitsOf({ [name]: bad })[name], objectLimits[name], `${name} at ${bad}`);
    }
  }
  // Eight REQs of the longest a row may allow still fit the 16 KiB a
  // socket carries through hibernation.
  assert.ok(maxSubscriptions * objectLimitBounds.request[1] <= 16 * 1024 - 2048);
});

test('the row is read from the store, and a store that is down or absent is the defaults', async () => {
  const kv = (row) => ({ get: async (at, kind) => (at === 'config|relay' && kind === 'json' ? row : null) });
  assert.equal((await limitsFrom({ OH_STORE: kv({ burst: 10 }) })).burst, 10);
  assert.deepEqual(await limitsFrom({}), objectLimits);
  assert.deepEqual(await limitsFrom({ OH_STORE: { get: async () => { throw new Error('down'); } } }), objectLimits);
});

test('an object built with the row\'s burst holds a socket to it', async () => {
  const relay = objectRelay(verify, { now: () => 1_000_000, limits: objectLimitsOf({ burst: 5 }) });
  const a = socket();
  relay.open(a);
  for (let i = 0; i < 8; i++) await relay.message(a, JSON.stringify(['EVENT', await beat(keys[0], 2000 + i)]));
  assert.equal(a.of('OK').filter((m) => m[2]).length, 5);
});

// ---- a player's reaction ------------------------------------------------
// A seated player's 👍 (packages/table, reactions.dart) rides the table's
// own tag as an ephemeral kind: carried to the others and to whoever is
// watching, and never written down. Never free text, so the object holds
// it to the shape of one, and to the tag it belongs on.

const table = '0123456789abcdef0123456789abcdef';
const reaction = (key, { tag = table, content = '{"react":"nice","hand":2,"turn":17}', tags = [['t', tag]], at = 1000 } = {}) =>
  sign.event(key, { kind: reactionKind, content, tags, created_at: at });

test("the object's relay takes its logger as the relay does, on every kind of tag", async () => {
  for (const tag of ['online', 'ROOM42', table]) {
    const lines = [];
    const relay = objectRelay(verify, { tag, log: (line) => lines.push(line) });
    relay.open(socket());
    assert.deepEqual(lines, ['connected (1)'], tag);
  }
});

test("a reaction rides a table's tag: carried to whoever reads it there, and kept by nobody", async () => {
  const kept = [];
  const relay = objectRelay(verify, { tag: table, kept: (e) => kept.push(e) });
  const watcher = socket();
  relay.open(watcher);
  await relay.message(watcher, JSON.stringify(['REQ', 'watch', { kinds: [24247, reactionKind], '#t': [table] }]));
  const a = socket();
  relay.open(a);
  const nice = await reaction(keys[0]);
  await relay.message(a, JSON.stringify(['EVENT', nice]));
  assert.deepEqual(a.of('OK')[0], ['OK', nice.id, true, '']);
  assert.deepEqual(watcher.of('EVENT'), [['EVENT', 'watch', nice]]);
  // Forwarded and forgotten: nothing stored, nothing written out, and a
  // screen that arrives later hears nothing of it.
  assert.equal(relay.stored, 0);
  assert.deepEqual(kept, []);
  const late = socket();
  relay.open(late);
  await relay.message(late, JSON.stringify(['REQ', 'watch', { kinds: [reactionKind], '#t': [table] }]));
  assert.deepEqual(late.said, [['EOSE', 'watch']]);
  // Every code a screen knows has the shape.
  for (const code of ['nice', 'ha', 'wow', 'ouch', 'sorry', 'gg']) {
    assert.equal(reactionRefusal(table, { tags: [['t', table]], content: JSON.stringify({ react: code, hand: 0, turn: 52 }) }), null, code);
  }
});

test("a reaction anywhere but its table's tag, tagged otherwise, too big or not the shape of one, is refused and goes nowhere", async () => {
  // Presence, the standings, a pool, a room's code: no table there.
  for (const tag of ['online', 'standings', 'queue:rated:50', 'AB12CD34']) {
    const relay = objectRelay(verify, { tag });
    const a = socket();
    relay.open(a);
    await relay.message(a, JSON.stringify(['EVENT', await reaction(keys[0], { tag })]));
    assert.equal(a.of('OK')[0][2], false, tag);
    assert.match(a.of('OK')[0][3], /^blocked: a reaction rides a table's own tag/, tag);
  }
  const relay = objectRelay(verify, { tag: table });
  const watcher = socket();
  relay.open(watcher);
  await relay.message(watcher, JSON.stringify(['REQ', 'watch', { kinds: [reactionKind], '#t': [table] }]));
  const a = socket();
  relay.open(a);
  const refused = async (options, why) => {
    const e = await reaction(keys[1], options);
    await relay.message(a, JSON.stringify(['EVENT', e]));
    const ok = a.of('OK').at(-1);
    assert.equal(ok[1], e.id);
    assert.equal(ok[2], false, JSON.stringify(options));
    assert.match(ok[3], why, JSON.stringify(options));
  };
  // Tagged for another table, for none, or with something more.
  await refused({ tags: [['t', 'fedcba9876543210fedcba9876543210']] }, /^blocked: /);
  await refused({ tags: [] }, /^blocked: /);
  await refused({ tags: [['t', table], ['p', keys[0].public]] }, /^blocked: /);
  // Too big: a reaction is some thirty characters.
  await refused({ content: JSON.stringify({ react: 'nice', hand: 2, turn: 17, pad: 'x'.repeat(reactionMost) }) }, /^invalid: too big/);
  // Words, or anything else that is not a code and a moment.
  for (const content of [
    'nice',
    'hello, everyone at this table',
    '["nice",2,17]',
    '{"react":"nice","hand":2}',
    '{"react":"nice","hand":2,"turn":17,"text":"hello"}',
    '{"react":"Nice!","hand":2,"turn":17}',
    '{"react":"nice","hand":-1,"turn":17}',
    '{"react":"nice","hand":2,"turn":53}',
    '{"react":"nice","hand":"2","turn":17}',
  ]) {
    await refused({ content }, /^invalid: a reaction is a code/);
  }
  assert.equal(watcher.of('EVENT').length, 0, 'and none of it reached anybody');
  // A forged one is refused before the policy is asked.
  const forged = { ...(await reaction(keys[1])), content: '{"react":"gg","hand":2,"turn":17}' };
  await relay.message(a, JSON.stringify(['EVENT', forged]));
  assert.match(a.of('OK').at(-1)[3], /^invalid: bad id or signature/);
  // And the table's own traffic is untouched by any of it.
  await relay.message(a, JSON.stringify(['EVENT', await sign.event(keys[1], { kind: 24242, content: '{"x":1}', tags: [['t', table]] })]));
  assert.equal(a.of('OK').at(-1)[2], true);
});

test("a flood of reactions is held to the table's rate like anything else a socket says", async () => {
  const relay = objectRelay(verify, { tag: table, now: () => 1_000_000 });
  const a = socket();
  relay.open(a);
  const events = [];
  for (let i = 0; i < tableLimits.burst + 3; i++) events.push(await reaction(keys[0], { at: 1000 + i }));
  await Promise.all(events.map((e) => relay.message(a, JSON.stringify(['EVENT', e]))));
  assert.equal(a.of('OK').filter((m) => m[2]).length, tableLimits.burst);
  assert.match(a.of('OK').at(-1)[3], /^rate-limited: /);
});

test("a socket's line says what kind of tag, as what, how it closed and how long it was open, and nobody's key", () => {
  const table = '83167bb6681da6f1b6f4ab8931028fbb';
  assert.equal(tagLabel('online'), 'presence');
  assert.equal(tagLabel('queue:open:100'), 'queue');
  assert.equal(tagLabel(table), 'table:83167bb6', 'a table by the first eight of its id: its id is its address');
  assert.equal(tagLabel('ABCD2345'), 'room', 'a room code lets anybody in: none of it');
  assert.equal(tagLabel(undefined), 'unknown');

  const device = { account: 'a'.repeat(32), key: 'b'.repeat(64), epoch: 3, until: 9 };
  const house = { account: null, key: 'c'.repeat(64), epoch: 0, until: 9 };
  assert.deepEqual(socketLine('open', { tag: table, sockets: 3 }), { relay: 'open', tag: 'table:83167bb6', as: 'unanswered', sockets: 3 });
  const closed = socketLine('close', { tag: table, who: device, code: 1006, clean: false, why: '', openedAt: 1000, now: 62400, sockets: 2 });
  assert.deepEqual(closed, { relay: 'close', tag: 'table:83167bb6', as: 'device', code: 1006, clean: false, openS: 61, sockets: 2 });
  assert.equal(socketLine('close', { tag: table, who: house, code: 1000, clean: true, sockets: 0 }).as, 'house');
  assert.equal(socketLine('error', { tag: 'online', why: 'x'.repeat(200), sockets: 0 }).why.length, 80);
  for (const line of [closed, socketLine('close', { tag: table, who: house, sockets: 0 })]) {
    const text = JSON.stringify(line);
    for (const secret of [device.account, device.key, house.key, table]) assert.ok(!text.includes(secret), text);
  }
});
