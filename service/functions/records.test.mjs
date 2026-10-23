// What the bucket keeps (records.mjs): a record its own player sent,
// once, packed, and given back as it was.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { gunzipSync, gzipSync } from 'node:zlib';
import { test } from 'node:test';

import { keys } from '../do/sign.mjs';
import { NotAsSent, anonymizeGames, eventIdOf, forgottenKey, keepRecord, keptGames, markForgotten, recordMost, recordResponse } from './records.mjs';
import { licenceFor, signerOn } from './licence.mjs';

// Devices that can sign: BIP-340's published pairs, the second skipped
// as the worker's tests skip it (it is their service's own).
const [ada, , bao] = keys;
const ADA = ada.public;
const BAO = bao.public;
const CY = 'c'.repeat(64);
const TABLE = '0123456789abcdef0123456789abcdef';
const signer = await signerOn(await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url)));
const keep = (bucket, key, table, text) => keepRecord(bucket, key, table, text, { verify: signer.verify });

/// An event [pair] says at [table], made as the table makes one
/// (packages/table, events.dart): its id the hash of what it says.
async function said(pair, kind, body, table = TABLE) {
  const event = { table, author: pair.public, kind, body };
  const id = await eventIdOf(table, event);
  return { id, author: pair.public, kind, body, sig: signer.sign(pair.secret, id) };
}

/// A game's record, as its players send it: a play each from Ada and
/// Bao.
const game = {
  v: 2,
  spec: { id: TABLE, seed: 1, seats: [{ key: ADA }, { key: BAO }, { bot: 'Romeo' }, { bot: 'Juliet' }] },
  record: [
    { turn: [0, 4], event: await said(ada, 'play', { hand: 0, turn: 4, seat: 0, card: '2C' }), witnesses: [BAO] },
    { turn: [0, 5], event: await said(bao, 'play', { hand: 0, turn: 5, seat: 1, card: '3C' }), witnesses: [ADA] },
  ],
};

/// An R2 bucket in memory: head, get, put, and a listing a page of one
/// at a time, as R2's binding lists, with each object's custom metadata
/// when it is asked for.
function bucket() {
  const kept = new Map();
  return {
    kept,
    read: [],
    async head(key) {
      return kept.has(key) ? { key } : null;
    },
    async get(key) {
      this.read.push(key);
      const k = kept.get(key);
      return k ? { body: new Blob([k.body]).stream(), httpMetadata: k.meta, customMetadata: k.custom } : null;
    },
    async put(key, body, options) {
      kept.set(key, { body: Buffer.from(typeof body === 'string' ? body : new Uint8Array(body)), meta: options.httpMetadata, custom: options.customMetadata });
    },
    async list({ prefix, cursor, include = [] }) {
      const all = [...kept.keys()].filter((k) => k.startsWith(prefix)).sort();
      const at = cursor ? all.indexOf(cursor) : 0;
      const key = all[at];
      const objects = key === undefined ? [] : [{ key, ...(include.includes('customMetadata') ? { customMetadata: kept.get(key).custom } : {}) }];
      return { objects, truncated: at + 1 < all.length, cursor: all[at + 1] };
    },
  };
}

/// The game's record as its players send it, or with [change] made to
/// a copy first.
const record = (change = (r) => r) => JSON.stringify(change(structuredClone(game)));

test('an event\'s id is worked out here as the table works it out', async () => {
  // A real game, every event in it made by the Dart table.
  const real = JSON.parse(gunzipSync(await readFile(new URL('../../packages/table/test/fixtures/sealed_three_leave.json.gz', import.meta.url))).toString());
  const ids = await Promise.all(real.record.map((d) => eventIdOf(real.spec.id, d.event)));
  assert.deepEqual(ids, real.record.map((d) => d.event.id));
  assert.ok(ids.length > 50);
});

test('a player at the table sends its record, and it is kept packed, once', async () => {
  const b = bucket();
  const text = record();
  assert.deepEqual(await keep(b, ADA, TABLE, text), { status: 200, body: { kept: true } });
  const kept = b.kept.get(`tables/${TABLE}.json`);
  assert.equal(gunzipSync(kept.body).toString(), text);
  assert.equal(kept.meta.contentEncoding, 'gzip');
  assert.ok(kept.body.length < text.length * 2);
  // Another player's copy: the first is the one kept.
  assert.deepEqual(await keep(b, BAO, TABLE, record()), { status: 200, body: { kept: true, already: true } });
  assert.equal(b.kept.size, 1);
});

