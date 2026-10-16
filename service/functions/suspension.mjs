// An account suspended from live play, or a name or picture taken off
// it, on the operator's word (the terms, "At a live table" and
// "Copyright"; docs/how-to/suspend-an-account.md). The operator's tool
// (service/tool/suspend.mjs) reaches the store from outside, as
// forget.mjs does, but what it asks for is carried out here, in the
// account's own turn (household.mjs): that is where the account's
// device in use is kept, and so where its sockets at the relay are
// closed at once, and where the devices' own changes to the account
// run, one after another with these.
//
// The tool writes an order — `ORDER#<id>|META`, {account, act, at} and,
// for a removal, which of name and picture — which KV keeps for
// [ORDER_KEPT_S], and asks the service to carry it out
// (`POST /api/order`, {order: id}). The route reads the order before
// it wakes anything, so a request that names none does nothing, and
// whoever can write one can write the store: the operator. Each act
// can be carried out twice to the same end, since the answer to the
// first can be lost and the tool asks again.

import { isSuspended } from './accounts.mjs';
import { PICTURES_ROW, pictureDigest, releasing, withholding } from './pictures.mjs';
import { dayOf, isAccount } from './rows.mjs';

/// How long an order is kept, in seconds, for the tool to have it
/// carried out: KV's own expiry, and the age past which it is refused.
export const ORDER_KEPT_S = 10 * 60;

/// An order's id: 32 hex, made by the tool.
export const isOrder = (id) => typeof id === 'string' && /^[0-9a-f]{32}$/.test(id);

/// Where an order is kept.
export const orderRow = (id) => [`ORDER#${id}`, 'META'];

/// What a suspended account's devices are told: by the licence handler,
/// by the account's turn when the relay asks about one of its
/// activations, and by the relay as it closes their sockets. The word
/// before the colon is what the app goes by (packages/table,
/// relays.dart, turnedAway).
export const SUSPENDED_WHY = 'suspended: this account is suspended from live play';

/// The acts an order may ask for.
export const ACTS = Object.freeze(['suspend', 'lift', 'remove', 'restore']);

/// [act] for [account], as the tool writes it down.
export function orderOf(account, act, { name = false, picture = false, now = Date.now() } = {}) {
  return { account, act, ...(act === 'remove' ? { name, picture } : {}), at: new Date(now).toISOString() };
}

/// The order [op.order] carried out for [op.account], in the account's
/// turn: {status, body}. [active] is where the account's device in use
/// is kept, and [revoke] closes its sockets at the relay
/// (household.mjs, revokerOf).
export async function carryOut(op, store, active, { now = Date.now(), revoke = null } = {}) {
  if (!isOrder(op.order) || !isAccount(op.account)) return { status: 400, body: { error: 'an order and its account' } };
  const order = await store.get(...orderRow(op.order));
  if (!order || order.account !== op.account) return { status: 404, body: { error: 'no such order' } };
  if (!(now - Date.parse(order.at) < ORDER_KEPT_S * 1000)) return { status: 410, body: { error: 'that order has run out' } };
  // A mistyped account is not marked: nothing is done to one that does
  // not exist.
  if (!(await store.get(`ACCOUNT#${op.account}`, 'META'))) return { status: 404, body: { error: 'no such account' } };
  let body;
  switch (order.act) {
    case 'suspend':
      body = await suspend(op.account, store, active, { now, revoke });
      break;
    case 'lift':
      body = await lift(op.account, store, active);
      break;
    case 'remove':
      body = await remove(op.account, store, { name: order.name === true, picture: order.picture === true, now });
      break;
    case 'restore':
      body = await restore(op.account, store, { now });
      break;
    default:
      return { status: 400, body: { error: `not one of ${ACTS.join(', ')}` } };
  }
  await store.del(...orderRow(op.order));
  return { status: 200, body: { act: order.act, ...body } };
}

/// Every device of [account], each with its entitlement row where that
/// row is still the account's.
async function devicesWithRows(store, account) {
  const found = [];
  for (const sk of await store.under(`ACCOUNT#${account}`, 'DEVICE#')) {
    const key = sk.slice('DEVICE#'.length);
    const row = await store.get(`KEY#${key}`, 'ENTITLEMENT');
    if (row?.account === account) found.push({ key, row });
  }
  return found;
}

