// Pictures to hash for pdq.test.mjs, made the same way every time, and
// what Meta's C++ reference made of each (pdq/cpp in ThreatExchange,
// built as it is and given these same pixels): the hash in its hex and
// the quality.

import { readFileSync } from 'node:fs';

import { jpegPixels } from './jpeg.mjs';

/// Numbers from 0 to 1, the same ones for the same [seed].
function numbers(seed) {
  let s = seed >>> 0;
  return () => (s = (Math.imul(s, 1103515245) + 12345) >>> 0) / 2 ** 32;
}

/// A picture [rows] by [cols], three bytes a pixel, row by row, each
/// byte [at] (x, y, channel) held to 0..255.
function picture(rows, cols, at) {
  const rgb = new Uint8Array(rows * cols * 3);
  for (let y = 0; y < rows; y++) {
    for (let x = 0; x < cols; x++) {
      for (let c = 0; c < 3; c++) rgb[(y * cols + x) * 3 + c] = Math.max(0, Math.min(255, Math.floor(at(x, y, c))));
    }
  }
  return rgb;
}

const waves = (rows, cols) => (x, y, c) => 127.5 + 127.5 * Math.sin((3 * x) / cols * 6.28 + c) * Math.cos((5 * y) / rows * 6.28);

/// Every picture: {name, rows, cols, rgb, hex, quality}.
export function pdqCases() {
  const noise = numbers(7);
  const gradient = jpegPixels(readFileSync(new URL('./testdata/gradient64.jpg', import.meta.url)));
  return [
    // As the app makes them: 64 by 64, which PDQ takes as it is.
    { name: "the app's own kind, decoded", rows: 64, cols: 64, rgb: gradient.rgb, hex: 'ff9bb71b5d2524787a533f01f38dc970a80b0109d65aeae6042754e785d940fd', quality: 17 },
    { name: 'waves, 64 by 64', rows: 64, cols: 64, rgb: picture(64, 64, waves(64, 64)), hex: '08bd57ca22bdff48a835554aaab5a8b5f7482ab74d4888b57bc0a8b5ddc20a37', quality: 100 },
    { name: 'one colour', rows: 64, cols: 64, rgb: picture(64, 64, (x, y, c) => 90 + 40 * c), hex: '2c4b8200000011340000cc531134554b000011342c4b11340000a7a11134cc53', quality: 0 },
    // Larger: blurred and sampled down to 64 by 64 first.
    { name: 'waves, 300 by 200', rows: 300, cols: 200, rgb: picture(300, 200, waves(300, 200)), hex: 'aa3575caddc87dca0237fdca02b502b557420ab5d54aaa35f5c82237d54aaab5', quality: 100 },
    { name: 'noise, 1000 by 37', rows: 1000, cols: 37, rgb: picture(1000, 37, () => noise() * 256), hex: 'f5aeac9c3f2f4394caee116d1af244b2b69330d03522d902b26ce0f666f15d95', quality: 100 },
    { name: 'the smallest that hashes', rows: 5, cols: 5, rgb: picture(5, 5, (x, y, c) => 50 * x + 10 * y + c), hex: '94a5685b96a511a4ce7396256c5b645b6b4ace7329cacb7264d9685b348db7a4', quality: 62 },
    { name: 'too small to hash', rows: 4, cols: 9, rgb: picture(4, 9, (x) => 28 * x), hex: '0'.repeat(64), quality: 0 },
  ];
}
