// What a tag's object keeps, and for how long (tag_store.mjs,
// docs/explanation/relay.md), against a storage that behaves as an
// object's does: keys in order, list by prefix and end, one alarm.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { wasmPath } from './host.mjs';
import { NAME_REFUSED_WHY, PICTURE_IN_AVATAR_WHY, lobbyKind, namesIn, objectRelay, pictureInAvatar, refusalFor, resultsTag, schnorrVerifier, storedKeep } from './relay.mjs';
import { keys, signing } from './sign.mjs';
import { KEPT_MS, SWEEP_EVERY_MS, keyOf, tagStore } from './tag_store.mjs';
import { pictureScreen } from './withheld.mjs';
import { pictureDigest, withholding } from '../functions/pictures.mjs';

const wasm = readFileSync(wasmPath);
const verify = await schnorrVerifier(wasm);
const sign = await signing(wasm);

/// An object's storage, in memory.
function storage() {
  const rows = new Map();
  let alarm = null;
  const sorted = () => [...rows.keys()].sort();
  return {
    rows,
    get alarm() {
      return alarm;
    },
    async get(key) {
      return rows.get(key);
    },
    async put(key, value) {
      rows.set(key, structuredClone(value));
    },
    async delete(key) {
      for (const k of Array.isArray(key) ? key : [key]) rows.delete(k);
    },
    async list({ prefix = '', end = null, limit = Infinity } = {}) {
      const out = new Map();
      for (const k of sorted()) {
        if (out.size >= limit) break;
        if (!k.startsWith(prefix) || (end !== null && k >= end)) continue;
        out.set(k, rows.get(k));
      }
      return out;
    },
    async getAlarm() {
      return alarm;
    },
    async setAlarm(at) {
      alarm = at;
    },
  };
}

const socket = () => ({
  said: [],
  send(text) {
    this.said.push(JSON.parse(text));
  },
  of(what) {
    return this.said.filter((m) => m[0] === what);
  },
});

const lobby = (key, tag, at) => sign.event(key, { kind: lobbyKind, content: `room ${at}`, tags: [['t', tag]], created_at: at });

/// A relay for [tag] as TagRelay builds one, its stored events written
/// to [st] once the writes have settled; [screen], the pictures it
/// withholds (withheld.mjs).
async function built(st, tag, { screen = null } = {}) {
  const kept = tagStore(st, tag);
  const writes = [];
  const relay = objectRelay(verify, {
    tag,
    store: await kept.load(),
    kept: (e, gone) => writes.push(kept.keep(e, gone, { now: 0 })),
    withhold: screen ? (e) => screen.withheld(e) : null,
    forget: (e) => writes.push(kept.forget(e)),
  });
  return { relay, settled: () => Promise.all(writes) };
}

test('the lobby kind is stored under its own tag, and only there', async () => {
  const room = refusalFor('ABCD');
  assert.equal(room({ kind: 24242, tags: [['t', 'ABCD']] }), null);
  assert.equal(room({ kind: lobbyKind, tags: [['t', 'ABCD']] }), null);
  assert.match(room({ kind: lobbyKind, tags: [['t', 'WXYZ']] }), /^blocked: /);
  assert.match(room({ kind: lobbyKind, tags: [] }), /^blocked: /);
  assert.match(room({ kind: 1, tags: [['t', 'ABCD']] }), /^blocked: /);
  // Presence stores nothing, the lobby kind included.
  assert.match(refusalFor('online')({ kind: lobbyKind, tags: [['t', 'online']] }), /^blocked: /);
});

test('nothing that shows the others a name the filter refuses is carried, wherever it names them', () => {
  const room = refusalFor('ABCD');
  const table = refusalFor('a'.repeat(32));
  const said = (kind, content) => ({ kind, tags: [['t', 'ABCD']], content: JSON.stringify(content) });
  const watched = (names) => ({ kind: 24247, tags: [['t', 'a'.repeat(32)]], content: JSON.stringify({ phase: 'play', names }) });
  // Waiting in a room or a pool, a table started or seated, a table watched.
  assert.equal(room(said(24245, { kind: 'here', name: 'Ada' })), null);
  assert.equal(room(said(24245, { kind: 'here', name: 'Sh1t Head' })), NAME_REFUSED_WHY);
  assert.equal(room(said(24245, { kind: 'wait', name: 'f u c k', rating: 1500 })), NAME_REFUSED_WHY);
  assert.equal(room(said(lobbyKind, { kind: 'start', seats: [{ key: 'k', name: 'Ada' }, { bot: 'sam' }] })), null);
  assert.equal(room(said(lobbyKind, { kind: 'start', seats: [{ key: 'k', name: 'Ada' }, { key: 'j', name: 'Fuckface' }] })), NAME_REFUSED_WHY);
  assert.equal(table(watched(['Ada', 'Bao', 'Sam', 'Cy'])), null);
  assert.equal(table(watched(['Ada', 'Bao', 'nazi', 'Cy'])), NAME_REFUSED_WHY);
  // A kind that names nobody is not read for names: a table's own events.
  assert.equal(room(said(24242, { name: 'fuck' })), null);
  // Content that is not JSON, or names nobody, is carried as before.
  assert.equal(room({ kind: 24245, tags: [['t', 'ABCD']], content: 'not json' }), null);
  assert.deepEqual(namesIn(said(lobbyKind, { kind: 'picture', jpeg: 'AAAA' })), []);
  assert.deepEqual(namesIn(said(lobbyKind, { name: 7, seats: [null, { name: 'Ada' }], names: ['Bao', 3] })), ['Ada', 'Bao']);
});