/// [account] suspended: marked, so that a device brought in later is
/// too (accounts.mjs, joinAccount); each of its devices' entitlements
/// flagged, so that a licence, an activation and everything else that
/// asks for one is refused at the one read it makes (entitlementOf);
/// and its device in use cleared, its sockets at the relay closed now
/// rather than at the end of their activation's hour.
async function suspend(account, store, active, { now, revoke }) {
  if (!(await isSuspended(store, account))) await store.put(`ACCOUNT#${account}`, 'SUSPENDED', { since: dayOf(now) });
  let flagged = 0;
  for (const { key, row } of await devicesWithRows(store, account)) {
    if (row.suspended) continue;
    await store.put(`KEY#${key}`, 'ENTITLEMENT', { ...row, suspended: true });
    flagged += 1;
  }
  const was = (await active.get(account)) ?? { key: null, epoch: 0, tags: [] };
  const cutOff = was.key !== null;
  if (cutOff || !was.suspended) {
    const epoch = (was.epoch ?? 0) + 1;
    await active.put(account, { key: null, epoch, at: null, seated: null, tags: [], suspended: true });
    if (was.tags?.length) await revoke?.(was.tags, account, epoch, SUSPENDED_WHY);
  }
  return { suspended: true, flagged, cutOff };
}

/// [account]'s suspension lifted: the mark gone, its devices' rows as
/// they were, and nothing said of it when the relay asks. Its devices
/// ask for their licences again as the app next opens.
async function lift(account, store, active) {
  await store.del(`ACCOUNT#${account}`, 'SUSPENDED');
  let unflagged = 0;
  for (const { key, row } of await devicesWithRows(store, account)) {
    if (!row.suspended) continue;
    const { suspended: _, ...rest } = row;
    await store.put(`KEY#${key}`, 'ENTITLEMENT', rest);
    unflagged += 1;
  }
  const was = await active.get(account);
  if (was?.suspended) {
    const { suspended: _, ...rest } = was;
    await active.put(account, rest);
  }
  return { suspended: false, unflagged };
}

/// [account]'s name, picture or both taken off its profile and held
/// beside it (`ACCOUNT#…|HELD`), to be put back if the removal was a
/// mistake — a copyright counter-notice, say. The profile's version
/// goes up, so every device of the account takes the change as one
/// made on another device (app/lib/net/account_profile.dart). A name
/// taken off is an empty one; a picture, none, and the icon shows. What
/// is held is what the latest removal took, so that a name the player
/// chose after an earlier one was taken off is the one put back. A
/// picture taken off is withheld at the relay as well (pictures.mjs),
/// written first, so that an order carried out again after a failure
/// part way finds it withheld whatever else it finds.
async function remove(account, store, { name, picture, now }) {
  const pk = `ACCOUNT#${account}`;
  const profile = await store.get(pk, 'PROFILE');
  const removed = [];
  if (!profile) return { removed };
  const held = (await store.get(pk, 'HELD')) ?? {};
  const next = { ...profile };
  if (name && profile.name) {
    held.name = profile.name;
    next.name = '';
    removed.push('name');
  }
  if (picture && profile.picture) {
    held.picture = profile.picture;
    next.picture = null;
    removed.push('picture');
    const digest = await pictureDigest(profile.picture);
    if (digest) await store.put(...PICTURES_ROW, withholding(await store.get(...PICTURES_ROW), digest, now));
  }
  if (!removed.length) return { removed };
  await store.put(pk, 'HELD', { ...held, at: new Date(now).toISOString() });
  await store.put(pk, 'PROFILE', { ...next, version: (profile.version ?? 0) + 1, updated_at: new Date(now).toISOString() });
  return { removed };
}

/// What [remove] held, put back on [account]'s profile, and no longer
/// held; a picture no longer withheld at the relay.
async function restore(account, store, { now }) {
  const pk = `ACCOUNT#${account}`;
  const held = await store.get(pk, 'HELD');
  const restored = [];
  if (!held) return { restored };
  const profile = (await store.get(pk, 'PROFILE')) ?? { name: '', icon: null, color: null, picture: null, version: 0 };
  const next = { ...profile };
  if (typeof held.name === 'string') {
    next.name = held.name;
    restored.push('name');
  }
  if (typeof held.picture === 'string') {
    next.picture = held.picture;
    restored.push('picture');
    const digest = await pictureDigest(held.picture);
    if (digest) await store.put(...PICTURES_ROW, releasing(await store.get(...PICTURES_ROW), digest, now));
  }
  if (restored.length) {
    await store.put(pk, 'PROFILE', { ...next, version: (profile.version ?? 0) + 1, updated_at: new Date(now).toISOString() });
  }
  await store.del(pk, 'HELD');
  return { restored };
}
