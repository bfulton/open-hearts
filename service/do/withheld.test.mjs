// A picture the operator took down, kept back by the tag's object that
// has it (withheld.mjs; service/functions/pictures.mjs): never stored
// or passed on once the list names it, let go of when it was already
// held, and the device that put it out not counted as refused.
//
//   node --test service/do/withheld.test.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { WITHHELD_FOR_MS, WITHHELD_WHY, pictureDigest, withholding } from '../functions/pictures.mjs';
import { wasmPath } from './host.mjs';
import { lobbyKind, objectRelay, presenceTag, resultsTag, schnorrVerifier } from './relay.mjs';
import { keys, signing } from './sign.mjs';
import { KEPT_MS, SWEEP_EVERY_MS } from './tag_store.mjs';
import { SCREEN_EVERY_MS, pictureScreen } from './withheld.mjs';

const wasm = readFileSync(wasmPath);
const verify = await schnorrVerifier(wasm);
const sign = await signing(wasm);

const pool = 'queue:anyone';

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

/// Two small "pictures", as base64 of their bytes.
const taken = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString('base64');
const other = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 9, 8, 7]).toString('base64');

/// [key]'s picture put out under [tag], as a pool or a room puts it.
const picture = (key, jpeg, { tag = pool, at = 1000 } = {}) =>
  sign.event(key, { kind: lobbyKind, content: JSON.stringify({ kind: 'picture', jpeg }), tags: [['t', tag]], created_at: at });
const seating = (key, at = 1000) => sign.event(key, { kind: lobbyKind, content: JSON.stringify({ kind: 'match', seats: [] }), tags: [['t', pool]], created_at: at });

/// The list's row, naming [jpegs], as the account's turn writes it.
async function listing(...jpegs) {
  let row = null;
  for (const j of jpegs) row = withholding(row, await pictureDigest(j), Date.now());
  return row;
}

test('a picture on the list is taken and kept to itself: not stored, not passed on, and its sender not refused; any other goes as before', async () => {
  const row = await listing(taken);
  const screen = pictureScreen({ read: () => row });
  const relay = objectRelay(verify, { tag: pool, withhold: (e) => screen.withheld(e) });
  const sender = socket();
  const waiting = socket();
  relay.open(sender);
  relay.open(waiting);
  await relay.message(waiting, JSON.stringify(['REQ', 'lobby', { kinds: [lobbyKind], '#t': [pool] }]));

  const down = await picture(keys[0], taken);
  await relay.message(sender, JSON.stringify(['EVENT', down]));
  assert.deepEqual(sender.of('OK')[0], ['OK', down.id, true, WITHHELD_WHY], 'taken, so the app does not hold it against this relay');
  assert.equal(relay.stored, 0);
  assert.equal(waiting.of('EVENT').length, 0);

  const fine = await picture(keys[1], other);
  const seat = await seating(keys[1]);
  await relay.message(sender, JSON.stringify(['EVENT', fine]));
  await relay.message(sender, JSON.stringify(['EVENT', seat]));
  assert.deepEqual(sender.of('OK').slice(1).map((m) => m[2]), [true, true]);
  assert.deepEqual(waiting.of('EVENT').map((m) => m[2].id), [fine.id, seat.id]);
  assert.equal(relay.stored, 2);
});

test('a picture already held when the list names it is let go of before anyone is served, and the object forgets its copy', async () => {
  let row = null;
  const forgotten = [];
  const screen = pictureScreen({ read: () => row, everyMs: 0 });
  const relay = objectRelay(verify, { tag: pool, withhold: (e) => screen.withheld(e), forget: (e) => forgotten.push(e.id) });
  const sender = socket();
  relay.open(sender);
  const down = await picture(keys[0], taken, { at: 1000 });
  const kept = await picture(keys[1], other, { at: 1001 });
  const seat = await seating(keys[1], 1002);
  for (const e of [down, kept, seat]) await relay.message(sender, JSON.stringify(['EVENT', e]));
  assert.equal(relay.stored, 3, 'before the operator took it down');

  // Taken down: the next to ask is served everything but it.
  row = await listing(taken);
  const late = socket();
  relay.open(late);
  await relay.message(late, JSON.stringify(['REQ', 'lobby', { kinds: [lobbyKind], '#t': [pool] }]));
  assert.deepEqual(late.said.map((m) => (m[0] === 'EVENT' ? m[2].id : m[0])), [kept.id, seat.id, 'EOSE'], 'the history, then its end');
  assert.equal(relay.stored, 2);
  assert.deepEqual(forgotten, [down.id]);
  // Put out again while it is on the list: kept back again.
  await relay.message(sender, JSON.stringify(['EVENT', down]));
  assert.deepEqual(sender.of('OK').at(-1), ['OK', down.id, true, WITHHELD_WHY]);
  // Put back, as after a counter-notice: the same event is taken and
  // held again, not answered as one the relay already has.
  row = null;
  await relay.message(sender, JSON.stringify(['EVENT', down]));
  assert.deepEqual(sender.of('OK').at(-1), ['OK', down.id, true, '']);
  assert.equal(relay.stored, 3);
});

