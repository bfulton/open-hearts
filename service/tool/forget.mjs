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
import { dayOf, isAccount } from '../functions/rows.mjs';

/// [account] forgotten: the mark that keeps its name off games kept
/// from then on, its name off the games already kept, and every row the
/// service keeps for it. With [apply] false, says what it would do and
/// changes nothing. [log] is told each step, by key and seat, never a
/// name, a code or a profile. Throws, changing nothing, for an account
/// whose subscription is still paid up: that is cancelled first, or its
/// next renewal would find nothing to renew. {games, rows}: how many.
export async function forget(store, bucket, account, { apply = false, log = () => {}, now = Date.now() } = {}) {
  if (!isAccount(account)) throw new Error('name the account, 32 hex');
  const subscription = (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription;
  const sub = typeof subscription === 'string' ? await store.get(`SUB#${subscription}`, 'META') : null;
  const running = !!sub && !sub.final && sub.renews_at >= dayOf(now);
  if (running && !sub.cancelled_at) throw new Error(`${subscription} is still paid up to ${sub.renews_at}; cancel it first`);
  // A web subscription that is cancelled but runs to the end of what was
  // paid for is still a subscriber's in Stripe, and `oh terms notify`
  // writes to every subscription with no note that it was told of a
  // change (ops/terms.mjs). So its notes stay, and this person is not
  // written to again about a change they were told of.
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
