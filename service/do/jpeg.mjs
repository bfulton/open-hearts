// A picture's pixels, for its PDQ hash (arachnid.mjs, pdq.mjs) and its
// PhotoDNA Edge Hashes (photodna.mjs): the JPEG an account set, decoded
// by jpeg-js (vendor/jpeg-js), as plain RGB.

import decode from './vendor/jpeg-js/decoder.js';

/// A picture that cannot be decoded, or hashed: nothing can be asked
/// about it, so it is never shown (known.mjs).
export class Unreadable extends Error {}

/// The most a picture may have to be decoded, in millions of pixels:
/// far more than the app's 64 by 64 (app/lib/avatar.dart), and little
/// enough that no picture of 12,000 bytes can make the decoder take
/// much memory.
const MOST_MEGAPIXELS = 1;

/// The pixels of the JPEG [bytes]: {width, height, rgb}, three bytes a
/// pixel, row by row. Unreadable for anything else, or anything larger.
export function jpegPixels(bytes) {
  try {
    const { width, height, data } = decode(bytes, { useTArray: true, formatAsRGBA: false, maxResolutionInMP: MOST_MEGAPIXELS, maxMemoryUsageInMB: 16 });
    if (!(width > 0 && height > 0) || data.length !== width * height * 3) throw new Error(`${width} by ${height} with ${data.length} bytes`);
    return { width, height, rgb: data };
  } catch (e) {
    throw new Unreadable(`not a picture that can be read: ${e?.message ?? e}`);
  }
}
