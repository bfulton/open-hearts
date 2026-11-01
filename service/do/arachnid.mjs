// Arachnid Shield, the Canadian Centre for Child Protection's free
// service for finding known images of child sexual abuse
// (https://projectarachnid.com/): whether a picture matches one, asked
// once for each new picture as an account first sets it, as PhotoDNA
// is, or in its place (checkers.mjs, known.mjs).
// Shield is never sent the picture: the relay decodes it (jpeg.mjs),
// makes its PDQ hash (pdq.mjs), and asks Shield about the hash.

import { base64Of } from '../functions/rows.mjs';
import { jpegPixels } from './jpeg.mjs';
import { pdqHash } from './pdq.mjs';

/// What Shield says a hash matches: known child sexual abuse material;
/// harmful or abusive images of children that are not; Shield's own
/// test pictures, for checking that asking works; or nothing it knows.
export const CSAM = 'csam';
export const HARMFUL = 'harmful-abusive-material';
export const TEST = 'test';
export const NO_MATCH = 'no-known-match';
const SAID = new Set([CSAM, HARMFUL, TEST, NO_MATCH]);

/// The least quality (pdq.mjs) a hash needs to be asked about. Below
/// it the picture is too featureless for its hash to say what it is,
/// and Meta, PDQ's author, recommends not matching it.
export const MIN_QUALITY = 50;

/// Shield not answering what a picture's hash matches: down, refusing
/// the credentials, or answering something else. The picture is asked
/// about again.
export class ShieldFailed extends Error {}

/// The JPEG [jpeg]'s PDQ hash, as Shield takes it (base64 of its 32
/// bytes), and its quality: {hash, quality}. Unreadable (jpeg.mjs) for a
/// picture that cannot be decoded.
export function pictureHash(jpeg) {
  const { width, height, rgb } = jpegPixels(jpeg);
  const { hash, quality } = pdqHash(rgb, width, height);
  return { hash: base64Of(hash), quality };
}

/// The value of an Authorization header for [username] and [password]
/// (RFC 7617, in UTF-8).
const basic = (username, password) => `Basic ${base64Of(new TextEncoder().encode(`${username}:${password}`))}`;

/// What Shield at [endpoint] (its PDQ call) says the PDQ hash [hash]
/// (pictureHash) matches, asked with [username] and [password]: CSAM,
/// HARMFUL, TEST or NO_MATCH. ShieldFailed for anything else.
export async function shieldSays(hash, { endpoint, username, password, fetchImpl = fetch }) {
  let res;
  try {
    res = await fetchImpl(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: basic(username, password) },
      body: JSON.stringify({ hashes: [hash] }),
    });
  } catch (e) {
    throw new ShieldFailed(`Arachnid Shield not reached: ${e?.message ?? e}`);
  }
  const body = await res.json().catch(() => null);
  if (!res.ok) throw new ShieldFailed(`Arachnid Shield said ${res.status}${typeof body?.detail === 'string' ? `: ${body.detail}` : ''}`);
  const scanned = body?.scanned_hashes;
  if (!scanned || typeof scanned !== 'object' || !Object.hasOwn(scanned, hash)) throw new ShieldFailed('Arachnid Shield said nothing of the hash it was asked about');
  // Shield's SDK reads a hash that matches nothing as null.
  const said = scanned[hash] === null ? NO_MATCH : scanned[hash]?.classification;
  if (!SAID.has(said)) throw new ShieldFailed(`Arachnid Shield said ${JSON.stringify(said ?? null)} of a hash`);
  return said;
}