test('two sockets screening the same history at once let a picture go once', async () => {
  let listed = false;
  let answer;
  const asked = new Promise((resolve) => (answer = resolve));
  const forgotten = [];
  const counted = [];
  const relay = objectRelay(verify, {
    tag: pool,
    count: (what) => counted.push(what),
    withhold: async () => (listed ? (await asked, WITHHELD_WHY) : null),
    forget: (e) => forgotten.push(e.id),
  });
  const sender = socket();
  relay.open(sender);
  const down = await picture(keys[0], taken);
  await relay.message(sender, JSON.stringify(['EVENT', down]));
  listed = true;
  const askers = [socket(), socket()];
  for (const s of askers) relay.open(s);
  const both = Promise.all(askers.map((s) => relay.message(s, JSON.stringify(['REQ', 'lobby', { kinds: [lobbyKind], '#t': [pool] }]))));
  // Both are screening it before either is answered.
  await new Promise(setImmediate);
  answer();
  await both;
  assert.deepEqual(forgotten, [down.id]);
  assert.equal(counted.filter((what) => what === 'withheld').length, 1);
  for (const s of askers) assert.deepEqual(s.said, [['EOSE', 'lobby']]);
});

test('the list is read at most once a minute, only when a picture comes by; a read that fails leaves the last one', async () => {
  let clock = 0;
  let reads = 0;
  let row = await listing(taken);
  let failing = false;
  const screen = pictureScreen({
    read: async () => {
      reads++;
      if (failing) throw new Error('store out of reach');
      return row;
    },
    now: () => clock,
  });
  assert.equal(await screen.withheld(await seating(keys[0])), null);
  const down = await picture(keys[0], taken);
  // Only the lobby's picture is one: the same words in a heartbeat are not.
  assert.equal(await screen.withheld({ ...down, kind: 24245 }), null);
  assert.equal(reads, 0, 'nothing read for what is not a picture');
  // Asked about at once by two sockets: one read.
  assert.deepEqual(await Promise.all([screen.withheld(down), screen.withheld(down)]), [WITHHELD_WHY, WITHHELD_WHY]);
  assert.equal(reads, 1);
  // Put back, as after a counter-notice: still withheld within the minute,
  // and not after it.
  row = null;
  clock += SCREEN_EVERY_MS - 1;
  assert.equal(await screen.withheld(down), WITHHELD_WHY);
  assert.equal(reads, 1);
  clock += 1;
  assert.equal(await screen.withheld(down), null);
  assert.equal(reads, 2);
  // Taken down again, then the store out of reach: the list in hand stands.
  row = await listing(taken);
  clock += SCREEN_EVERY_MS;
  assert.equal(await screen.withheld(down), WITHHELD_WHY);
  failing = true;
  clock += SCREEN_EVERY_MS;
  assert.equal(await screen.withheld(down), WITHHELD_WHY);
  assert.equal(reads, 4);
});

test('a picture is the same picture however its base64 is spelled; a listing runs out', async () => {
  const unpadded = taken.replace(/=+$/, '');
  assert.notEqual(unpadded, taken, 'a spelling of its own');
  assert.equal(await pictureDigest(unpadded), await pictureDigest(taken));
  assert.equal(await pictureDigest('not base64!'), null);
  const at = Date.now();
  let clock = at;
  const screen = pictureScreen({ read: () => withholding(null, '0'.repeat(64), at), now: () => clock, everyMs: 0 });
  const listed = await pictureScreen({ read: async () => withholding(null, await pictureDigest(taken), at), now: () => clock }).withheld(await picture(keys[0], unpadded));
  assert.equal(listed, WITHHELD_WHY);
  assert.equal(await screen.withheld(await picture(keys[0], taken)), null);
  // Past its time, nothing is withheld; and its time outlasts every copy
  // the relay keeps.
  clock = at + WITHHELD_FOR_MS;
  assert.equal(
    await pictureScreen({ read: async () => withholding(null, await pictureDigest(taken), at), now: () => clock }).withheld(await picture(keys[0], taken)),
    null,
  );
  assert.ok(WITHHELD_FOR_MS > KEPT_MS + SWEEP_EVERY_MS);
});

test('presence and the results are never screened: no picture is put out there', async () => {
  for (const tag of [presenceTag, resultsTag]) {
    let asked = 0;
    const relay = objectRelay(verify, { tag, withhold: () => (asked++, WITHHELD_WHY) });
    const s = socket();
    relay.open(s);
    await relay.message(s, JSON.stringify(['EVENT', await picture(keys[0], taken, { tag })]));
    await relay.message(s, JSON.stringify(['REQ', 'x', { kinds: [lobbyKind] }]));
    assert.equal(asked, 0, tag);
  }
});
