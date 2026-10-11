// The service's own settings (docs/06-service.md): one
// row the operator writes, every number checked against its bounds, and
// what the service then does by them. node --test service/functions
import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import {
  SERVICE_BOUNDS,
  SERVICE_DEFAULTS,
  S,
  checkout,
  forgetPriceIds,
  claimWith,
  forgetSettings,
  memoryStore,
  mint,
  record,
  sequencer,
  serviceSettingsOf,
  settle,
  ticketFor,
  useSettings,
} from './worker.mjs';

const KEY = 'ab'.repeat(32);
const now = Date.now();

afterEach(forgetSettings);

/// A KV binding holding [row] as `config|service`, counting its reads.
const kvWith = (row, counts = { get: 0 }) => ({
  counts,
  async get(at, kind) {
    counts.get++;
    if (at !== 'config|service') return null;
    return kind === 'json' ? row : JSON.stringify(row);
  },
});

test('no row is the defaults', () => {
  assert.deepEqual(serviceSettingsOf(null), { ...SERVICE_DEFAULTS });
  assert.deepEqual(SERVICE_DEFAULTS, {
    licenceDays: 31,
    mostDevices: 5,
    ticketMinutes: 10,
    ticketReuseMinutes: 2,
    turnTtlS: 14400,
    requestToleranceS: 300,
    webhookToleranceS: 300,
    householdChangesPerHour: 20,
    householdReadsPerHour: 60,
    activationsPerHour: 600,
    profileWritesPerHour: 30,
    recordsPerHour: 12,
    stripePrice: null,
  });
  for (const raw of [[], 'x', 7]) assert.deepEqual(serviceSettingsOf(raw), { ...SERVICE_DEFAULTS });
});

test('each number is taken at its edges and refused past them, on its own', () => {
  for (const [name, [least, most]] of Object.entries(SERVICE_BOUNDS)) {
    if (name === 'ticketReuseMinutes') continue;
    assert.equal(serviceSettingsOf({ [name]: least })[name], least, `${name} at ${least}`);
    assert.equal(serviceSettingsOf({ [name]: most })[name], most, `${name} at ${most}`);
    for (const bad of [least - 1, most + 1, least + 0.5, String(least), null]) {
      const got = serviceSettingsOf({ [name]: bad, mostDevices: 3 });
      assert.equal(got[name], name === 'mostDevices' ? 3 : SERVICE_DEFAULTS[name], `${name} at ${bad}`);
      if (name !== 'mostDevices') assert.equal(got.mostDevices, 3, 'one bad field leaves the others');
    }
  }
});

test('a code handed back again always has time left in it', () => {
  assert.equal(serviceSettingsOf({ ticketMinutes: 5, ticketReuseMinutes: 4 }).ticketReuseMinutes, 4);
  assert.equal(serviceSettingsOf({ ticketMinutes: 5, ticketReuseMinutes: 5 }).ticketReuseMinutes, 2);
  assert.equal(serviceSettingsOf({ ticketMinutes: 1 }).ticketReuseMinutes, 0);
});

test('a Stripe price is a price id or a lookup key, and nothing else', () => {
  assert.equal(serviceSettingsOf({ stripePrice: 'price_1QxYz' }).stripePrice, 'price_1QxYz');
  assert.equal(serviceSettingsOf({ stripePrice: 'openhearts_annual' }).stripePrice, 'openhearts_annual');
  for (const bad of ['', 'price_', 'price_1&mode=payment', 'live play', 'a/b', 'x'.repeat(201), 42]) {
    assert.equal(serviceSettingsOf({ stripePrice: bad }).stripePrice, null, String(bad));
  }
});

test('the row is read once a minute, and a store that is down is the defaults', async () => {
  const counts = { get: 0 };
  const env = { OH_STORE: kvWith({ mostDevices: 3 }, counts) };
  assert.equal((await settle(env, { now })).mostDevices, 3);
  assert.equal((await settle(env, { now: now + 59000 })).mostDevices, 3);
  assert.equal(counts.get, 1, 'kept for a minute');
  await settle({ OH_STORE: kvWith({ mostDevices: 4 }, counts) }, { now: now + 61000 });
  assert.equal(S().mostDevices, 4);
  const down = { get: async () => { throw new Error('down'); } };
  assert.deepEqual(await settle({ OH_STORE: down }, { now: now + 200000 }), { ...SERVICE_DEFAULTS });
});

async function subscriber() {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((now + 300 * 86400000) / 1000) } } }, store, { now });
  return store;
}

