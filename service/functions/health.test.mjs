// What an outside monitor asks (health.mjs): the store read
// and Stripe asked for the price with the service's key, and that price
// the one the terms state, kept for half a minute. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker from './worker.mjs';
import { forgetHealth, healthOf } from './health.mjs';
import { memoryStore } from './rows.mjs';
import { STATED, stripePrice } from './stripe.fixtures.mjs';

const kv = (store) => ({
  get: async (at) => (store.rows.has(at) ? JSON.parse(store.rows.get(at)) : null),
  put: async () => {},
  delete: async () => {},
  list: async () => ({ keys: [], list_complete: true }),
});
const stripe = (status, data = [stripePrice()]) => {
  const asked = [];
  const f = async (url, init) => {
    asked.push({ url: String(url), auth: init.headers.authorization });
    return new Response(JSON.stringify({ data }), { status });
  };
  f.asked = asked;
  return f;
};
const env = (more = {}) => ({ OH_STORE: kv(memoryStore()), OH_STRIPE_SECRET: 'rk_live_x', OH_STRIPE_PRICE: 'openhearts_annual', OH_PRICE: STATED, ...more });

test('up: the store reads and Stripe finds the price with the key the service holds', async () => {
  forgetHealth();
  const f = stripe(200);
  assert.deepEqual(await healthOf(env(), f), { ok: true, store: 'ok', stripe: 'ok' });
  assert.equal(f.asked.length, 1);
  assert.match(f.asked[0].url, /\/v1\/prices\?lookup_keys%5B%5D=openhearts_annual/);
  assert.equal(f.asked[0].auth, 'Bearer rk_live_x');
});

test('down: an expired or refused key, a missing price, Stripe away, no key, no store', async () => {
  for (const [f, more, want] of [
    [stripe(401), {}, { stripe: 'stripe said 401' }],
    [stripe(403), {}, { stripe: 'stripe said 403' }],
    [stripe(200, []), {}, { stripe: 'no such price' }],
    // A price other than the terms' is one the shop will not sell at.
    [stripe(200, [stripePrice({ unit_amount: 699 })]), {}, { stripe: 'not the price the terms state: unit_amount 699' }],
    [stripe(200, [stripePrice({ recurring: { interval: 'month', interval_count: 1 } })]), {}, { stripe: 'not the price the terms state: every 1 month' }],
    [stripe(200), { OH_PRICE: undefined }, { stripe: 'not configured' }],
    [async () => { throw new Error('down'); }, {}, { stripe: 'not answering' }],
    [stripe(200), { OH_STRIPE_SECRET: undefined }, { stripe: 'not configured' }],
    [stripe(200), { OH_STORE: undefined }, { store: 'not bound' }],
  ]) {
    forgetHealth();
    const said = await healthOf(env(more), f);
    assert.equal(said.ok, false, JSON.stringify(want));
    for (const [k, v] of Object.entries(want)) assert.equal(said[k], v);
  }
});

test('asked in a loop, Stripe is asked once in half a minute', async () => {
  forgetHealth();
  const f = stripe(200);
  const now = Date.now();
  for (let i = 0; i < 10; i++) await healthOf(env(), f, { now: now + i * 1000 });
  assert.equal(f.asked.length, 1);
  await healthOf(env(), f, { now: now + 31000 });
  assert.equal(f.asked.length, 2);
});

test('the route: 200 when up, 503 when not, never cached, GET only', async () => {
  forgetHealth();
  const realFetch = globalThis.fetch;
  globalThis.fetch = stripe(401);
  try {
    const res = await worker.fetch(new Request('https://play.openhearts.game/api/health'), env());
    assert.equal(res.status, 503);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await res.json(), { ok: false, store: 'ok', stripe: 'stripe said 401' });
    assert.equal((await worker.fetch(new Request('https://play.openhearts.game/api/health', { method: 'POST' }), env())).status, 405);
    forgetHealth();
    globalThis.fetch = stripe(200);
    assert.equal((await worker.fetch(new Request('https://play.openhearts.game/api/health'), env())).status, 200);
  } finally {
    globalThis.fetch = realFetch;
  }
});
