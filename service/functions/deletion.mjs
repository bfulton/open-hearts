// An account's data, deleted on request (the privacy policy's
// choices): everything the service keeps for an account, its profile
// included, and its name off the games it played (records.mjs,
// withoutNames), by `./oh account delete <account>` (service/tool/forget.mjs). What
// stays, its results on the relay, names its account number, which
// nothing left in the service ties to it.

import { backupRow } from './accounts.mjs';
import { Held, holdOf } from './holds.mjs';
import { isAccount } from './rows.mjs';

/// Deletes [account]'s rows: the account's own (its devices, its code,
/// backup codes, sign-in, device in use and profile), each of its
/// devices' entitlements, the rows its codes and its sign-in are found
/// by, and those of every subscription it has had. Returns the rows, as
/// `PK|SK`. With [dry], deletes nothing and says what it would. [keys]
/// lists the store's keys under a prefix, as accountsNamed takes it:
/// without it, only the subscription the account has now is found.
/// Throws [Held], deleting nothing, while the account is under a legal
/// hold (holds.mjs).
export async function forgetAccount(store, account, { dry = false, keys = null } = {}) {
  if (!isAccount(account)) return [];
  const held = await holdOf(store, account);
  if (held) throw new Held(held);
  const gone = [];
  const del = async (pk, sk) => {
    gone.push(`${pk}|${sk}`);
    if (!dry) await store.del(pk, sk);
  };
  const pk = `ACCOUNT#${account}`;
  for (const sk of await store.under(pk, 'DEVICE#')) {
    const key = sk.slice('DEVICE#'.length);
    if ((await store.get(`KEY#${key}`, 'ENTITLEMENT'))?.account === account) await del(`KEY#${key}`, 'ENTITLEMENT');
  }
  for (const c of (await store.get(pk, 'BACKUP'))?.codes ?? []) await del(await backupRow(c.code), 'META');
  const login = (await store.get(pk, 'LOGIN'))?.login;
  if (typeof login === 'string' && login.startsWith('LOGIN#')) await del(login, 'IDENTITY');
  const ticket = (await store.get(pk, 'TICKET'))?.code;
  if (typeof ticket === 'string') await del(`TICKET#${ticket}`, 'META');
  // Every subscription that names it: the one it has now, and any that
  // lapsed before a later one took the account on (accountFor), whose
  // rows still name it and would still tie its number to a payment.
  const subscriptions = new Set();
  const current = (await store.get(pk, 'META'))?.subscription;
  if (typeof current === 'string') subscriptions.add(current);
  for (const key of keys ? await keys('SUB#') : []) {
    const sub = /^SUB#(.+)\|ACCOUNT$/.exec(key)?.[1];
    if (sub) subscriptions.add(sub);
  }
  for (const sub of subscriptions) {
    if ((await store.get(`SUB#${sub}`, 'ACCOUNT'))?.account !== account) continue;
    for (const sk of await store.under(`SUB#${sub}`, '')) await del(`SUB#${sub}`, sk);
  }
  for (const sk of await store.under(pk, '')) await del(pk, sk);
  return gone;
}

/// The accounts whose profile is called [name], or was until the
/// operator took the name off and held it (suspension.mjs), case and the
/// spaces at its ends aside: for a deletion asked for by the name played
/// under. [keys] lists the store's keys under a prefix, which the
/// operator's tool can do (service/tool/kv.mjs) and the worker never
/// does.
export async function accountsNamed(store, keys, name) {
  const wanted = typeof name === 'string' ? name.trim().toLowerCase() : '';
  if (!wanted) return [];
  const found = [];
  for (const key of await keys('ACCOUNT#')) {
    const [, account, sk] = /^ACCOUNT#([0-9a-f]{32})\|(PROFILE|HELD)$/.exec(key) ?? [];
    if (!account || found.includes(account)) continue;
    const called = (await store.get(`ACCOUNT#${account}`, sk))?.name;
    if (typeof called === 'string' && called.trim().toLowerCase() === wanted) found.push(account);
  }
  return found;
}

/// Every item of the Stripe list or search at [path], page by page: a
/// search pages by its `next_page`, a list after its last item.
async function stripeAll(stripe, path) {
  const items = [];
  let more = '';
  for (;;) {
    const page = await stripe(`${path}&limit=100${more}`);
    const data = page?.data ?? [];
    items.push(...data);
    if (!page?.has_more || !data.length) return items;
    more = page.next_page ? `&page=${encodeURIComponent(page.next_page)}` : `&starting_after=${encodeURIComponent(data.at(-1).id)}`;
  }
}

/// The accounts that web subscriptions paid for with [email] stand
/// behind: for a deletion asked for by the address paid with, as Stripe
/// holds it, case aside. Stripe's search, not its list: the list's
/// filter counts case, and the search matches words, so what it finds
/// is held to the whole address. [stripe] GETs a path of Stripe's API
/// and gives its JSON.
export async function accountsPaidBy(store, stripe, email) {
  const wanted = typeof email === 'string' ? email.trim().toLowerCase() : '';
  if (!wanted.includes('@')) return [];
  const query = `email:"${wanted.replace(/["\\]/g, '\\$&')}"`;
  const customers = (await stripeAll(stripe, `/customers/search?query=${encodeURIComponent(query)}`))
    .filter((c) => typeof c?.email === 'string' && c.email.trim().toLowerCase() === wanted);
  const found = new Set();
  for (const customer of customers) {
    for (const sub of await stripeAll(stripe, `/subscriptions?customer=${encodeURIComponent(customer.id)}&status=all`)) {
      const account = (await store.get(`SUB#${sub.id}`, 'ACCOUNT'))?.account;
      if (isAccount(account)) found.add(account);
    }
  }
  return [...found];
}
