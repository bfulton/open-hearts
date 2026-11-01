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
//
// The automatic check hides a picture on the same list (service/do/
// review.mjs); one the operator puts back after it is listed as allowed,
// so that the check does not hide it again.

import { bytesOf64, hex } from './rows.mjs';

/// Where the list is kept: `config|pictures`, {pictures: [{sha256,
/// until}], allowed: [{sha256, until}]}, `until` in milliseconds;
/// `allowed` only when something is.
export const PICTURES_ROW = ['config', 'pictures'];

/// Where each picture an account sets is kept, for the operator to look
/// at and act on (service/do/profile_pictures.mjs): one object for each
/// account and picture, `account/<account>/<digest>.jpg`, the picture's
/// bytes, and in its metadata all that is known of it: when the account
/// first set it (`at`), when it last did (`last`), what the model made
/// of it (`check`), what was said of it against known images of child
/// sexual abuse (`known`) and, once a checker said it, which one did and
/// when, its receipt (`knownBy`, `knownAt`; service/do/checkers.mjs),
/// when the operator was emailed it (`told`), and, once it is no longer
/// the account's picture, since when (`ended`). A copy cleared before
/// copies kept receipts was cleared by Arachnid Shield, the only
/// checker there was. The account's picture now is the one it set last,
/// unless that one says it has ended: the account took it off, or was
/// deleted, and set none since. It is the only one the relay carries for
/// the account. Two accounts that set the same picture have a copy each.
/// Served for the daily email at the bucket's custom domain
/// (infra/cloudflare.mjs; a test holds the two equal).
export const PICTURES_ORIGIN = 'https://pictures.openhearts.game';
export const ACCOUNT_PICTURES_PREFIX = 'account/';
export const accountPicturesPrefix = (account) => `${ACCOUNT_PICTURES_PREFIX}${account}/`;
export const pictureKey = (account, digest) => `${accountPicturesPrefix(account)}${digest}.jpg`;
export const pictureUrl = (account, digest) => `${PICTURES_ORIGIN}/${pictureKey(account, digest)}`;

/// The account and digest [key] keeps the picture of ({account,
/// digest}), or null for a key that is not a picture's.
export function pictureParts(key) {
  const m = /^account\/([0-9a-f]{32})\/([0-9a-f]{64})\.jpg$/.exec(String(key));
  return m ? { account: m[1], digest: m[2] } : null;
}

/// The picture at [key] in [bucket] (an R2 binding), its metadata made
/// what [change] makes of it (a copy of it, to return changed, or null
/// to leave it as it is). Written only if nobody wrote the picture since
/// it was read, by its etag, and read again if somebody did, so that
/// two writers never lose each other's change; and never written back
/// once deleted. Resolves the metadata the picture has now, or null
/// when there is no such picture. Throws when every one of [tries]
/// writes lost to another.
export async function changePicture(bucket, key, change, { tries = 3 } = {}) {
  for (let i = 0; i < tries; i++) {
    const o = await bucket.get(key);
    if (!o) return null;
    const meta = change({ ...(o.customMetadata ?? {}) });
    if (!meta) return { ...(o.customMetadata ?? {}) };
    const bytes = await o.arrayBuffer();
    if (await bucket.put(key, bytes, { httpMetadata: o.httpMetadata, customMetadata: meta, onlyIf: { etagMatches: o.etag } })) return meta;
  }
  throw new Error(`${key} written by another ${tries} times over`);
}

/// What the copy [o] (an object R2 listed or read, with its metadata)
/// says: {key, account, digest, at, last, ended, told, check, known,
/// knownBy, knownAt, uploaded}, or null for an object that is not a
/// copy.
export function copyOf(o) {
  const parts = pictureParts(o?.key);
  if (!parts) return null;
  const m = o.customMetadata ?? {};
  return { key: o.key, ...parts, ...flagsOf(m), uploaded: new Date(o.uploaded).getTime() };
}

/// A copy's metadata [m], as profile_pictures.mjs writes it.
const flagsOf = (m) => ({ at: m.at ?? '', last: m.last ?? '', ended: m.ended ?? null, told: m.told ?? null, check: m.check ?? null, known: m.known ?? null, knownBy: m.knownBy ?? null, knownAt: m.knownAt ?? null });

/// The flags a copy keeps of what was said of it against known images
/// (service/do/known.mjs, knownAsker): [said], and its receipt, which
/// checker said it and when, once one did.
export const knownFlags = (said, { knownBy = null, knownAt = null } = {}) => ({ known: said, ...(knownBy ? { knownBy } : {}), ...(knownAt ? { knownAt } : {}) });

/// [copies], of one account, the one it set last first.
export const newestFirst = (copies) => [...copies].sort((a, b) => (a.last !== b.last ? (a.last < b.last ? 1 : -1) : a.key < b.key ? -1 : 1));

