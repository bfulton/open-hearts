// A subscription as its store says it: when it runs to
// (dateSubscription) — Stripe, the App Store or Google Play alike — and
// a store's checked purchase put into an account (bindPurchase).

import { accountFor, joinAccount, paidFor } from './accounts.mjs';
import { dayOf, isAccount } from './rows.mjs';

/// What a store says of a subscription, written down — Stripe, the App
/// Store or Google Play alike. [until] is when what was paid for runs
/// out, in ms; [gone] that it has ended now (refunded, revoked, given
/// up on); [final] that nothing after this is news. [created] is when
/// the store said it, in seconds, or null. Returns what was recorded,
/// or null when it was not news.
export async function dateSubscription(store, subscription, { source, txn_ref = null, until, gone = false, final = false, cancelledAt = null, created = null, now = Date.now() }) {
  const today = dayOf(now);
  // Stores do not promise to deliver in order, and a delivery that
  // failed is tried again for days: an update from before the end can
  // arrive after it. An event older than the one that wrote the row is
  // not news, and nothing is news after the end.
  const known = await store.get(`SUB#${subscription}`, 'META');
  if (known?.final) return null;
  if (created !== null && known?.event_at != null && created < known.event_at) return null;
  const renews_at = gone ? today : until ? dayOf(until) : null;
  await store.put(`SUB#${subscription}`, 'META', {
    source,
    txn_ref,
    renews_at,
    cancelled_at: cancelledAt ? dayOf(cancelledAt) : gone ? today : null,
    event_at: created ?? known?.event_at ?? null,
    ...(final ? { final: true } : {}),
  });
  // The devices under it hold a copy of the date so that a licence is
  // one read (docs/explanation/service.md). A renewal may leave those copies
  // stale — they catch up by themselves, later is harmless. An ending
  // may not: a copy that outlived its subscription would go on
  // licensing a refunded device for as long as a year. Five rows, once:
  // the devices of its account, if this is still the account's
  // subscription.
  const account = gone ? (await store.get(`SUB#${subscription}`, 'ACCOUNT'))?.account : null;
  if (isAccount(account) && (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription === subscription) {
    for (const sk of await store.under(`ACCOUNT#${account}`, 'DEVICE#')) {
      const key = sk.slice('DEVICE#'.length);
      const row = await store.get(`KEY#${key}`, 'ENTITLEMENT');
      if (row?.account !== account) continue;
      await store.put(`KEY#${key}`, 'ENTITLEMENT', { ...row, licensed_until: today, at: today });
    }
  }
  return { subscription, renews_at };
}

/// A checked purchase written down and [op.key] put into its account,
/// in the subscription's own turn: dated first, whatever it says, and
/// joined only if it is paid up. The device that paid moves onto what
/// it paid for, and its account with it where nothing else is paid up
/// there ([accountFor]); any other device bringing the same proof — a
/// restore on a new phone — joins the account as a code would let it.
/// {status, body}.
export async function bindPurchase(op, store, { now = Date.now() } = {}) {
  await dateSubscription(store, op.subscription, {
    source: op.source,
    txn_ref: op.txn_ref ?? null,
    until: op.until,
    gone: op.gone,
    created: op.created ?? null,
    now,
  });
  if (op.gone || !op.paid || !(op.until > now)) return { status: 402, body: { error: 'not paid' } };
  if (op.buyer === true) return paidFor(store, op.subscription, op.key, { now });
  const account = await accountFor(store, op.subscription, { buyer: op.key, make: true, now });
  return joinAccount(op.key, account, store, { now });
}