test('a picture travels only as its own event: one inside an avatar, its own or a seat\'s, is not carried', () => {
  const room = refusalFor('ABCD');
  const said = (kind, content) => ({ kind, tags: [['t', 'ABCD']], content: JSON.stringify(content) });
  assert.equal(room(said(24245, { kind: 'here', name: 'Ada', avatar: { icon: 'rocket', color: 2 } })), null);
  assert.equal(room(said(24245, { kind: 'here', name: 'Ada', avatar: { picture: '/9j/4AAQ' } })), PICTURE_IN_AVATAR_WHY);
  assert.equal(room(said(24245, { kind: 'wait', name: 'Ada', avatar: { color: 1, picture: '' } })), PICTURE_IN_AVATAR_WHY);
  assert.equal(room(said(lobbyKind, { kind: 'start', seats: [{ key: 'k', name: 'Ada', avatar: { icon: 'rocket' } }, { bot: 'sam' }] })), null);
  assert.equal(room(said(lobbyKind, { kind: 'match', seats: [{ key: 'k', name: 'Ada', avatar: { picture: '/9j/4AAQ' } }] })), PICTURE_IN_AVATAR_WHY);
  // The one way: a picture of its own.
  assert.equal(room(said(lobbyKind, { kind: 'picture', jpeg: '/9j/4AAQ' })), null);
  assert.equal(pictureInAvatar(said(24242, { avatar: { picture: 'x' } })), false, 'a table\'s own events are not read');
});

test('a name the filter refuses is answered not OK at the object, and neither kept nor passed on', async () => {
  const st = storage();
  const { relay, settled } = await built(st, 'ABCD');
  const a = socket();
  const b = socket();
  relay.open(a);
  relay.open(b);
  await relay.message(b, JSON.stringify(['REQ', 's', { kinds: [lobbyKind], '#t': ['ABCD'] }]));
  const started = (name, at) =>
    sign.event(keys[0], { kind: lobbyKind, content: JSON.stringify({ kind: 'start', seats: [{ key: keys[0].public, name }] }), tags: [['t', 'ABCD']], created_at: at });
  const bad = await started('Sh1t Head', 1000);
  await relay.message(a, JSON.stringify(['EVENT', bad]));
  assert.deepEqual(a.of('OK')[0], ['OK', bad.id, false, NAME_REFUSED_WHY]);
  // The same, named as the others may see: carried and kept.
  const good = await started('Ada', 1001);
  await relay.message(a, JSON.stringify(['EVENT', good]));
  assert.equal(a.of('OK')[1][2], true);
  await settled();
  assert.deepEqual(b.of('EVENT').map((m) => m[2].id), [good.id], 'only the one named as the others may see passed on');
  assert.deepEqual([...st.rows.keys()], [keyOf(good)]);
});

test('a room told to the object is there for whoever asks later, and after the object is evicted', async () => {
  const st = storage();
  const first = await built(st, 'ABCD');
  const a = socket();
  first.relay.open(a);
  const room = await lobby(keys[0], 'ABCD', 1000);
  await first.relay.message(a, JSON.stringify(['EVENT', room]));
  assert.equal(a.of('OK')[0][2], true);
  await first.settled();
  assert.deepEqual([...st.rows.keys()], [keyOf(room)]);
  assert.equal(st.alarm, SWEEP_EVERY_MS);

  // Evicted: a new relay, built from storage alone.
  const again = await built(st, 'ABCD');
  const b = socket();
  again.relay.open(b);
  await again.relay.message(b, JSON.stringify(['REQ', 's', { kinds: [lobbyKind], '#t': ['ABCD'] }]));
  assert.deepEqual(b.of('EVENT').map((m) => m[2].id), [room.id]);
});

