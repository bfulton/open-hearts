// PDQ, Meta's perceptual hash of a picture: 256 bits that stay nearly
// the same when the picture is resized, recompressed or slightly
// altered, and a quality from 0 to 100 that says how much there is in
// the picture to hash. Arachnid Shield is asked about a picture by its
// PDQ hash (arachnid.mjs), so the picture itself never leaves the relay.
//
// A port of the C++ reference in Meta's ThreatExchange repository
// (pdq/cpp: hashing/pdqhashing.cpp, downscaling/downscaling.cpp,
// hashing/torben.cpp), Copyright (c) Meta Platforms, Inc. and
// affiliates, under the BSD licence in pdq.LICENSE.txt; the median is
// Torben Mogensen's, public domain. The reference works in single
// precision, and so does this, every step rounded as the reference
// rounds it (f), so that given the same pixels it makes the same hash,
// bit for bit (pdq.test.mjs holds it to hashes the reference made).

const f = Math.fround;

/// Standard RGB to luminance, as the reference has it.
const LUMA_R = f(0.299);
const LUMA_G = f(0.587);
const LUMA_B = f(0.114);

/// Smaller than this either way, a picture hashes to nothing.
const MIN_HASHABLE_DIM = 5;

/// Box-filter passes that make the reference's tent filter.
const JAROSZ_PASSES = 2;

/// The DCT's 16 by 64 matrix, row-major: slots 1 to 16 of a 64-point
/// DCT-II, each scaled as the reference scales it.
const DCT = (() => {
  const d = new Float32Array(16 * 64);
  const scale = f(Math.sqrt(2 / 64));
  for (let i = 0; i < 16; i++) {
    for (let j = 0; j < 64; j++) d[i * 64 + j] = scale * Math.cos((Math.PI / 2 / 64) * (i + 1) * (2 * j + 1));
  }
  return d;
})();

/// The luminance of [rgb], three bytes a pixel, row by row.
export function lumaFromRgb(rgb, rows, cols) {
  const luma = new Float32Array(rows * cols);
  for (let k = 0; k < rows * cols; k++) {
    luma[k] = f(f(f(LUMA_R * rgb[3 * k]) + f(LUMA_G * rgb[3 * k + 1])) + f(LUMA_B * rgb[3 * k + 2]));
  }
  return luma;
}

/// The PDQ hash of the picture [rgb] (three bytes a pixel, row by row)
/// [width] by [height]: {hash, quality}, [hash] the 32 bytes of the
/// hash as the reference writes it in hex.
export function pdqHash(rgb, width, height) {
  return pdqFromLuma(lumaFromRgb(rgb, height, width), height, width);
}

/// The PDQ hash of the luminance [luma] (row-major, [rows] by [cols]),
/// as pdqHash.
export function pdqFromLuma(luma, rows, cols) {
  if (rows < MIN_HASHABLE_DIM || cols < MIN_HASHABLE_DIM) return { hash: new Uint8Array(32), quality: 0 };
  const image = Float32Array.from(luma);
  let small;
  if (rows === 64 && cols === 64) {
    small = image;
  } else {
    jaroszFilter(image, new Float32Array(rows * cols), rows, cols, windowSize(cols, 64), windowSize(rows, 64));
    small = decimate(image, rows, cols, 64, 64);
  }
  const quality = qualityOf(small);
  const dct = dct64To16(small);
  const median = torben(dct);
  const words = new Uint16Array(16);
  for (let k = 0; k < 256; k++) if (dct[k] > median) words[k >> 4] |= 1 << (k & 15);
  // The reference's hex: the sixteen words, last first, each high byte
  // first.
  const hash = new Uint8Array(32);
  for (let w = 0; w < 16; w++) {
    hash[2 * w] = words[15 - w] >> 8;
    hash[2 * w + 1] = words[15 - w] & 0xff;
  }
  return { hash, quality };
}

/// [hash] as the reference writes it: 64 hex digits.
export const pdqHex = (hash) => Array.from(hash, (b) => b.toString(16).padStart(2, '0')).join('');

/// The box filter's window for scaling [oldDimension] to [newDimension].
const windowSize = (oldDimension, newDimension) => Math.trunc((oldDimension + 2 * newDimension - 1) / (2 * newDimension));

/// Blurs [buffer1] in place, with [buffer2] to work in: box filters
/// along the rows and then the columns, twice over.
function jaroszFilter(buffer1, buffer2, rows, cols, windowAlongRows, windowAlongCols) {
  for (let pass = 0; pass < JAROSZ_PASSES; pass++) {
    for (let i = 0; i < rows; i++) box1D(buffer1, buffer2, i * cols, cols, 1, windowAlongRows);
    for (let j = 0; j < cols; j++) box1D(buffer2, buffer1, j, rows, cols, windowAlongCols);
  }
}

