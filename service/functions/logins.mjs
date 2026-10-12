// A sign-in's rows: the identifier kept only as an HMAC (loginRow), and
// the one account it is linked to, linked and unlinked in the account's
// turn.

import { accountOfKey } from './accounts.mjs';
import { dayOf, hex, isAccount } from './rows.mjs';
import { notConfigured } from './settings.mjs';

/// The identifier as it is stored: an HMAC, so a leaked table joins to
/// nothing. Null when there is no secret to key it with, which is a
/// service that must not be storing identifiers at all.
export async function loginRow(who, env) {
  const secret = env.OH_ID_HMAC;
  if (!secret || !who) return null;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const mac = hex(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${who.provider}:${who.sub}`))));
  return `LOGIN#${who.provider}#${mac}`;
}

/// The account a sign-in is linked to, or null.
export async function linkedAccount(store, login) {
  const account = (await store.get(login, 'IDENTITY'))?.account;
  return isAccount(account) ? account : null;
}

/// Links the sign-in at [login] to the account [key] is a device of,
/// once, in the account's turn. A sign-in linked to another account, or
/// an account linked to another sign-in, is a refusal rather than a
/// second link: one person, one account, one sign-in.
export async function attest(who, key, store, login, { now = Date.now() } = {}) {
  if (!login) return { status: 503, body: notConfigured('OH_ID_HMAC') };
  const today = dayOf(now);
  const account = await accountOfKey(store, key);
  if (!account || !(await store.get(`ACCOUNT#${account}`, `DEVICE#${key}`))) return { status: 402, body: { error: 'no subscription' } };
  const linked = await linkedAccount(store, login);
  if (linked && linked !== account) return { status: 409, body: { error: 'that sign-in is linked to another account' } };
  const mine = await store.get(`ACCOUNT#${account}`, 'LOGIN');
  if (mine && mine.login !== login) return { status: 409, body: { error: 'this account is linked to another sign-in' } };
  const held = await store.get(login, 'IDENTITY');
  if (!isAccount(held?.account)) await store.put(login, 'IDENTITY', { account, created_at: held?.created_at ?? today });
  // What the account carries is which provider, and the row's own
  // name, an HMAC: never who. The key carries nothing of it at all.
  if (!mine) await store.put(`ACCOUNT#${account}`, 'LOGIN', { provider: who.provider, login, at: today });
  return { status: 200, body: { attested: today, account } };
}

/// [login] taken off [account], in the account's turn: the row it is
/// found by, and the account's note of it, so the account is free to be
/// linked again — to the same sign-in, if the person signs in with it
/// again. {status: 200, body: {unlinked}}, whether anything was there to
/// take; unlinking twice is nothing the second time.
export async function unlinkSignIn(account, login, store) {
  if (!isAccount(account) || typeof login !== 'string' || !/^LOGIN#[a-z]+#[0-9a-f]{64}$/.test(login)) {
    return { status: 400, body: { error: 'not a sign-in' } };
  }
  let unlinked = false;
  // Apple's word is about the identity, wherever it is linked, so its
  // row goes whatever it names.
  if (await store.get(login, 'IDENTITY')) {
    await store.del(login, 'IDENTITY');
    unlinked = true;
  }
  if ((await store.get(`ACCOUNT#${account}`, 'LOGIN'))?.login === login) {
    await store.del(`ACCOUNT#${account}`, 'LOGIN');
    unlinked = true;
  }
  return { status: 200, body: { unlinked } };
}
