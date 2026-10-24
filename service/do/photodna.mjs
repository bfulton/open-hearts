// Microsoft's PhotoDNA Cloud Service: whether a picture matches a known
// image of child sexual abuse, asked once for each new picture as an
// account first sets it, as Arachnid Shield is, or in its place
// (checkers.mjs, known.mjs). The service is never sent the
// picture: the relay decodes it (jpeg.mjs), makes its PhotoDNA Edge
// Hashes with the module Microsoft licenses to Open Hearts, which is not
// in this repository (photodna_off.mjs), and asks MatchHash about them.

import { Unreadable, jpegPixels } from './jpeg.mjs';

/// The status of an answer that is one.
const ANSWERED = 3000;

/// Where Microsoft's own matches for checking an integration come from:
/// its sample pictures match these, and nobody is ever acted on for one.
export const TEST_SOURCE = 'Test';

/// PhotoDNA not answering whether a picture matches: down, refusing the
/// key, or answering something else. The picture is asked about again.
export class PhotoDnaFailed extends Error {}

/// How [edgeHashes] (the licensed module's: rgb, width, height -> the
/// picture's hashes) hashes a JPEG: decoded first, so that a picture
/// that cannot be decoded, or one too small to hash, throws Unreadable
/// (jpeg.mjs): nothing can be asked of PhotoDNA about either.
export const jpegHasher = (edgeHashes) => (jpeg) => {
  const { width, height, rgb } = jpegPixels(jpeg);
  try {
    return edgeHashes(rgb, width, height);
  } catch (e) {
    if (e?.unhashable) throw new Unreadable(`${width} by ${height} is too small to hash`);
    throw e;
  }
};

/// What PhotoDNA says of the JPEG [jpeg] (its bytes), hashed by [hasher]
/// (jpegHasher) and asked of MatchHash at [endpoint] with [key]:
/// {match, test} — [match] when a hash of it matches a known image,
/// [test] when one matches Microsoft's test pictures. A picture with
/// nothing to hash, one colour, matches nothing. PhotoDnaFailed when the
/// service does not answer for every hash; Unreadable, from [hasher],
/// for a picture that cannot be decoded.
export async function photoDnaMatch(jpeg, { endpoint, key, hasher, fetchImpl = fetch }) {
  const hashes = hasher(jpeg);
  if (!hashes.length) return { match: false, test: false };
  return matchHashes(hashes, { endpoint, key, fetchImpl });
}

/// What MatchHash at [endpoint] says of [hashes] (PhotoDNA Edge Hashes,
/// base64, at most five), with [key]: {match, test}, as photoDnaMatch.
export async function matchHashes(hashes, { endpoint, key, fetchImpl = fetch }) {
  let res;
  try {
    res = await fetchImpl(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'ocp-apim-subscription-key': key },
      body: JSON.stringify(hashes.map((value) => ({ DataRepresentation: 'PreHashV2', Value: value }))),
    });
  } catch (e) {
    throw new PhotoDnaFailed(`PhotoDNA not reached: ${e?.message ?? e}`);
  }
  const body = await res.json().catch(() => null);
  const results = body?.MatchResults;
  if (!res.ok || !Array.isArray(results) || results.length !== hashes.length) {
    throw new PhotoDnaFailed(`PhotoDNA said ${res.status}, ${Array.isArray(results) ? `${results.length} results for ${hashes.length} hashes` : 'no results'}`);
  }
  let match = false;
  let test = false;
  for (const r of results) {
    const code = r?.Status?.Code;
    if (code !== ANSWERED || typeof r.IsMatch !== 'boolean') throw new PhotoDnaFailed(`PhotoDNA said status ${code ?? 'none'} for a hash`);
    if (!r.IsMatch) continue;
    const flags = r.MatchDetails?.MatchFlags;
    if (!Array.isArray(flags) || !flags.length) throw new PhotoDnaFailed('PhotoDNA said a hash matched, and not what it matched');
    for (const f of flags) {
      if (f?.Source === TEST_SOURCE) test = true;
      else match = true;
    }
  }
  return { match, test };
}
