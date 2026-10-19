// An account's data, deleted on request (the privacy policy's
// choices): everything the service keeps for an account, its profile
// included, and its name off the games it played (records.mjs,
// withoutNames), by `./oh account delete <account>` (service/tool/forget.mjs). What
// stays, its results on the relay, names its account number, which
// nothing left in the service ties to it.

import { accountOfKey, backupRow } from './accounts.mjs';
import { Held, holdOf, holdRow } from './holds.mjs';
import { dayOf, isAccount } from './rows.mjs';

/// What a deleted account's device in use is told as the relay closes
/// its sockets (packages/table, relays.dart, turnedAway): the word
/// before the colon is what the app goes by.
export const DELETED_WHY = 'deleted: this account was deleted';

/// The account of [op.key], one of its devices, deleted at that
/// device's asking, in the account's turn (household.mjs): what the
/// route has not already done outside the store (worker.mjs,
/// deleteRoute). Its rows go ([forgetAccount]), and its device in use
/// is cut off at the relay now, the account's object keeping only the
/// count that orders its devices in use. Its picture is no longer its
/// own, and is kept as long as one replaced ([pictures],
/// profile_pictures.mjs). Under a legal hold (holds.mjs), nothing goes:
/// the asking is noted, for when the hold is released, and the answer
/// is the same. {status, body}.
export async function deleteAccount(op, store, active, { now = Date.now(), revoke = null, pictures = null } = {}) {
  const account = await accountOfKey(store, op.key);
  if (!account || !(await store.get(`ACCOUNT#${account}`, `DEVICE#${op.key}`))) return { status: 404, body: { error: 'no account' } };
  const held = await holdOf(store, account);
  if (held) {
    if (!held.deleteAsked) await store.put(...holdRow(account), { ...held, deleteAsked: dayOf(now) });
    return { status: 200, body: { deleted: true } };
  }
  const picture = (await store.get(`ACCOUNT#${account}`, 'PROFILE'))?.picture ?? null;
  await forgetAccount(store, account);
  if (picture) await pictures?.set({ account, picture: null, prev: picture });
  const was = await active.get(account);
  if (was) {
    const epoch = (was.epoch ?? 0) + 1;
    await active.put(account, { key: null, epoch, at: null, seated: null, tags: [] });
    if (was.tags?.length) await revoke?.(was.tags, account, epoch, DELETED_WHY);
  }
  return { status: 200, body: { deleted: true } };
}

/// Deletes [account]'s rows: the account's own (its devices, its code,
/// backup codes, sign-in, device in use and profile), each of its
/// devices' entitlements, the rows its codes and its sign-in are found
/// by, and those of every subscription it has had. Returns the rows, as
/// `PK|SK`. With [dry], deletes nothing and says what it would. [keys]
/// lists the store's keys under a prefix, as accountsNamed takes it:
/// without it, the subscriptions found are the ones the account's META
/// names, now and before (accountFor).
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
  // lapsed before a later one took the account on (accountFor, which
  // notes them as `before`), whose rows still name it and would still
  // tie its number to a payment.
  const subscriptions = new Set();
  const meta = await store.get(pk, 'META');
  for (const sub of [meta?.subscription, ...(Array.isArray(meta?.before) ? meta.before : [])]) {
    if (typeof sub === 'string') subscriptions.add(sub);
  }
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
