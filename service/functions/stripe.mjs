// Buying on the web with Stripe: the checkout, what Stripe's webhook
// says, the billing portal, and the payer's email address for backup
// codes.

import { paidFor } from './accounts.mjs';
import { dayOf, isAccount } from './rows.mjs';
import { S, STRIPE_PRICE } from './settings.mjs';
import { dateSubscription } from './subscriptions.mjs';

// ---- buying, on the web ------------------------------------------------
// Stripe Checkout in subscription mode, with the device's key in the
// session. Nobody is asked for an email or a password: the account is
// made when the subscription is paid for, with the paying device on it
// ([paidFor]), and the licence follows. A phone buys through its own
// store instead (stores.mjs, "buying in a store").

const STRIPE = 'https://api.stripe.com/v1';

/// The states a subscription does not come back from. Not `canceled`
/// alone: dunning that gives up leaves `unpaid`, and a checkout that
/// was never paid leaves `incomplete_expired`.
const ENDED = new Set(['canceled', 'unpaid', 'incomplete_expired']);

/// And of those, the ones that are final: `unpaid` comes back when the
/// invoice is paid after all; these two do not, and neither does a
/// subscription Stripe has deleted.
const FINAL = new Set(['canceled', 'incomplete_expired']);

/// Where a buyer may be sent back to: this site, and nowhere else. The
/// address rides in from the app, and an app is not what decides where
/// a payment lands.
export function sameSite(candidate, requestUrl) {
  if (typeof candidate !== 'string') return null;
  let at;
  try {
    at = new URL(candidate, requestUrl);
  } catch {
    return null;
  }
  return at.origin === new URL(requestUrl).origin ? at.toString() : null;
}

/// Lookup keys already asked of Stripe, kept a few minutes: a key moved
/// to a new price reaches checkouts within that.
const priceIds = new Map();
const PRICE_KEPT_MS = 5 * 60 * 1000;

/// For a test: ask Stripe again.
export const forgetPriceIds = () => priceIds.clear();

/// The price id [named] stands for — itself, when it is one; the active
/// price holding it as its lookup key, when it is not; null when Stripe
/// has no such price.
export async function priceIdOf(named, secret, fetchImpl = fetch, { now = Date.now() } = {}) {
  if (named.startsWith('price_')) return named;
  const kept = priceIds.get(named);
  if (kept && kept.until > now) return kept.id;
  const id = await priceLookup(named, secret, fetchImpl);
  if (id) priceIds.set(named, { id, until: now + PRICE_KEPT_MS });
  return id;
}

/// Stripe refusing to say: its status.
export class StripeRefused extends Error {
  constructor(status) {
    super(`stripe prices ${status}`);
    this.status = status;
  }
}

/// The price Stripe has under the lookup key [named], asked now: its
/// id, or null for none. Throws [StripeRefused] when Stripe says no,
/// and whatever the fetch throws when it does not answer.
export async function priceLookup(named, secret, fetchImpl) {
  const url = `${STRIPE}/prices?${new URLSearchParams({ 'lookup_keys[]': named, active: 'true', limit: '1' })}`;
  const res = await fetchImpl(url, { headers: { authorization: `Bearer ${secret}` } });
  if (!res.ok) throw new StripeRefused(res.status);
  const id = (await res.json())?.data?.[0]?.id;
  return typeof id === 'string' && id.startsWith('price_') ? id : null;
}

/// How Stripe's checkout page looks: the app's, not the account's — the
/// felt, the gold, the front door's heart, and the name (one account may
/// sell more than one app). The icon is the site's own copy, so a
/// preview's checkout shows a preview's icon. Only the top of the page
/// takes the name; receipts carry the account's public business name.
export function checkoutBranding(back) {
  return {
    'branding_settings[display_name]': 'Open Hearts',
    'branding_settings[icon][type]': 'url',
    'branding_settings[icon][url]': new URL('/icon-512.png', back).toString(),
    'branding_settings[background_color]': '#06231A',
    'branding_settings[button_color]': '#E4B363',
    'branding_settings[border_style]': 'rounded',
    'branding_settings[font_family]': 'roboto',
  };
}

