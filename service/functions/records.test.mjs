// What the bucket keeps (records.mjs): a record its own player sent,
// once, packed, and given back as it was.

import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { test } from 'node:test';

import { keepRecord, recordMost, recordResponse } from './records.mjs';

const TABLE = '0123456789abcdef0123456789abcdef';
const ADA = 'a'.repeat(64);
const BAO = 'b'.repeat(64);
const CY = 'c'.repeat(64);

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

const record = (table = TABLE) =>
  JSON.stringify({ v: 1, spec: { id: table, seed: 1, seats: [{ key: ADA }, { key: BAO }, { bot: 'Romeo' }, { bot: 'Juliet' }] }, record: [] });

test('a player at the table sends its record, and it is kept packed, once', async () => {
  const b = bucket();
  const text = record();
  assert.deepEqual(await keepRecord(b, ADA, TABLE, text), { status: 200, body: { kept: true } });
  const kept = b.kept.get(`tables/${TABLE}.json`);
  assert.equal(gunzipSync(kept.body).toString(), text);
  assert.equal(kept.meta.contentEncoding, 'gzip');
  assert.ok(kept.body.length < text.length * 2);
  // Another player's copy: the first is the one kept.
  assert.deepEqual(await keepRecord(b, BAO, TABLE, record()), { status: 200, body: { kept: true, already: true } });
  assert.equal(b.kept.size, 1);
});

test('only a player at that table, with that table\'s record, of a game\'s size', async () => {
  const b = bucket();
  assert.equal((await keepRecord(b, CY, TABLE, record())).status, 403, 'not seated there');
  assert.equal((await keepRecord(b, ADA, 'ROOM-1-2', record('ROOM-1-2'))).status, 400, 'not a table id');
  assert.equal((await keepRecord(b, ADA, TABLE, record('f'.repeat(32)))).status, 400, 'another table\'s');
  assert.equal((await keepRecord(b, ADA, TABLE, 'not json')).status, 400);
  assert.equal((await keepRecord(b, ADA, TABLE, JSON.stringify({ v: 2, spec: { id: TABLE } }))).status, 400);
  assert.equal((await keepRecord(b, ADA, TABLE, ' '.repeat(recordMost + 1))).status, 413);
  assert.equal((await keepRecord(null, ADA, TABLE, record())).status, 503, 'no bucket bound');
  assert.equal(b.kept.size, 0);
});

test('a kept record comes back as it was sent, packed and for good; none is a 404', async () => {
  const b = bucket();
  await keepRecord(b, ADA, TABLE, record());
  const res = await recordResponse(b, TABLE);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-encoding'), 'gzip');
  assert.match(res.headers.get('cache-control'), /immutable/);
  assert.equal(gunzipSync(Buffer.from(await res.arrayBuffer())).toString(), record());
  assert.equal((await recordResponse(b, 'f'.repeat(32))).status, 404);
  assert.equal((await recordResponse(b, 'nope')).status, 400);
});
