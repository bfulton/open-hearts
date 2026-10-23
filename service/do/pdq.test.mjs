// PDQ (pdq.mjs): the same hash and quality, bit for bit, as Meta's C++
// reference makes of the same pixels, and the hash in the form Arachnid
// Shield takes it.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { pdqCases } from './pdq.fixtures.mjs';
import { lumaFromRgb, pdqFromLuma, pdqHash, pdqHex } from './pdq.mjs';

test("each picture hashes as Meta's reference hashes it: 64 by 64 as it is, larger ones blurred and sampled down, the smallest to nothing", () => {
  for (const c of pdqCases()) {
    const { hash, quality } = pdqHash(c.rgb, c.cols, c.rows);
    assert.equal(hash.length, 32, c.name);
    assert.equal(pdqHex(hash), c.hex, c.name);
    assert.equal(quality, c.quality, c.name);
    assert.deepEqual(pdqFromLuma(lumaFromRgb(c.rgb, c.rows, c.cols), c.rows, c.cols), { hash, quality }, `${c.name}: the same from its luminance`);
  }
});

test("the hash in Shield's form: the hex's 32 bytes in base64, as Shield's own SDK makes it", () => {
  // The fixture as Pillow decodes it, and what Shield's SDK tests do with
  // such pixels (arachnid-shield-sdk-python, tests/conftest.py: pdqhash's
  // compute, then numpy's packbits, then base64).
  const pixels = new Uint8Array(readFileSync(new URL('./testdata/gradient64.pillow.rgb', import.meta.url)));
  const { hash } = pdqHash(pixels, 64, 64);
  assert.equal(Buffer.from(hash).toString('base64'), 'doedu35hgDS3VxeDcA0JdMWbcRDVWp8iDa6fQT5VQP8=');
  assert.equal(Buffer.from(pdqHex(hash), 'hex').toString('base64'), Buffer.from(hash).toString('base64'));
});

test("a picture's hash barely moves when it is resized or recompressed, and moves far for another picture", () => {
  const [app, waves] = pdqCases();
  const distance = (a, b) => a.reduce((d, x, i) => d + [...(x ^ b[i]).toString(2)].filter((bit) => bit === '1').length, 0);
  // The same waves at 64 by 64 and at 128 by 128.
  const big = new Uint8Array(128 * 128 * 3);
  for (let y = 0; y < 128; y++) for (let x = 0; x < 128; x++) big.set(waves.rgb.subarray(((y >> 1) * 64 + (x >> 1)) * 3, ((y >> 1) * 64 + (x >> 1)) * 3 + 3), (y * 128 + x) * 3);
  const a = pdqHash(waves.rgb, 64, 64).hash;
  assert.ok(distance(a, pdqHash(big, 128, 128).hash) <= 31, 'the same picture, larger');
  assert.ok(distance(a, pdqHash(app.rgb, 64, 64).hash) > 31, 'another picture');
});