test('a picture taken down goes from storage as well, and an object woken from eviction serves it to nobody', async () => {
  const st = storage();
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 5, 5, 5, 5]).toString('base64');
  let row = null;
  const screen = pictureScreen({ read: () => row, everyMs: 0 });
  const first = await built(st, 'ABCD', { screen });
  const a = socket();
  first.relay.open(a);
  const room = await lobby(keys[0], 'ABCD', 1000);
  const picture = await sign.event(keys[1], { kind: lobbyKind, content: JSON.stringify({ kind: 'picture', jpeg }), tags: [['t', 'ABCD']], created_at: 1001 });
  for (const e of [room, picture]) await first.relay.message(a, JSON.stringify(['EVENT', e]));
  await first.settled();
  assert.deepEqual([...st.rows.keys()], [keyOf(room), keyOf(picture)]);

  // Taken down while the object was evicted: woken, it has the picture
  // in storage, and lets go of it before serving anyone.
  row = withholding(null, await pictureDigest(jpeg), Date.now());
  const again = await built(st, 'ABCD', { screen });
  const b = socket();
  again.relay.open(b);
  await again.relay.message(b, JSON.stringify(['REQ', 's', { kinds: [lobbyKind], '#t': ['ABCD'] }]));
  assert.deepEqual(b.of('EVENT').map((m) => m[2].id), [room.id]);
  await again.settled();
  assert.deepEqual([...st.rows.keys()], [keyOf(room)]);
});

test('a day on, the sweep deletes what is a day old and leaves the rest', async () => {
  const st = storage();
  const kept = tagStore(st, 'ABCD');
  const now = 10 * KEPT_MS;
  const old = await lobby(keys[0], 'ABCD', Math.floor((now - KEPT_MS) / 1000) - 1);
  const fresh = await lobby(keys[1], 'ABCD', Math.floor((now - KEPT_MS) / 1000) + 1);
  await kept.keep(old, null, { now: 0 });
  await kept.keep(fresh, null, { now: 0 });
  assert.equal(await kept.sweep({ now }), true);
  assert.deepEqual([...st.rows.keys()], [keyOf(fresh)]);
  assert.equal(st.alarm, now + SWEEP_EVERY_MS);
  // Nothing left to go: no change, and once empty, no further alarm.
  assert.equal(await kept.sweep({ now }), false);
  await st.setAlarm(null);
  assert.equal(await kept.sweep({ now: now + 2 * KEPT_MS }), true);
  assert.equal(st.rows.size, 0);
  assert.equal(st.alarm, null);
});

test('the tag kept for good is the one the table package publishes results on', () => {
  // Ratings are folded from every result (packages/table, results.dart),
  // so a result swept with the day's rooms is a rating that changes.
  const dart = readFileSync(new URL('../../packages/table/lib/src/results.dart', import.meta.url), 'utf8');
  const published = dart.match(/static const tag = '([^']+)';/)?.[1];
  assert.ok(published, 'GameResult.tag in results.dart');
  assert.equal(resultsTag, published);
});

test('results are kept for good: no sweep, and storage keeps what memory lets go of', async () => {
  const st = storage();
  const kept = tagStore(st, resultsTag);
  const result = await lobby(keys[0], resultsTag, 1000);
  const later = await lobby(keys[1], resultsTag, 2000);
  await kept.keep(result, null, { now: 0 });
  await kept.keep(later, result, { now: 0 });
  assert.equal(st.alarm, null);
  assert.equal(st.rows.size, 2);
  assert.equal(await kept.sweep({ now: 100 * KEPT_MS }), false);
  assert.equal(st.rows.size, 2);
  // What is loaded is the newest the memory holds.
  assert.equal(storedKeep(resultsTag), 20000);
  assert.equal((await kept.load()).size, 2);
});

test('a room\'s object lets the oldest go from storage as it lets it go from memory', async () => {
  const st = storage();
  const kept = tagStore(st, 'ABCD');
  const a = await lobby(keys[0], 'ABCD', 1000);
  const b = await lobby(keys[1], 'ABCD', 2000);
  await kept.keep(a, null, { now: 0 });
  await kept.keep(b, a, { now: 0 });
  assert.deepEqual([...st.rows.keys()], [keyOf(b)]);
});

test('presence keeps nothing, in memory or in storage', async () => {
  const st = storage();
  const kept = tagStore(st, 'online');
  assert.equal(await kept.load(), null);
  assert.equal(await kept.sweep({ now: 0 }), false);
});
