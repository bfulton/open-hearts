// Arachnid Shield's PDQ call (arachnid.mjs): a picture's PDQ hash and
// the credentials sent, never the picture, and only an answer for that
// hash, in Shield's own classes, taken as one.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { CSAM, HARMFUL, NO_MATCH, ShieldFailed, TEST, pictureHash, shieldSays } from './arachnid.mjs';
import { Unreadable } from './jpeg.mjs';
import { pdqCases } from './pdq.fixtures.mjs';

const endpoint = 'https://shield.example/v1/pdq';
const shield = (fetchImpl) => ({ endpoint, username: 'user', password: 'pass', fetchImpl });
const HASH = 'doedu35hgDS3VxeDcA0JdMWbcRDVWp8iDa6fQT5VQP8=';

/// A fetch that answers [status] with [body] and keeps what it was asked.
function answering(status, body) {
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push({ url, init });
    return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
  };
  return { asked, fetchImpl };
}

test("a picture's hash: its PDQ hash, the 32 bytes in base64, and its quality; Unreadable for one that cannot be decoded", () => {
  const jpeg = readFileSync(new URL('./testdata/gradient64.jpg', import.meta.url));
  const [decoded] = pdqCases();
  assert.deepEqual(pictureHash(jpeg), { hash: Buffer.from(decoded.hex, 'hex').toString('base64'), quality: decoded.quality });
  assert.throws(() => pictureHash(Uint8Array.from([1, 2, 3])), Unreadable);
});

test('the hash and the credentials sent; each of Shield\'s classes read as it is', async () => {
  const yes = answering(200, { scanned_hashes: { [HASH]: { classification: CSAM, match_type: 'near', near_match_details: [] } } });
  assert.equal(await shieldSays(HASH, shield(yes.fetchImpl)), CSAM);
  const [{ url, init }] = yes.asked;
  assert.equal(url, endpoint);
  assert.equal(init.method, 'POST');
  assert.equal(init.headers['content-type'], 'application/json');
  assert.equal(init.headers.authorization, `Basic ${Buffer.from('user:pass').toString('base64')}`);
  assert.deepEqual(JSON.parse(init.body), { hashes: [HASH] });

  for (const said of [HARMFUL, TEST, NO_MATCH]) {
    const { fetchImpl } = answering(200, { scanned_hashes: { [HASH]: { classification: said, match_type: null } } });
    assert.equal(await shieldSays(HASH, shield(fetchImpl)), said);
  }
  // As Shield's own SDK reads it: a hash that matches nothing, null.
  const none = answering(200, { scanned_hashes: { [HASH]: null } });
  assert.equal(await shieldSays(HASH, shield(none.fetchImpl)), NO_MATCH);

  // Credentials beyond Latin-1, in UTF-8.
  const utf8 = answering(200, { scanned_hashes: { [HASH]: null } });
  await shieldSays(HASH, { endpoint, username: 'ü', password: 'ß€', fetchImpl: utf8.fetchImpl });
  assert.equal(utf8.asked[0].init.headers.authorization, `Basic ${Buffer.from('ü:ß€', 'utf8').toString('base64')}`);
});

test('anything but an answer for the hash asked about is a failure, never a clear picture', async () => {
  for (const [status, body, said] of [
    [401, { detail: 'please supply your API username and password in the Authorization header' }, /said 401: please supply/],
    [503, 'not json', /said 503$/],
    [200, 'not json', /nothing of the hash/],
    [200, {}, /nothing of the hash/],
    [200, { scanned_hashes: null }, /nothing of the hash/],
    [200, { scanned_hashes: { other: null } }, /nothing of the hash/],
    [200, { scanned_hashes: { [HASH]: {} } }, /said null of a hash/],
    [200, { scanned_hashes: { [HASH]: { classification: 'CSAM' } } }, /said "CSAM" of a hash/],
    [200, { scanned_hashes: { [HASH]: { classification: 'something-new' } } }, /said "something-new"/],
    [200, { scanned_hashes: { [HASH]: 'csam' } }, /said null of a hash/],
  ]) {
    const { fetchImpl } = answering(status, body);
    await assert.rejects(shieldSays(HASH, shield(fetchImpl)), (e) => e instanceof ShieldFailed && said.test(e.message), `${status} ${JSON.stringify(body)}`);
  }
  await assert.rejects(
    shieldSays(HASH, shield(async () => { throw new Error('offline'); })),
    (e) => e instanceof ShieldFailed && /not reached: offline/.test(e.message),
  );
});