test('only a player at that table, with that table\'s record, of a game\'s size', async () => {
  const b = bucket();
  assert.equal((await keep(b, CY, TABLE, record())).status, 403, 'not seated there');
  const named = (table) => record((r) => ({ ...r, spec: { ...r.spec, id: table } }));
  assert.equal((await keep(b, ADA, 'ROOM-1-2', named('ROOM-1-2'))).status, 400, 'not a table id');
  assert.equal((await keep(b, ADA, TABLE, named('f'.repeat(32)))).status, 400, 'another table\'s');
  assert.equal((await keep(b, ADA, TABLE, 'not json')).status, 400);
  assert.equal((await keep(b, ADA, TABLE, JSON.stringify({ v: 2, spec: { id: TABLE } }))).status, 400);
  // The form before, whose removals named their backers by key alone.
  assert.deepEqual(await keep(b, ADA, TABLE, record((r) => ({ ...r, v: 1 }))), { status: 400, body: { error: 'a record of form 2' } });
  assert.equal((await keep(b, ADA, TABLE, ' '.repeat(recordMost + 1))).status, 413);
  assert.equal((await keep(null, ADA, TABLE, record())).status, 503, 'no bucket bound');
  assert.equal(b.kept.size, 0);
});

test('only a record with moves its sender signed at that table in it', async () => {
  const b = bucket();
  // Somebody's key written into a seat of a game they never played:
  // nothing in it is theirs.
  const seated = record((r) => ({ ...r, spec: { ...r.spec, seats: r.spec.seats.map((s, i) => (i === 0 ? { key: CY } : s)) } }));
  assert.equal((await keep(b, CY, TABLE, seated)).status, 403, 'seated, but none of it signed by them');
  // Their own events, each said differently from what they signed.
  const changed = record((r) => {
    for (const d of r.record) if (d.event.author === ADA) d.event.body = { ...d.event.body, hand: d.event.body.hand + 1 };
    return r;
  });
  assert.equal((await keep(b, ADA, TABLE, changed)).status, 403, 'not what was signed');
  // Their own events, with signatures that are not theirs.
  const forged = record((r) => {
    for (const d of r.record) if (d.event.author === ADA) d.event.sig = 'ab'.repeat(64);
    return r;
  });
  assert.equal((await keep(b, ADA, TABLE, forged)).status, 403, 'not signed by them');
  assert.equal(b.kept.size, 0);
  assert.equal((await keep(b, ADA, TABLE, record())).status, 200, 'and the game as it was is kept');
});

test('where the service signs licences, only seats the app would show: each person\'s licensed for its key, each account once', async () => {
  // The worker's tests' service: BIP-340's second pair.
  const [other, service] = keys;
  const by = (pair) => ({ signer, secret: pair.secret, service: pair.public });
  const keepChecked = (text) => keepRecord(bucket(), ADA, TABLE, text, { verify: signer.verify, service: service.public });
  const A = 'a'.repeat(32);
  const B = 'b'.repeat(32);
  const adas = await licenceFor(ADA, A, '2026-11-01', by(service));
  const baos = await licenceFor(BAO, B, '2026-11-01', by(service));
  const seated = (bao) => record((r) => {
    r.spec.seats[0].licence = adas;
    if (bao) r.spec.seats[1].licence = bao;
    return r;
  });
  for (const [text, error, what] of [
    [record(), 'seat 0 has no licence for its key', 'none at all'],
    [seated(null), 'seat 1 has no licence for its key', 'none at one seat'],
    [seated(adas), 'seat 1 has no licence for its key', 'another device\'s'],
    [seated({ ...baos, account: A }), 'seat 1 has no licence for its key', 'changed after it was signed'],
    [seated({ ...baos, sig: 'ab' }), 'seat 1 has no licence for its key', 'not a signature'],
    [seated(await licenceFor(BAO, B, '2026-11-01', by(other))), 'seat 1 has no licence for its key', 'another service\'s'],
    [seated(await licenceFor(BAO, A, '2026-11-01', by(service))), 'seat 1 is an account already seated', 'one account at two seats'],
  ]) {
    assert.deepEqual(await keepChecked(text), { status: 403, body: { error } }, what);
  }
  assert.deepEqual(await keepChecked(seated(baos)), { status: 200, body: { kept: true } });
  // Not its date: a game is read, and sent, after licences run out.
  assert.deepEqual(await keepChecked(seated(await licenceFor(BAO, B, '2020-01-01', by(service)))), { status: 200, body: { kept: true } });
});