test('a household of two, when the row says two', async () => {
  useSettings({ mostDevices: 2 });
  const store = await subscriber();
  const made = await ticketFor(KEY, store, { now });
  assert.equal(made.body.most, 2);
  assert.equal((await claimWith('11'.repeat(32), made.body.ticket, store, { now })).status, 200);
  const third = await ticketFor(KEY, store, { now });
  assert.equal(third.status, 409);
  assert.equal(third.body.most, 2);
});

test('a code good for as long as the row says', async () => {
  useSettings({ ticketMinutes: 3, ticketReuseMinutes: 1 });
  const store = await subscriber();
  const made = await ticketFor(KEY, store, { now });
  assert.equal(Date.parse(made.body.expires_at) - now, 3 * 60000);
  assert.equal((await claimWith('11'.repeat(32), made.body.ticket, store, { now: now + 3 * 60000 + 1 })).status, 410);
});

test('the Stripe price in the row is the one a checkout sells', async () => {
  const sent = [];
  const stripe = async (url, init) => {
    sent.push(new URLSearchParams(init.body).get('line_items[0][price]'));
    return Response.json({ url: 'https://checkout.stripe.com/c/pay/cs_1' });
  };
  const env = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'price_build' };
  await checkout(KEY, 'https://x/', 'https://x/', env, stripe);
  useSettings({ stripePrice: 'price_new' });
  await checkout(KEY, 'https://x/', 'https://x/', env, stripe);
  assert.deepEqual(sent, ['price_build', 'price_new']);
});

test('a lookup key is asked of Stripe once, for its active price, and sold by id', async () => {
  forgetPriceIds();
  const asked = [];
  const sold = [];
  const stripe = async (url, init) => {
    if (String(url).startsWith('https://api.stripe.com/v1/prices?')) {
      asked.push(new URL(url).searchParams);
      return Response.json({ data: [{ id: 'price_Yearly599' }] });
    }
    sold.push(new URLSearchParams(init.body).get('line_items[0][price]'));
    return Response.json({ url: 'https://checkout.stripe.com/c/pay/cs_1' });
  };
  const env = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'openhearts_annual' };
  for (let i = 0; i < 2; i++) assert.equal((await checkout(KEY, 'https://x/', 'https://x/', env, stripe)).status, 200);
  assert.deepEqual(sold, ['price_Yearly599', 'price_Yearly599']);
  assert.equal(asked.length, 1, 'kept, not asked for every checkout');
  assert.equal(asked[0].get('lookup_keys[]'), 'openhearts_annual');
  assert.equal(asked[0].get('active'), 'true');
});

test('a lookup key Stripe has no price for is a shop not open; Stripe not answering is said so', async () => {
  forgetPriceIds();
  const none = async () => Response.json({ data: [] });
  const env = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'no_such_key' };
  assert.deepEqual(await checkout(KEY, 'https://x/', 'https://x/', env, none), { status: 503, body: { error: 'the shop is not open yet' } });
  const down = async () => new Response('no', { status: 500 });
  assert.equal((await checkout(KEY, 'https://x/', 'https://x/', env, down)).status, 502);
  const bad = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'price_1&mode=payment' };
  assert.equal((await checkout(KEY, 'https://x/', 'https://x/', bad, none)).status, 503, 'nothing sent for a name that is neither');
});

test('TURN credentials last as long as the row says', async () => {
  useSettings({ turnTtlS: 3600 });
  let asked;
  await mint({ OH_TURN_KEY_ID: 'k', OH_TURN_API_TOKEN: 't' }, async (url, init) => {
    asked = JSON.parse(init.body).ttl;
    return Response.json({ iceServers: [] });
  });
  assert.equal(asked, 3600);
});

test('a household is held to the row\'s allowance an hour', async () => {
  useSettings({ householdChangesPerHour: 5 });
  const next = sequencer({ now: () => now });
  const said = [];
  for (let i = 0; i < 7; i++) said.push((await next('change', async () => ({ status: 200 }))).status);
  assert.deepEqual(said, [200, 200, 200, 200, 200, 429, 429]);
});

test('records sent to be kept have an allowance of their own', async () => {
  useSettings({ recordsPerHour: 2, householdChangesPerHour: 5 });
  const next = sequencer({ now: () => now });
  const said = [];
  for (let i = 0; i < 3; i++) said.push((await next('record', async () => ({ status: 200 }))).status);
  assert.deepEqual(said, [200, 200, 429]);
  assert.equal((await next('change', async () => ({ status: 200 }))).status, 200, 'and spend none of the changes\'');
});
