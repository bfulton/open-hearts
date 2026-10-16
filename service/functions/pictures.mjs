// A picture the operator took off an account (suspension.mjs, remove)
// is withheld by the relay wherever it was published, not left there
// for the day the relay keeps a lobby (docs/how-to/suspend-an-account.md).
// The relay cannot be told where: a picture goes to every pool and room
// its account waited in, from any of its devices. So the picture is
// named instead, by the SHA-256 of its JPEG, in one row every relay
// object reads (service/do/withheld.mjs), and withheld wherever it
// turns up: on its way in, and in what a tag's object already holds.
// A device that still has the picture, and puts it out again before it
// takes the change, is withheld the same way.

/// Where the list is kept: `config|pictures`, {pictures: [{sha256,
/// until}]}, `until` in milliseconds.
export const PICTURES_ROW = ['config', 'pictures'];

/// How long a picture taken off is withheld, unless it is put back
/// first: longer than the relay keeps any lobby event (a day, and an
/// hour for its sweep; service/do/tag_store.mjs), and long enough that
/// a device of the account left unopened for a while takes the change
/// before it can put the picture out again.
export const WITHHELD_FOR_MS = 30 * 24 * 60 * 60 * 1000;

/// What a publisher is told of a picture the relay took and keeps to
/// itself: taken, so that a device is not counted as refused for it
/// (packages/table, relays.dart), and said why for whoever reads it.
export const WITHHELD_WHY = 'withheld: this picture was taken down';

const toHex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');

/// The SHA-256 of the JPEG [base64] encodes, in hex: of the bytes, so
/// that two spellings of the same picture are one. Null for anything
/// that is not base64.
export async function pictureDigest(base64) {
  if (typeof base64 !== 'string' || !base64) return null;
  let bytes;
  try {
    bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
  return toHex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
}

/// The picture a lobby event's [content] carries — a pool's or a
/// room's, `{"kind":"picture","jpeg":…}` (packages/table, matching.dart;
/// app/lib/net/room.dart) — or null.
export function pictureIn(content) {
  if (typeof content !== 'string' || !content.includes('"picture"')) return null;
  try {
    const said = JSON.parse(content);
    return said?.kind === 'picture' && typeof said.jpeg === 'string' ? said.jpeg : null;
  } catch {
    return null;
  }
}

/// The digests [row] withholds at [now].
export function withheldOf(row, now = Date.now()) {
  const found = new Set();
  for (const p of Array.isArray(row?.pictures) ? row.pictures : []) {
    if (typeof p?.sha256 === 'string' && /^[0-9a-f]{64}$/.test(p.sha256) && Number(p.until) > now) found.add(p.sha256);
  }
  return found;
}

/// [row] withholding [digest] from [now] for [WITHHELD_FOR_MS], and
/// with what has run out gone.
export function withholding(row, digest, now = Date.now()) {
  const kept = (Array.isArray(row?.pictures) ? row.pictures : []).filter((p) => Number(p?.until) > now && p.sha256 !== digest);
  return { pictures: [...kept, { sha256: digest, until: now + WITHHELD_FOR_MS }] };
}

/// [row] no longer withholding [digest], and with what has run out
/// gone.
export function releasing(row, digest, now = Date.now()) {
  return { pictures: (Array.isArray(row?.pictures) ? row.pictures : []).filter((p) => Number(p?.until) > now && p.sha256 !== digest) };
}