test('a kept record comes back as it was sent, packed and for good; none is a 404', async () => {
  const b = bucket();
  await keep(b, ADA, TABLE, record());
  const res = await recordResponse(b, TABLE);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-encoding'), 'gzip');
  assert.match(res.headers.get('cache-control'), /immutable/);
  assert.equal(gunzipSync(Buffer.from(await res.arrayBuffer())).toString(), record());
  assert.equal((await recordResponse(b, 'f'.repeat(32))).status, 404);
  assert.equal((await recordResponse(b, 'nope')).status, 400);
});

test('a game sent after an account was forgotten is kept without its name', async () => {
  const FORGOTTEN = 'f'.repeat(32);
  const OTHER = 'e'.repeat(32);
  const licence = (key, account) => ({ key, account, until: '2026-11-01', plan: 'annual', sig: '00'.repeat(64) });
  // Bao's seat is the forgotten account's: it played on while its last
  // licence ran, and Ada's device sends the game.
  const licensed = (r) => {
    r.spec.seats[0].licence = licence(ADA, OTHER);
    r.spec.seats[1].licence = licence(BAO, FORGOTTEN);
    r.names = { 0: 'Ada', 1: 'Bao' };
    return r;
  };
  const b = bucket();
  b.kept.set(forgottenKey(FORGOTTEN), { body: Buffer.from('{}') });
  assert.deepEqual(await keep(b, ADA, TABLE, record(licensed)), { status: 200, body: { kept: true } });
  const kept = JSON.parse(gunzipSync(b.kept.get(`tables/${TABLE}.json`).body).toString());
  assert.deepEqual(kept.names, { 0: 'Ada' });
  assert.deepEqual({ ...kept, names: undefined }, { ...JSON.parse(record(licensed)), names: undefined }, 'the rest as it was sent');

  // Only Bao named, and Bao forgotten: no names at all.
  const b2 = bucket();
  b2.kept.set(forgottenKey(FORGOTTEN), { body: Buffer.from('{}') });
  await keep(b2, ADA, TABLE, record((r) => ({ ...licensed(r), names: { 1: 'Bao' } })));
  assert.equal('names' in JSON.parse(gunzipSync(b2.kept.get(`tables/${TABLE}.json`).body).toString()), false);

  // Nobody forgotten, or the forgotten seat unnamed: kept as it was sent,
  // byte for byte, written however the device wrote it.
  const spaced = JSON.stringify(licensed(structuredClone(game)), null, 1);
  const b3 = bucket();
  await keep(b3, ADA, TABLE, spaced);
  assert.equal(gunzipSync(b3.kept.get(`tables/${TABLE}.json`).body).toString(), spaced);
  const b4 = bucket();
  b4.kept.set(forgottenKey(FORGOTTEN), { body: Buffer.from('{}') });
  const unnamed = JSON.stringify({ ...licensed(structuredClone(game)), names: { 0: 'Ada' } }, null, 1);
  await keep(b4, ADA, TABLE, unnamed);
  assert.equal(gunzipSync(b4.kept.get(`tables/${TABLE}.json`).body).toString(), unnamed);

  // A forgotten name in a record JSON.stringify would not give back as
  // it was sent: refused, not kept with the name nor rewritten.
  const b5 = bucket();
  b5.kept.set(forgottenKey(FORGOTTEN), { body: Buffer.from('{}') });
  assert.equal((await keep(b5, ADA, TABLE, spaced)).status, 422);
  assert.equal(b5.kept.has(`tables/${TABLE}.json`), false);
});

test('a game is kept without a name the filter refuses, the rest as it was sent', async () => {
  const named = (names) => (r) => ({ ...r, names });
  const b = bucket();
  assert.deepEqual(await keep(b, ADA, TABLE, record(named({ 0: 'Ada', 1: 'Sh1t Head' }))), { status: 200, body: { kept: true } });
  const kept = JSON.parse(gunzipSync(b.kept.get(`tables/${TABLE}.json`).body).toString());
  assert.deepEqual(kept.names, { 0: 'Ada' });
  assert.deepEqual({ ...kept, names: undefined }, { ...JSON.parse(record(named({}))), names: undefined });
  // None left: no names at all.
  const b2 = bucket();
  await keep(b2, ADA, TABLE, record(named({ 1: 'f u c k' })));
  assert.equal('names' in JSON.parse(gunzipSync(b2.kept.get(`tables/${TABLE}.json`).body).toString()), false);
  // Every name one the others may see: kept byte for byte.
  const b3 = bucket();
  const fine = record(named({ 0: 'Ada', 1: 'Cassandra' }));
  await keep(b3, ADA, TABLE, fine);
  assert.equal(gunzipSync(b3.kept.get(`tables/${TABLE}.json`).body).toString(), fine);
});

