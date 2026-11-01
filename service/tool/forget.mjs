// An account forgotten, on its owner's request (the privacy policy's
// choices; docs/how-to/delete-an-accounts-data.md): its name taken off
// the games it played, which stay the other players', and every row the
// service keeps for it deleted — its devices and their entitlements, its
// codes, its sign-in, its device in use, its profile — and those of
// every subscription it has had. Its results stay on the relay, under an
// account number nothing left in the service ties to it.
//
// Run by `oh account delete` (ops/account.mjs), which reaches the
// production store and bucket through Cloudflare's API.

import { anonymizeGames, forgottenKey } from '../functions/records.mjs';
import { forgetAccount } from '../functions/deletion.mjs';
import { Held, holdOf } from '../functions/holds.mjs';
import { dayOf, isAccount } from '../functions/rows.mjs';

/// [account] forgotten: the mark that keeps its name off games kept
/// from then on, its name off the games already kept, and every row the
/// service keeps for it. With [apply] false, says what it would do and
/// changes nothing. [log] is told each step, by key and seat, never a
/// name, a code or a profile. A web subscription still running is ended
/// first, by [endWeb] (given its id; not called without [apply]), as the
/// app's own deletion ends it (service/functions/worker.mjs,
/// deleteRoute), before any row that names it is deleted: a run that
/// stops there is run again and finds it. Any other subscription still
/// paid up, one bought in a store, makes this throw, changing nothing:
/// its owner cancels it in the store, or its next renewal would find
/// nothing to renew. Throws [Held], changing nothing and ending nothing,
/// while the account is under a legal hold (holds.mjs).
/// {games, rows}: how many.
export async function forget(store, bucket, account, { apply = false, log = () => {}, now = Date.now(), endWeb = null } = {}) {
  if (!isAccount(account)) throw new Error('name the account, 32 hex');
  const held = await holdOf(store, account);
  if (held) throw new Held(held);
  const subscription = (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription;
  const sub = typeof subscription === 'string' ? await store.get(`SUB#${subscription}`, 'META') : null;
  let running = !!sub && !sub.final && sub.renews_at >= dayOf(now);
  if (running && sub.source === 'stripe' && endWeb) {
    log(`${apply ? 'ending' : 'would end'} ${subscription} in Stripe now: no renewal, and nothing refunded`);
    if (apply) await endWeb(subscription);
    running = false;
  }
  if (running && !sub.cancelled_at) throw new Error(`${subscription} is still paid up to ${sub.renews_at}; cancel it first`);
  // A subscription that is cancelled but runs to the end of what was paid
  // for is still a subscriber's, and `oh terms notify` writes to every
  // subscription with no note that it was told of a change (ops/terms.mjs).
  // So its notes stay, and this person is not written to again about a
  // change they were told of. (Only a store's: a web one is ended above.)
  const notesKept = running ? [subscription] : [];
  // The mark first: a game kept from then on, one that ends while this
  // runs or that the account plays while its last licence runs, is kept
  // without its name (records.mjs, keepRecord). Then the games already
  // kept, by their seats' licences, and then the rows. A run that stops
  // part way is run again.
  const mark = forgottenKey(account);
  if (await bucket.get(mark)) {
    log(`${mark} is marked`);
  } else {
    if (apply) await bucket.put(mark, { forgotten: dayOf(now) });
    log(`${apply ? 'marked' : 'would mark'} ${mark}, for the games kept from then on`);
  }
  const games = await anonymizeGames(bucket, account, { dry: !apply });
  for (const { key, named } of games) log(`${apply ? 'took' : 'would take'} the name off ${key}, seat ${named.join(', ')}`);
  const rows = await forgetAccount(store, account, { dry: !apply, keys: store.list, notesKept });
  // A household code is a code: its row is said, and not its name.
  for (const row of rows) log(`${apply ? 'deleted' : 'would delete'} ${row.replace(/^TICKET#[^|]+/, 'TICKET#…')}`);
  log(`${games.length} game(s) and ${rows.length} row(s) ${apply ? 'changed' : 'to change; --apply changes them'}`);
  return { games: games.length, rows: rows.length };
}
