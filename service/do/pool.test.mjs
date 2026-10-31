// A pool's object (pool.mjs) in the relay that runs it, with no sockets
// in the way:
//
//   node --test service/do/pool.test.mjs
//
// How the house seats a pool is Dart's, and tested there over a real
// socket to this relay (service/test/waiting_room_test.dart). Here is
// what the pool's object is held to: a seating from anybody but its
// house goes to nobody, and somebody waiting wakes the house while it is
// away, and only then.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { wasmPath } from './host.mjs';
import { NOT_THE_HOUSE_WHY, poolWantsMs, waitingKind } from './pool.mjs';
import { lobbyKind, memoryStore, objectRelay, schnorrVerifier, serviceGate } from './relay.mjs';
import { keys, signing } from './sign.mjs';

const wasm = readFileSync(wasmPath);
const verify = await schnorrVerifier(wasm);
const sign = await signing(wasm);

const [ada, bao, house, service] = keys;
const pool = 'queue:unrated';

/// A socket that keeps what it was told, in order.
const socket = () => ({
  said: [],
  send(text) {
    this.said.push(JSON.parse(text));
  },
  of(what) {
    return this.said.filter((m) => m[0] === what);
  },
});

const say = (relay, from, event) => relay.message(from, JSON.stringify(['EVENT', event]));
const ok = (from) => from.of('OK').at(-1);
const listen = (relay, s, tag = pool) => relay.message(s, JSON.stringify(['REQ', 'p', { kinds: [lobbyKind, waitingKind], '#t': [tag] }]));

/// A seating of the pool, as the house says one (packages/table,
/// matching.dart, PoolHost), said by [author].
const seating = (author, { tag = pool, at = 1000 } = {}) =>
  sign.event(author, { kind: lobbyKind, content: JSON.stringify({ kind: 'match', round: 1, table: 'ab'.repeat(16), seats: [] }), tags: [['t', tag]], created_at: at });

/// [key]'s device saying it is waiting in the pool.
const waiting = (key, at = 1000) =>
  sign.event(key, { kind: waitingKind, content: JSON.stringify({ kind: 'wait', name: 'W', rating: 1500, since: 1 }), tags: [['t', pool]], created_at: at });

function clock(at = 1_000_000) {
  const c = () => c.at;
  c.at = at;
  return c;
}

/// The gate of a deployed relay whose service is [service]'s key and
/// whose house is [house], on the clock [now].
const gateOn = (now) => serviceGate({ service: service.public, verify, house: house.public, now });

/// An activation the service gives [key]'s device, good until [until]
/// (service/functions/licence.mjs, activationFor).
async function activationFor(key, until) {
  const account = key.public.slice(0, 32);
  const statement = `oh-active/1\n${account}\n${key.public}\n1\n${until}`;
  const digest = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(statement))).toString('hex');
  return { account, key: key.public, epoch: 1, until, sig: sign.over(service, digest) };
}

/// [s], open on [relay], answering its challenge as [key]: the house by
/// its key alone, anybody else with an activation good for an hour of
/// the clock [at].
async function answerAs(relay, s, key, at) {
  const tags = key === house ? [] : [['activation', JSON.stringify(await activationFor(key, Math.floor(at() / 1000) + 3600))]];
  const e = await sign.event(key, { kind: 22242, tags: [['challenge', s.of('AUTH').at(-1)[1]], ...tags], created_at: Math.floor(at() / 1000) });
  await relay.message(s, JSON.stringify(['AUTH', e]));
  assert.equal(ok(s)[2], true, ok(s)[3]);
}

test("a pool's seating is its house's: anybody else's is answered as taken, and goes to nobody", async () => {
  const relay = objectRelay(verify, { tag: pool, house: house.public });
  const reader = socket();
  const stranger = socket();
  relay.open(reader);
  relay.open(stranger);
  await listen(relay, reader);
  await say(relay, stranger, await seating(bao));
  assert.deepEqual(ok(stranger).slice(2), [true, NOT_THE_HOUSE_WHY], 'taken, so its device is not held out for it');
  assert.equal(reader.of('EVENT').length, 0, 'carried to nobody');
  assert.equal(relay.stored, 0, 'and kept by nobody');
  // A seating that names this relay's house, said by somebody else, is
  // still somebody else's.
  await say(relay, stranger, await seating(ada, { at: 1001 }));
  assert.equal(ok(stranger)[3], NOT_THE_HOUSE_WHY);
  // The house's is carried and kept.
  const theirs = await seating(house);
  await say(relay, stranger, theirs);
  assert.deepEqual(ok(stranger).slice(2), [true, '']);
  assert.deepEqual(reader.of('EVENT').map((m) => m[2].id), [theirs.id]);
  assert.equal(relay.stored, 1);
  // Whatever else a pool carries is anybody's: a picture, a beat.
  const picture = await sign.event(bao, { kind: lobbyKind, content: JSON.stringify({ kind: 'picture', jpeg: '' }), tags: [['t', pool]], created_at: 1002 });
  await say(relay, stranger, picture);
  await say(relay, stranger, await waiting(bao));
  assert.equal(reader.of('EVENT').length, 3);
});

