// oh verify's proof that Link sells our checkout (ops/release.mjs,
// sellsThroughLink): a Managed Payments session made as the service
// makes one, and expired before anybody could pay with it.
//
//   node --test ops/*.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { Failed } from './env.mjs';
import { NO_DEVICE, sellsThroughLink } from './release.mjs';
import { stripe as stripeDefinition } from '../infra/stripe.mjs';
import { checkoutFields } from '../service/functions/stripe.mjs';

/// Stripe as the operator's key sees it: the price holding the lookup
/// key ([price]), and a session made, or refused as [refuse] says.
function stripeWith({ price = { id: 'price_1' }, refuse = null } = {}) {
  const calls = [];
  return {
    calls,
    get: async (path) => {
      calls.push(['GET', path]);
      return { data: price ? [price] : [] };
    },
    post: async (path, fields) => {
      calls.push(['POST', path, fields]);
      if (path === '/checkout/sessions' && refuse) throw new Failed(refuse);
      return path === '/checkout/sessions' ? { id: 'cs_live_1' } : { id: 'cs_live_1', status: 'expired' };
    },
  };
}

test('a checkout through Link: made as the service makes one, for no device, and expired at once', async () => {
  const stripe = stripeWith();
  assert.equal(await sellsThroughLink(stripe, 'https://play.openhearts.game'), true);
  const [lookup, made, expired] = stripe.calls;
  assert.equal(lookup[0], 'GET');
  assert.equal(new URLSearchParams(lookup[1].split('?')[1]).get('lookup_keys[]'), stripeDefinition.price.lookupKey);
  const back = 'https://play.openhearts.game/play/';
  assert.deepEqual(made, ['POST', '/checkout/sessions', checkoutFields(NO_DEVICE, 'price_1', back, back, 'en')], 'every field the service sends, branding and the terms box with them');
  assert.equal(made[2]['managed_payments[enabled]'], 'true');
  assert.equal(made[2]['metadata[key]'], '0'.repeat(64), 'no device could be bound to it');
  assert.deepEqual(expired, ['POST', '/checkout/sessions/cs_live_1/expire', undefined], 'expired before anybody could pay');
  assert.equal(stripe.calls.length, 3);
});

test('a checkout through Link: Stripe refusing it, or no price, says why and expires nothing', async () => {
  const refused = stripeWith({ refuse: 'Stripe said 400 to POST /checkout/sessions: Managed Payments is not enabled' });
  await assert.rejects(sellsThroughLink(refused, 'https://play.openhearts.game'), /Managed Payments is not enabled/);
  assert.ok(!refused.calls.some(([, path]) => path.endsWith('/expire')));
  await assert.rejects(sellsThroughLink(stripeWith({ price: null }), 'https://play.openhearts.game'), /no active price holds the lookup key openhearts_annual/);
});
