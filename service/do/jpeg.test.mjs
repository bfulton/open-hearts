// A picture's pixels for its PhotoDNA hash (jpeg.mjs): a JPEG as the
// app makes them decoded to plain RGB, and anything else, or anything
// too large, Unreadable.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { Unreadable, jpegPixels } from './jpeg.mjs';

/// Our own 64 by 64 picture, as the app's are: red rising to the right
/// and green downwards, four a pixel, on blue 128 (made with jpeg-js's
/// encoder at quality 90).
const gradient = readFileSync(new URL('./testdata/gradient64.jpg', import.meta.url));

/// [jpeg] with the size its frame says it is made [width] by [height].
function sized(jpeg, width, height) {
  const out = Uint8Array.from(jpeg);
  for (let i = 0; i + 8 < out.length; i++) {
    if (out[i] === 0xff && out[i + 1] === 0xc0) {
      out.set([height >> 8, height & 0xff, width >> 8, width & 0xff], i + 5);
      return out;
    }
  }
  throw new Error('no frame');
}

test('a JPEG decoded to three bytes a pixel, row by row', () => {
  const { width, height, rgb } = jpegPixels(gradient);
  assert.equal(width, 64);
  assert.equal(height, 64);
  assert.ok(rgb instanceof Uint8Array);
  assert.equal(rgb.length, 64 * 64 * 3);
  const near = (x, y, want) => {
    const at = (y * 64 + x) * 3;
    rgb.slice(at, at + 3).forEach((v, i) => assert.ok(Math.abs(v - want[i]) <= 8, `${x},${y}: ${[...rgb.slice(at, at + 3)]} for ${want}`));
  };
  near(0, 0, [0, 0, 128]);
  near(63, 0, [252, 0, 128]);
  near(0, 63, [0, 252, 128]);
  near(40, 20, [160, 80, 128]);
});

test('anything but a JPEG, or one too large, is Unreadable', () => {
  for (const [what, bytes] of [
    ['nothing', new Uint8Array()],
    ['not a JPEG', Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])],
    ['only its start', gradient.subarray(0, 4)],
    ['cut short', gradient.subarray(0, 300)],
    ['more than a million pixels', sized(gradient, 1200, 1000)],
  ]) {
    assert.throws(() => jpegPixels(bytes), (e) => e instanceof Unreadable && /^not a picture that can be read: /.test(e.message), what);
  }
  assert.throws(() => jpegPixels(sized(gradient, 1200, 1000)), /maxResolutionInMP limit exceeded/, 'refused for its size, before it is decoded');
  assert.equal(jpegPixels(sized(gradient, 64, 64)).width, 64, 'sized() changes only the size');
});
