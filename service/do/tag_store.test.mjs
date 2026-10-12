// What a tag's object keeps, and for how long (tag_store.mjs,
// docs/explanation/relay.md), against a storage that behaves as an
// object's does: keys in order, list by prefix and end, one alarm.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { wasmPath } from './host.mjs';
import { lobbyKind, objectRelay, refusalFor, resultsTag, schnorrVerifier, storedKeep } from './relay.mjs';
import { keys, signing } from './sign.mjs';
import { KEPT_MS, SWEEP_EVERY_MS, keyOf, tagStore } from './tag_store.mjs';

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
/// to [st] once the writes have settled.
async function built(st, tag) {
  const kept = tagStore(st, tag);
  const writes = [];
  const relay = objectRelay(verify, { tag, store: await kept.load(), kept: (e, gone) => writes.push(kept.keep(e, gone, { now: 0 })) });
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
