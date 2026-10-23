// PhotoDNA's Match call (photodna.mjs): the picture's bytes and the key
// sent, and only an answer with status 3000 and IsMatch taken as one.
//
//   node --test service/functions

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PhotoDnaFailed, photoDnaMatch } from './photodna.mjs';

const endpoint = 'https://photodna.example/Match';
const jpeg = Uint8Array.from([0xff, 0xd8, 0xff, 1, 2]);

/// A fetch that answers [status] with [body] and keeps what it was asked.
function answering(status, body) {
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push({ url, init });
    return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
  };
  return { asked, fetchImpl };
}

test('PhotoDNA: the picture and the key sent; a match and a clear picture read, whatever the case of the fields', async () => {
  const yes = answering(200, { Status: { Code: 3000, Description: 'OK' }, IsMatch: true, TrackingId: 't' });
  assert.equal(await photoDnaMatch(jpeg, { endpoint, key: 'k', fetchImpl: yes.fetchImpl }), true);
  const [{ url, init }] = yes.asked;
  assert.equal(url, endpoint);
  assert.equal(init.method, 'POST');
  assert.equal(init.headers['ocp-apim-subscription-key'], 'k');
  assert.equal(init.headers['content-type'], 'image/jpeg');
  assert.deepEqual(init.body, jpeg);

  const no = answering(200, { status: { code: 3000 }, isMatch: false });
  assert.equal(await photoDnaMatch(jpeg, { endpoint, key: 'k', fetchImpl: no.fetchImpl }), false);
});

test('PhotoDNA: anything but an answer is a failure, never a clear picture', async () => {
  for (const [status, body] of [
    [200, { Status: { Code: 3004 }, IsMatch: false }],
    [200, { Status: { Code: 3000 } }],
    [200, { Status: { Code: 3000 }, IsMatch: 'false' }],
    [401, { Status: { Code: 3000 }, IsMatch: false }],
    [500, 'not json'],
  ]) {
    const { fetchImpl } = answering(status, body);
    await assert.rejects(photoDnaMatch(jpeg, { endpoint, key: 'k', fetchImpl }), PhotoDnaFailed, `${status} ${JSON.stringify(body)}`);
  }
  await assert.rejects(
    photoDnaMatch(jpeg, { endpoint, key: 'k', fetchImpl: async () => { throw new Error('offline'); } }),
    (e) => e instanceof PhotoDnaFailed && /not reached: offline/.test(e.message),
  );
});
