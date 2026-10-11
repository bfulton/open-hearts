// What the bucket keeps (records.mjs): a record its own player sent,
// once, packed, and given back as it was.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { gunzipSync } from 'node:zlib';
import { test } from 'node:test';

import { keys } from '../do/sign.mjs';
import { eventIdOf, keepRecord, recordMost, recordResponse } from './records.mjs';
import { signerOn } from './worker.mjs';

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
  v: 1,
  spec: { id: TABLE, seed: 1, seats: [{ key: ADA }, { key: BAO }, { bot: 'Romeo' }, { bot: 'Juliet' }] },
  record: [
    { turn: [0, 4], event: await said(ada, 'play', { hand: 0, turn: 4, seat: 0, card: '2C' }), witnesses: [BAO] },
    { turn: [0, 5], event: await said(bao, 'play', { hand: 0, turn: 5, seat: 1, card: '3C' }), witnesses: [ADA] },
  ],
};

/// An R2 bucket in memory: head, get, put.
function bucket() {
  const kept = new Map();
  return {
    kept,
    async head(key) {
      return kept.has(key) ? { key } : null;
    },
    async get(key) {
      const k = kept.get(key);
      return k ? { body: new Blob([k.body]).stream(), httpMetadata: k.meta } : null;
    },
    async put(key, body, options) {
      kept.set(key, { body: Buffer.from(body), meta: options.httpMetadata, custom: options.customMetadata });
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