test('a kept game notes the accounts at its seats, and the worker reads only the games that name the one being deleted', async () => {
  const A = 'a'.repeat(32);
  const B = 'b'.repeat(32);
  const b = bucket();
  const kept = (r) => JSON.parse(gunzipSync(b.kept.get(`tables/${r}.json`).body).toString());
  // Ada's and Bao's game, kept as a player sends it: its accounts noted.
  await keep(b, ADA, TABLE, record((r) => {
    r.spec.seats[0].licence = { key: ADA, account: A };
    r.spec.seats[1].licence = { key: BAO, account: B };
    return { ...r, names: { 0: 'Ada', 1: 'Bao' } };
  }));
  assert.deepEqual(b.kept.get(`tables/${TABLE}.json`).custom, { from: ADA, accounts: `${A},${B}` });
  // A game kept before accounts were noted, one of Bao's alone, and one
  // of Ada's that would not be written back as it was sent.
  const put = (id, text, custom) => b.put(`tables/${id}.json`, gzipSync(text), { httpMetadata: { contentType: 'application/json', contentEncoding: 'gzip' }, customMetadata: custom });
  const seated = (id, accounts, names) => JSON.stringify({ v: 2, spec: { id, seats: accounts.map((account, i) => ({ key: `${i}`.repeat(64), licence: { account } })) }, record: [], names });
  await put('before', seated('before', [B, A], { 0: 'Bao', 1: 'Ada' }), { from: BAO });
  await put('baos', seated('baos', [B], { 0: 'Bao' }), { from: BAO, accounts: B });
  await put('odd', '{"v":2,"spec":{"id":"odd","seats":[{"licence":{"account":"' + A + '"}}]},"record":[{"at":2.0}],"names":{"0":"Ada"}}', { from: ADA, accounts: A });
  const refused = [];
  b.read.length = 0;
  const changed = await anonymizeGames(keptGames(b), A, { refused: (key) => refused.push(key) });
  assert.deepEqual(changed, [{ key: `tables/${TABLE}.json`, named: [0] }, { key: 'tables/before.json', named: [1] }]);
  assert.deepEqual(refused, ['tables/odd.json'], 'one it would not write back is said, and the rest go on');
  assert.ok(!b.read.includes('tables/baos.json'), 'a game noted without the account is never read');
  assert.deepEqual(kept(TABLE).names, { 1: 'Bao' });
  assert.deepEqual(kept('before').names, { 0: 'Bao' });
  assert.deepEqual(kept('baos').names, { 0: 'Bao' });
  // Rewritten as it is kept: packed, said so, with what was noted beside
  // it, and now the accounts too where a game had none.
  assert.equal(b.kept.get(`tables/${TABLE}.json`).meta.contentEncoding, 'gzip');
  assert.deepEqual(b.kept.get(`tables/${TABLE}.json`).custom, { from: ADA, accounts: `${A},${B}` });
  assert.deepEqual(b.kept.get('tables/before.json').custom, { from: BAO, accounts: `${B},${A}` });
  // Without [refused], such a game stops the run, as for the operator.
  await assert.rejects(anonymizeGames(keptGames(b), A), NotAsSent);
});

test('an account marked forgotten from the worker is marked once', async () => {
  const b = bucket();
  const A = 'a'.repeat(32);
  await markForgotten(b, A, { now: Date.parse('2026-10-19T12:00:00Z') });
  assert.deepEqual(JSON.parse(b.kept.get(forgottenKey(A)).body.toString()), { forgotten: '2026-10-19' });
  await markForgotten(b, A, { now: Date.parse('2026-10-20T12:00:00Z') });
  assert.deepEqual(JSON.parse(b.kept.get(forgottenKey(A)).body.toString()), { forgotten: '2026-10-19' }, 'the first day stays');
});
