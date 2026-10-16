// An account suspended from live play or let back, and its name or
// picture taken off or put back, on the operator's word (the terms, "At
// a live table" and "Copyright"; docs/how-to/suspend-an-account.md).
//
// Run by `oh account suspend`, `lift`, `remove` and `restore`
// (ops/account.mjs). An act is done in the account's own turn
// (service/functions/suspension.mjs): an order is written into the
// store, which KV keeps for ten minutes, and the service is asked to
// carry it out (POST /api/order), asked again while the store has not
// shown the order to the service yet.

import { hex } from '../functions/rows.mjs';
import { ORDER_KEPT_S, orderOf, orderRow } from '../functions/suspension.mjs';

/// How the account stands, as the store has it: {exists, suspended (the
/// day, or null), terminated (the day, or null), devices, name, picture,
/// held: {name, picture}}, the last three saying only whether there is
/// one.
export async function standing(store, account) {
  const pk = `ACCOUNT#${account}`;
  const profile = await store.get(pk, 'PROFILE');
  const held = await store.get(pk, 'HELD');
  const mark = await store.get(pk, 'SUSPENDED');
  return {
    exists: !!(await store.get(pk, 'META')),
    suspended: mark?.since ?? null,
    terminated: mark?.terminated ?? null,
    devices: (await store.under(pk, 'DEVICE#')).length,
    name: !!profile?.name,
    picture: !!profile?.picture,
    held: { name: typeof held?.name === 'string', picture: typeof held?.picture === 'string' },
  };
}

/// In words, what [act] would do to the account [stands] describes
/// (standing, above).
export function wouldDo(act, stands, { name = false, picture = false } = {}) {
  switch (act) {
    case 'suspend':
      return stands.suspended
        ? `already suspended since ${stands.suspended}; its devices would be checked again and any in use cut off`
        : `would refuse its ${stands.devices} device(s) licences and activations, and cut the one in use off at the relay`;
    case 'terminate':
      return stands.terminated
        ? `already terminated on ${stands.terminated}; its devices would be checked again and any in use cut off`
        : `would end the account: refuse its ${stands.devices} device(s) licences and activations for good, and cut the one in use off at the relay`;
    case 'lift':
      return stands.terminated
        ? `terminated on ${stands.terminated}: a terminated account is not let back`
        : stands.suspended
          ? `would let its ${stands.devices} device(s) back to live play, as each next opens the game`
          : 'not suspended: nothing to lift';
    case 'remove': {
      const parts = [...(name && stands.name ? ['name'] : []), ...(picture && stands.picture ? ['picture'] : [])];
      return parts.length ? `would take its ${parts.join(' and ')} off its profile, and hold them to put back` : 'nothing of that on its profile';
    }
    case 'restore': {
      const parts = Object.entries(stands.held).filter(([, h]) => h).map(([k]) => k);
      return parts.length ? `would put its ${parts.join(' and ')} back on its profile` : 'nothing held to put back';
    }
    default:
      return 'not an act';
  }
}

/// [act] carried out for [account] in its turn: the order written, with
/// KV's expiry, and the service asked until it has carried it out.
/// {status, body} as the service last answered, or the error the asking
/// ended on. [tries] asks, [wait] apart: a 404 or an unreachable
/// service is asked again, since KV takes a while to show a new row
/// everywhere; anything else is the answer.
export async function carry(store, account, act, options, { origin, fetchImpl = fetch, tries = 24, wait = 5000, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), now = Date.now() } = {}) {
  const id = hex(crypto.getRandomValues(new Uint8Array(16)));
  await store.put(...orderRow(id), orderOf(account, act, { ...options, now }), { ttl: ORDER_KEPT_S });
  let last = null;
  for (let i = 0; i < tries; i++) {
    if (i) await sleep(wait);
    try {
      const res = await fetchImpl(`${origin}/api/order`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ order: id }),
      });
      last = { status: res.status, body: await res.json().catch(() => null) };
    } catch (e) {
      last = { status: 0, body: { error: `${e?.message ?? e}` } };
    }
    if (last.status !== 404 && last.status !== 0 && last.status < 500) return last;
  }
  return last;
}