/// A moving average of [length] values from [start] in steps of
/// [stride], [window] wide, centred, narrower at the ends.
function box1D(input, output, start, length, stride, window) {
  const half = Math.trunc((window + 2) / 2);
  const phase1 = half - 1;
  const phase2 = window - half + 1;
  const phase3 = length - window;
  const phase4 = half - 1;
  let li = start;
  let ri = start;
  let oi = start;
  let sum = 0;
  let current = 0;
  for (let i = 0; i < phase1; i++) {
    sum = f(sum + input[ri]);
    current++;
    ri += stride;
  }
  for (let i = 0; i < phase2; i++) {
    sum = f(sum + input[ri]);
    current++;
    output[oi] = f(sum / current);
    ri += stride;
    oi += stride;
  }
  for (let i = 0; i < phase3; i++) {
    sum = f(sum + input[ri]);
    sum = f(sum - input[li]);
    output[oi] = f(sum / current);
    li += stride;
    ri += stride;
    oi += stride;
  }
  for (let i = 0; i < phase4; i++) {
    sum = f(sum - input[li]);
    current--;
    output[oi] = f(sum / current);
    li += stride;
    oi += stride;
  }
}

/// [input] sampled at the centres of an [outRows] by [outCols] grid.
function decimate(input, inRows, inCols, outRows, outCols) {
  const out = new Float32Array(outRows * outCols);
  for (let i = 0; i < outRows; i++) {
    const ini = Math.trunc(((i + 0.5) * inRows) / outRows);
    for (let j = 0; j < outCols; j++) {
      const inj = Math.trunc(((j + 0.5) * inCols) / outCols);
      out[i * outCols + j] = input[ini * inCols + inj];
    }
  }
  return out;
}

/// How much there is in the 64 by 64 picture to hash, from 0 to 100:
/// its significant gradients, summed and scaled as the reference does.
function qualityOf(b) {
  let sum = 0;
  const gradient = (u, v) => Math.abs(Math.trunc(f(f(f(u - v) * 100) / 255)));
  for (let i = 0; i < 63; i++) for (let j = 0; j < 64; j++) sum += gradient(b[i * 64 + j], b[(i + 1) * 64 + j]);
  for (let i = 0; i < 64; i++) for (let j = 0; j < 63; j++) sum += gradient(b[i * 64 + j], b[i * 64 + j + 1]);
  return Math.min(100, Math.trunc(sum / 90));
}

/// Slots 1 to 16 by 1 to 16 of the 64 by 64 picture [a]'s 2D DCT:
/// DCT a DCTᵀ, summed in the reference's order.
function dct64To16(a) {
  const t = new Float32Array(16 * 64);
  for (let i = 0; i < 16; i++) {
    for (let j = 0; j < 64; j++) {
      let sum = 0;
      for (let k = 0; k < 64; k++) sum = f(sum + f(DCT[i * 64 + k] * a[k * 64 + j]));
      t[i * 64 + j] = sum;
    }
  }
  const b = new Float32Array(256);
  for (let i = 0; i < 16; i++) {
    for (let j = 0; j < 16; j++) {
      let sum = 0;
      for (let k = 0; k < 64; k++) sum = f(sum + f(t[i * 64 + k] * DCT[j * 64 + k]));
      b[i * 16 + j] = sum;
    }
  }
  return b;
}

/// The median of [m], by Torben Mogensen's method, as the reference
/// takes it.
function torben(m) {
  const n = m.length;
  let min = m[0];
  let max = m[0];
  for (let i = 1; i < n; i++) {
    if (m[i] < min) min = m[i];
    if (m[i] > max) max = m[i];
  }
  let less;
  let greater;
  let equal;
  let guess;
  let maxltguess;
  let mingtguess;
  const half = Math.trunc((n + 1) / 2);
  for (;;) {
    guess = f(f(min + max) / 2);
    less = 0;
    greater = 0;
    equal = 0;
    maxltguess = min;
    mingtguess = max;
    for (let i = 0; i < n; i++) {
      if (m[i] < guess) {
        less++;
        if (m[i] > maxltguess) maxltguess = m[i];
      } else if (m[i] > guess) {
        greater++;
        if (m[i] < mingtguess) mingtguess = m[i];
      } else {
        equal++;
      }
    }
    if (less <= half && greater <= half) break;
    if (less > greater) max = maxltguess;
    else min = mingtguess;
  }
  if (less >= half) return maxltguess;
  if (less + equal >= half) return guess;
  return mingtguess;
}