/// Every copy [account] has in [bucket] (an R2 binding), as [copyOf]
/// says it, the one it set last first.
export async function copiesOf(bucket, account) {
  const found = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix: accountPicturesPrefix(account), cursor, include: ['customMetadata'] });
    for (const o of page.objects) {
      const c = copyOf(o);
      if (c) found.push(c);
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return newestFirst(found);
}

/// Of [copies], one account's with the one it set last first, its
/// picture now: that one, unless it says it has ended; else null.
export const currentOf = (copies) => (copies[0] && !copies[0].ended ? copies[0] : null);

/// [copies], one account's in [bucket] with the one it set last first,
/// made to say what that order says: each but the first that does not
/// yet say since when it is no longer the account's picture says so,
/// from when the one after it was set; and with [end] (ISO), the first
/// too, from then. Each is written only if it was not set again since
/// it was listed (changePicture), and [copies] are changed as written.
/// Throws, once those before it are written, for a copy another writer
/// kept it from writing.
export async function settleCopies(bucket, copies, { end = null } = {}) {
  const set = copies.map((c) => c.last);
  for (let i = 0; i < copies.length; i++) {
    const c = copies[i];
    const since = i ? set[i - 1] : end;
    if (c.ended || !since) continue;
    const m = await changePicture(bucket, c.key, (m) => (m.ended || (m.last ?? '') !== c.last ? null : { ...m, ended: since }));
    if (m) Object.assign(c, flagsOf(m));
  }
}

/// [account]'s copy of [digest] deleted from [bucket], so that none it
/// set before becomes its picture now: each before it says first that
/// it has ended, if it does not yet.
export async function deleteCopy(bucket, account, digest) {
  await settleCopies(bucket, await copiesOf(bucket, account));
  await bucket.delete(pictureKey(account, digest));
}

/// The SHA-256 [said] names a picture by, as the operator is given one:
/// the digest itself, as the daily email gives it, or the address or
/// path of its copy. Null for anything else.
export function pictureNamed(said) {
  const digest = /^(?:.*\/)?([0-9a-f]{64})(?:\.jpg)?$/i.exec(String(said ?? '').trim())?.[1];
  return digest ? digest.toLowerCase() : null;
}

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

/// What a publisher is told of a picture that is not its account's
/// picture now, taken and kept the same way: one the account has not
/// set, or not yet (service/do/profile_pictures.mjs, ownedScreen).
export const NOT_THEIRS_WHY = "withheld: not this account's picture";

/// The SHA-256 of the JPEG [base64] encodes, in hex: of the bytes, so
/// that two spellings of the same picture are one. Null for anything
/// that is not base64.
export async function pictureDigest(base64) {
  if (typeof base64 !== 'string' || !base64) return null;
  let bytes;
  try {
    bytes = bytesOf64(base64);
  } catch {
    return null;
  }
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
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

/// The entries of [row]'s [part] that have not run out at [now] and
/// are not for [digest].
const still = (row, part, now, digest) => (Array.isArray(row?.[part]) ? row[part] : []).filter((p) => Number(p?.until) > now && p.sha256 !== digest);

/// A row of [pictures] and [allowed], without `allowed` when there are
/// none.
const rowOf = (pictures, allowed) => ({ pictures, ...(allowed.length ? { allowed } : {}) });

/// The digests [row] lists as allowed at [now]: put back by the
/// operator after the automatic check hid them.
export function allowedOf(row, now = Date.now()) {
  return new Set(still(row, 'allowed', now, null).map((p) => p.sha256));
}

/// [row] withholding [digest] from [now] for [WITHHELD_FOR_MS], and
/// with what has run out gone. The operator taking a picture down
/// overrides having allowed it.
export function withholding(row, digest, now = Date.now()) {
  return rowOf([...still(row, 'pictures', now, digest), { sha256: digest, until: now + WITHHELD_FOR_MS }], still(row, 'allowed', now, digest));
}

/// [row] no longer withholding [digest], and with what has run out
/// gone.
export function releasing(row, digest, now = Date.now()) {
  return rowOf(still(row, 'pictures', now, digest), still(row, 'allowed', now, null));
}

/// [row] no longer withholding [digest], and listing it as allowed for
/// [WITHHELD_FOR_MS], so that the automatic check does not hide it
/// again.
export function allowing(row, digest, now = Date.now()) {
  return rowOf(still(row, 'pictures', now, digest), [...still(row, 'allowed', now, digest), { sha256: digest, until: now + WITHHELD_FOR_MS }]);
}

/// [row] with each of [digests] it allows allowed for [WITHHELD_FOR_MS]
/// from [now], and with what has run out gone: what the operator
/// allowed stays allowed while its copy is kept (service/do/review.mjs).
export function stillAllowing(row, digests, now = Date.now()) {
  const kept = new Set(digests);
  return rowOf(
    still(row, 'pictures', now, null),
    still(row, 'allowed', now, null).map((p) => (kept.has(p.sha256) ? { sha256: p.sha256, until: now + WITHHELD_FOR_MS } : p)),
  );
}
