// A legal hold: an account's data kept as it is, on the operator's word,
// after a report the law requires — child sexual abuse material reported
// to NCMEC's CyberTipline, whose contents a provider keeps for a year
// (18 U.S.C. §2258A(h); docs/how-to/handle-abuse-material.md). While it
// holds, nothing the operator or the account asks deletes the account's
// rows (deletion.mjs) or puts back what was taken off it
// (suspension.mjs); a deletion asked for meanwhile is noted, and done
// once the hold is released (`oh account release`).

import { accountPictureKey, copyKey } from './pictures.mjs';
import { dayAfter, dayOf } from './rows.mjs';

/// How long a hold lasts at the least, in days: the year the law has a
/// report's contents kept for.
export const HOLD_DAYS = 365;

/// Where an account's hold is kept: {since, until, ref, deleteAsked}.
export const holdRow = (account) => [`ACCOUNT#${account}`, 'HOLD'];

/// The account's hold, or null.
export const holdOf = (store, account) => store.get(...holdRow(account));

/// Where a hold keeps a copy of each picture the account set, in the
/// private bucket of kept games (OH_RECORDS), which has no address of
/// its own: the copies kept of each picture an account sets
/// (pictures.mjs) are served at one, for the daily email, and deleted a
/// year after a picture stops being the account's, which a hold may
/// outlast. Placed and released by `oh account hold` and `oh account
/// release`.
export const heldPicturesPrefix = (account) => `held/${account}/`;
export const heldPictureKey = (account, digest) => `${heldPicturesPrefix(account)}${digest}.jpg`;

/// Each picture [account] set that [pictures] (OH_PICTURES) still has a
/// copy of, copied into [records] where a hold keeps it. Both are
/// buckets as {list(prefix) -> keys, read(key) -> bytes or null,
/// write(key, bytes, type)}: the operator's tool reaches them through
/// Cloudflare's API, the relay through its bindings. Resolves {kept,
/// gone}: the digests copied, and those whose copy was already deleted.
export async function keepHeldPictures(pictures, records, account) {
  const theirs = accountPictureKey(account, '');
  const kept = [];
  const gone = [];
  for (const key of await pictures.list(theirs)) {
    const digest = key.slice(theirs.length);
    const jpeg = await pictures.read(copyKey(digest));
    if (!jpeg) {
      gone.push(digest);
      continue;
    }
    await records.write(heldPictureKey(account, digest), jpeg, 'image/jpeg');
    kept.push(digest);
  }
  return { kept, gone };
}

/// A report's number, as the CyberTipline gives one: letters, digits and
/// dashes, short.
export const isReportRef = (ref) => typeof ref === 'string' && /^[A-Za-z0-9-]{1,40}$/.test(ref);

/// A hold placed on [account] from [now], for [ref] (the report's
/// number, or null): the row as written. One already in place is kept
/// as it is, with [ref] added if it had none.
export async function hold(store, account, { ref = null, now = Date.now() } = {}) {
  const was = await holdOf(store, account);
  const row = was
    ? { ...was, ref: was.ref ?? ref }
    : { since: dayOf(now), until: dayAfter(now, HOLD_DAYS), ref, deleteAsked: null };
  await store.put(...holdRow(account), row);
  return row;
}

/// Thrown where a hold stops what was asked.
export class Held extends Error {
  constructor(row) {
    super(`held since ${row.since}, until at least ${row.until}${row.ref ? `, for report ${row.ref}` : ''}`);
    this.row = row;
  }
}