/// A checkout session for [key], as Stripe answers: {status, body}.
export async function checkout(key, back, cancelled, env, fetchImpl = fetch) {
  const secret = env.OH_STRIPE_SECRET;
  const named = S().stripePrice ?? env.OH_STRIPE_PRICE;
  if (!secret || typeof named !== 'string' || !STRIPE_PRICE.test(named)) return { status: 503, body: { error: 'the shop is not open yet' } };
  let price;
  try {
    price = await priceIdOf(named, secret, fetchImpl);
  } catch {
    return { status: 502, body: { error: 'the shop is not answering' } };
  }
  if (!price) return { status: 503, body: { error: 'the shop is not open yet' } };
  const form = new URLSearchParams({
    mode: 'subscription',
    'line_items[0][price]': price,
    'line_items[0][quantity]': '1',
    success_url: back,
    cancel_url: cancelled,
    // Three places, because three different events carry it back: the
    // session's own metadata, the reference on the session, and the
    // subscription's metadata, which is what a renewal a year from now
    // will have.
    'metadata[key]': key,
    client_reference_id: key,
    'subscription_data[metadata][key]': key,
    ...checkoutBranding(back),
  });
  let res;
  try {
    res = await fetchImpl(`${STRIPE}/checkout/sessions`, {
      method: 'POST',
      headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    });
  } catch {
    return { status: 502, body: { error: 'the shop is not answering' } };
  }
  if (!res.ok) return { status: 502, body: { error: `the shop said ${res.status}` } };
  let session;
  try {
    session = await res.json();
  } catch {
    return { status: 502, body: { error: 'the shop talked nonsense' } };
  }
  if (typeof session.url !== 'string') return { status: 502, body: { error: 'the shop gave no checkout' } };
  return { status: 200, body: { url: session.url } };
}

/// Whether [header] signs [raw] with [secret], the way Stripe signs.
/// The payload is the timestamp and the body with a dot between them,
/// HMAC-SHA256; a signature over a payload from last week is refused
/// whatever it says, since a replay is not a payment.
export async function webhookSigned(header, raw, secret, { now = Date.now() } = {}) {
  if (typeof header !== 'string' || !secret) return false;
  const parts = Object.create(null);
  const v1 = [];
  for (const piece of header.split(',')) {
    const at = piece.indexOf('=');
    if (at < 0) continue;
    const name = piece.slice(0, at).trim();
    const value = piece.slice(at + 1).trim();
    if (name === 'v1') v1.push(value);
    else parts[name] = value;
  }
  const t = Number(parts.t);
  if (!Number.isFinite(t) || !v1.length) return false;
  if (Math.abs(now / 1000 - t) > S().webhookToleranceS) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'verify',
  ]);
  const signed = new TextEncoder().encode(`${t}.${raw}`);
  // Every v1 offered, since a secret being rotated signs with two —
  // each checked by the platform's own HMAC verify, which compares in
  // constant time, rather than by comparing strings, which stops at the
  // first character that differs.
  for (const offered of v1) {
    if (!/^[0-9a-f]{64}$/.test(offered)) continue;
    const mac = Uint8Array.from(offered.match(/../g), (b) => parseInt(b, 16));
    if (await crypto.subtle.verify('HMAC', key, mac, signed)) return true;
  }
  return false;
}

/// What a Stripe event means here, written down. Returns what was
/// recorded, or null when the event is not one of ours — a webhook
/// carries everything the account does, and most of it is not this.
export async function record(event, store, { now = Date.now() } = {}) {
  const object = event?.data?.object ?? {};
  const today = dayOf(now);
  // A checkout this service made, and paid for. Made here: only a
  // session this worker created carries the key in its metadata — a
  // Payment Link or a checkout for some other product on the account
  // can carry a client_reference_id in its URL, and must not buy live
  // play with it. Paid: `complete` with payment still to come is what a
  // delayed method sends first, and its money arrives, or does not, in
  // `async_payment_succeeded`.
  if (event?.type === 'checkout.session.completed' || event?.type === 'checkout.session.async_payment_succeeded') {
    if (object.mode !== undefined && object.mode !== 'subscription') return null;
    if (object.payment_status !== 'paid' && object.payment_status !== 'no_payment_required') return null;
    const key = object.metadata?.key;
    const subscription = typeof object.subscription === 'string' ? object.subscription : object.subscription?.id;
    if (!/^[0-9a-f]{64}$/.test(key ?? '') || !subscription) return null;
    // The date is the subscription's to say, and its own event may not
    // have arrived yet: bound now, dated on the first ask after it has.
    await keepCustomer(store, subscription, object.customer);
    const paid = await paidFor(store, subscription, key, { now });
    return { bound: key, subscription, account: paid.body?.account ?? null };
  }
  if (event?.type?.startsWith('customer.subscription.')) {
    const subscription = object.id;
    if (!subscription) return null;
    await keepCustomer(store, subscription, object.customer);
    const period = object.current_period_end ?? object.items?.data?.[0]?.current_period_end;
    // Ended: Stripe deleted it, or dunning gave up, or it was refunded
    // out. A subscription that is merely *cancelling* is not this — it
    // runs to the end of what was paid for, which is what renews_at
    // already says.
    const final = event.type.endsWith('.deleted') || FINAL.has(object.status);
    return dateSubscription(store, subscription, {
      source: 'stripe',
      txn_ref: object.latest_invoice ?? null,
      until: period ? period * 1000 : null,
      gone: final || ENDED.has(object.status),
      final,
      cancelledAt: object.canceled_at ? object.canceled_at * 1000 : null,
      created: Number.isSafeInteger(event.created) ? event.created : null,
      now,
    });
  }
  return null;
}