test("with no house, a pool's seating is nobody's; and a seating is a pool's business alone", async () => {
  const relay = objectRelay(verify, { tag: pool });
  const s = socket();
  relay.open(s);
  await say(relay, s, await seating(house));
  assert.equal(ok(s)[3], NOT_THE_HOUSE_WHY);
  // A room's tag is not a pool's: what it carries is its own.
  const room = objectRelay(verify, { tag: 'ROOM42', house: house.public });
  const r = socket();
  room.open(r);
  await say(room, r, await seating(bao, { tag: 'ROOM42' }));
  assert.deepEqual(ok(r).slice(2), [true, '']);
});

test("a seating kept from before is let go of once the pool's house is the only one that seats it", async () => {
  // Stored by an object from before this one: a seating a device of
  // the old way said, the day it said it.
  const store = memoryStore(100);
  const old = await seating(bao, { at: 1000 });
  store.add(old);
  const forgotten = [];
  const relay = objectRelay(verify, { tag: pool, house: house.public, store, forget: (e) => forgotten.push(e.id) });
  const reader = socket();
  relay.open(reader);
  await listen(relay, reader);
  assert.equal(reader.of('EVENT').length, 0, 'served to nobody');
  assert.deepEqual(forgotten, [old.id], 'and let go of where it was kept');
  assert.equal(relay.stored, 0);
});

test('somebody waiting in a pool wants the house while it is away, and not once it is there', async () => {
  const now = clock();
  const wanted = { n: 0 };
  const relay = objectRelay(verify, { tag: pool, house: house.public, now, gate: gateOn(now), wanted: () => wanted.n++ });
  const device = socket();
  relay.open(device);
  await answerAs(relay, device, ada, now);
  // A picture put out for whoever is seated with its player is not
  // somebody saying they wait.
  await say(relay, device, await sign.event(ada, { kind: lobbyKind, content: JSON.stringify({ kind: 'picture', jpeg: '' }), tags: [['t', pool]], created_at: Math.floor(now() / 1000) }));
  assert.equal(wanted.n, 0);
  assert.equal(relay.wantsHouse, false, 'nobody waiting yet');
  await say(relay, device, await waiting(ada, Math.floor(now() / 1000)));
  assert.equal(wanted.n, 1, 'waiting, and the house away');
  assert.equal(relay.wantsHouse, true);
  // The house comes.
  const theHouse = socket();
  relay.open(theHouse);
  await answerAs(relay, theHouse, house, now);
  assert.equal(relay.wantsHouse, false, 'the house is here');
  now.at += 2000;
  await say(relay, device, await waiting(ada, Math.floor(now() / 1000)));
  assert.equal(wanted.n, 1, 'and not wanted while it is');
  // The house's socket goes: wanted at the next word from somebody
  // waiting.
  relay.close(theHouse);
  assert.equal(relay.wantsHouse, true);
  now.at += 2000;
  await say(relay, device, await waiting(ada, Math.floor(now() / 1000)));
  assert.equal(wanted.n, 2);
  // Nobody says they are waiting for a while: nobody is, and the house
  // is not wanted.
  now.at += poolWantsMs;
  assert.equal(relay.wantsHouse, false, 'nobody heard waiting lately');
});

test("a friends' room's members waiting is the room's business, and wants no house", async () => {
  const wanted = { n: 0 };
  const room = objectRelay(verify, { tag: 'ROOM42', house: house.public, wanted: () => wanted.n++ });
  const r = socket();
  room.open(r);
  const here = await sign.event(ada, { kind: waitingKind, content: JSON.stringify({ kind: 'here' }), tags: [['t', 'ROOM42']], created_at: 1000 });
  await say(room, r, here);
  assert.equal(wanted.n, 0, 'nothing for the house to seat');
  assert.equal(room.wantsHouse, false);
});
