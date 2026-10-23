// Whether the service can sell: /api/health.
//
// What an outside monitor asks every minute (docs/explanation/service.md): not
// whether this worker answers — any page would say that — but whether
// what a purchase needs does. The store is read, and Stripe is asked
// for the price with the key the service holds, which catches an
// expired key while the worker answers everything else, and a price
// other than the one the terms state, which the shop will not sell.
// The answer is kept for half a minute in this isolate, so asking in a
// loop does not put the asker's load on Stripe.

import { CONFIG_ROW } from './config.mjs';
import { storeOf } from './rows.mjs';
import { StripeRefused, priceDiffers, priceLookup, statedPrice } from './stripe.mjs';

const HEALTH_KEPT_MS = 30 * 1000;
let health = null;

/// For a test: look again.
export const forgetHealth = () => {
  health = null;
};

/// {ok, store, stripe}: each check `ok`, or what went wrong in a few
/// words, without anything secret.
export async function healthOf(env, fetchImpl = fetch, { now = Date.now() } = {}) {
  if (health && health.until > now) return health.said;
  const said = { ok: false, store: 'ok', stripe: 'ok' };
  try {
    const store = storeOf(env);
    if (!store) said.store = 'not bound';
    else await store.get(...CONFIG_ROW);
  } catch (e) {
    said.store = 'unreadable';
  }
  const secret = env.OH_STRIPE_SECRET;
  const named = env.OH_STRIPE_PRICE;
  const stated = statedPrice(env);
  if (!secret || typeof named !== 'string' || !stated) {
    said.stripe = 'not configured';
  } else {
    // Asked now, not the checkout's kept answer (shopPrice): this is
    // whether Stripe answers at all, and has the price the terms state,
    // which is the only one a checkout sells at.
    try {
      const price = await priceLookup(named, secret, fetchImpl);
      const differs = price ? priceDiffers(price, stated) : null;
      if (!price) said.stripe = 'no such price';
      else if (differs) said.stripe = `not the price the terms state: ${differs}`;
    } catch (e) {
      said.stripe = e instanceof StripeRefused ? `stripe said ${e.status}` : 'not answering';
    }
  }
  said.ok = said.store === 'ok' && said.stripe === 'ok';
  health = { said, until: now + HEALTH_KEPT_MS };
  return said;
}