/// The Stripe customer behind [subscription], kept so a device on it can
/// open the billing portal. A row of its own, since the subscription's
/// META is written whole by every subscription event.
async function keepCustomer(store, subscription, customer) {
  const id = typeof customer === 'string' ? customer : customer?.id;
  if (typeof id !== 'string' || !/^cus_[A-Za-z0-9]{1,64}$/.test(id)) return;
  const known = await store.get(`SUB#${subscription}`, 'CUSTOMER');
  if (known?.customer !== id) await store.put(`SUB#${subscription}`, 'CUSTOMER', { customer: id });
}

// ---- managing a web subscription ------------------------------------------
// A web subscriber cancels, changes card or reads an invoice in Stripe's
// own billing portal: the service opens a session for the subscription's
// customer and the device goes there, as it went to the checkout. Any
// device of the account may, as any may drop another: an account that
// lost the phone that paid still has to be able to cancel. A
// subscription bought in a store is managed in the store, and local
// mode's open house was never bought at all.

/// A billing portal session for the subscription of the account [key]
/// is a device of: {status, body}.
export async function manage(key, back, store, env, fetchImpl = fetch) {
  const secret = env.OH_STRIPE_SECRET;
  if (!secret) return { status: 503, body: { error: 'the shop is not open yet' } };
  const account = (await store.get(`KEY#${key}`, 'ENTITLEMENT'))?.account;
  // Bound to it, not merely once on it: a dropped device keeps no say.
  if (!isAccount(account) || !(await store.get(`ACCOUNT#${account}`, `DEVICE#${key}`))) return { status: 402, body: { error: 'no subscription' } };
  const subscription = (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription;
  if (!subscription) return { status: 402, body: { error: 'no subscription' } };
  if (!subscription.startsWith('sub_')) return { status: 409, body: { error: 'not a web subscription' } };
  const auth = { authorization: `Bearer ${secret}` };
  let customer = (await store.get(`SUB#${subscription}`, 'CUSTOMER'))?.customer;
  if (!customer) {
    // No customer row for this subscription: Stripe knows.
    try {
      const res = await fetchImpl(`${STRIPE}/subscriptions/${encodeURIComponent(subscription)}`, { headers: auth });
      if (res.ok) customer = (await res.json())?.customer;
    } catch {
      return { status: 502, body: { error: 'the shop is not answering' } };
    }
    if (typeof customer !== 'string' || !/^cus_[A-Za-z0-9]{1,64}$/.test(customer)) {
      return { status: 502, body: { error: 'the shop does not know this subscription' } };
    }
    await keepCustomer(store, subscription, customer);
  }
  let res;
  try {
    res = await fetchImpl(`${STRIPE}/billing_portal/sessions`, {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ customer, return_url: back }).toString(),
    });
  } catch {
    return { status: 502, body: { error: 'the shop is not answering' } };
  }
  if (!res.ok) return { status: 502, body: { error: `the shop said ${res.status}` } };
  let session;
  try {
    session = await res.json();
  } catch {
    return { status: 502, body: { error: 'the shop talked nonsense' } };
  }
  if (typeof session.url !== 'string') return { status: 502, body: { error: 'the shop gave no portal' } };
  return { status: 200, body: { url: session.url } };
}

/// The email Stripe holds for the customer behind [subscription], or
/// null: read when backup codes are sent, and not kept. The account's
/// subscription, for an account.
export async function payerEmail(store, subscription, env, fetchImpl = fetch) {
  return (await payerLookup(store, subscription, env, fetchImpl)).email;
}

/// [payerEmail], with why there is none: {email, why}. The why goes to
/// the household with the ask, which logs it beside the send it
/// stopped (the relay's log is the one that can be read afterwards).
export async function payerLookup(store, subscription, env, fetchImpl = fetch) {
  const secret = env.OH_STRIPE_SECRET;
  if (!secret) return { email: null, why: 'no Stripe key' };
  if (typeof subscription !== 'string' || !subscription.startsWith('sub_')) return { email: null, why: 'not a web subscription' };
  const customer = (await store.get(`SUB#${subscription}`, 'CUSTOMER'))?.customer;
  if (!customer) return { email: null, why: 'no customer on record' };
  try {
    const res = await fetchImpl(`${STRIPE}/customers/${encodeURIComponent(customer)}`, { headers: { authorization: `Bearer ${secret}` } });
    if (!res.ok) {
      const code = (await res.json().catch(() => null))?.error?.code;
      return { email: null, why: `Stripe said ${res.status}${code ? ` (${code})` : ''}` };
    }
    const email = (await res.json())?.email;
    return typeof email === 'string' && email.includes('@') ? { email, why: null } : { email: null, why: 'no email on the customer' };
  } catch (e) {
    return { email: null, why: `Stripe unreachable: ${e?.message ?? e}` };
  }
}
