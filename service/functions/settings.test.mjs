// The service's own settings (docs/explanation/service.md): one
// row the operator writes, every number checked against its bounds, and
// what the service then does by them. node --test service/functions
import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { claimWith, ticketFor } from './accounts.mjs';
import { sequencer } from './household.mjs';
import { memoryStore } from './rows.mjs';
import { SERVICE_BOUNDS, SERVICE_DEFAULTS, STRIPE_PRICE, forgetSettings, loadServiceSettings, serviceSettings, serviceSettingsOf, useSettings } from './settings.mjs';
import { checkout, forgetPriceIds, record } from './stripe.mjs';
import { STATED, stripePrice, withPrice } from './stripe.fixtures.mjs';
import { mint } from './turn.mjs';

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

test('a Stripe price is named by a price id or a lookup key, and nothing else', () => {
  for (const good of ['price_1QxYz', 'openhearts_annual']) assert.ok(STRIPE_PRICE.test(good), good);
  for (const bad of ['', 'price_', 'price_1&mode=payment', 'live play', 'a/b', 'x'.repeat(201)]) assert.ok(!STRIPE_PRICE.test(bad), bad);
  // And not by the row: the price is the one the terms state.
  assert.ok(!('stripePrice' in serviceSettingsOf({ stripePrice: 'price_1QxYz' })));
});

test('the row is read once a minute, and a store that is down is the defaults', async () => {
  const counts = { get: 0 };
  const env = { OH_STORE: kvWith({ mostDevices: 3 }, counts) };
  assert.equal((await loadServiceSettings(env, { now })).mostDevices, 3);
  assert.equal((await loadServiceSettings(env, { now: now + 59000 })).mostDevices, 3);
  assert.equal(counts.get, 1, 'kept for a minute');
  await loadServiceSettings({ OH_STORE: kvWith({ mostDevices: 4 }, counts) }, { now: now + 61000 });
  assert.equal(serviceSettings().mostDevices, 4);
  const down = { get: async () => { throw new Error('down'); } };
  assert.deepEqual(await loadServiceSettings({ OH_STORE: down }, { now: now + 200000 }), { ...SERVICE_DEFAULTS });
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

test('a checkout sells only at the price the terms state, whatever the row says', async () => {
  forgetPriceIds();
  const sent = [];
  const sell = (price) => withPrice(async (url, init) => {
    sent.push(new URLSearchParams(init.body).get('line_items[0][price]'));
    return Response.json({ url: 'https://checkout.stripe.com/c/pay/cs_1' });
  }, price);
  const env = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'price_1', OH_PRICE: STATED };
  // No row moves the shop to another price.
  useSettings({ stripePrice: 'price_new' });
  assert.equal((await checkout(KEY, 'https://x/', 'https://x/', env, sell())).status, 200);
  assert.deepEqual(sent, ['price_1']);
  // A price in Stripe that is not the terms' is not sold at, however it
  // came to be named.
  for (const other of [{ unit_amount: 699 }, { currency: 'eur' }, { recurring: { interval: 'month', interval_count: 1 } }, { recurring: null }, { active: false }]) {
    forgetPriceIds();
    assert.deepEqual(await checkout(KEY, 'https://x/', 'https://x/', env, sell(stripePrice(other))), { status: 503, body: { error: 'the shop is not open yet' } }, JSON.stringify(other));
  }
  assert.equal(sent.length, 1, 'no checkout opened at another price');
  // Nor with no price stated.
  forgetPriceIds();
  const { OH_PRICE, ...unstated } = env;
  assert.equal((await checkout(KEY, 'https://x/', 'https://x/', unstated, sell())).status, 503);
  assert.equal(sent.length, 1);
});

test('a lookup key is asked of Stripe once, for its active price, and sold by id', async () => {
  forgetPriceIds();
  const asked = [];
  const sold = [];
  const stripe = async (url, init) => {
    if (String(url).startsWith('https://api.stripe.com/v1/prices?')) {
      asked.push(new URL(url).searchParams);
      return Response.json({ data: [stripePrice({ id: 'price_Yearly599' })] });
    }
    sold.push(new URLSearchParams(init.body).get('line_items[0][price]'));
    return Response.json({ url: 'https://checkout.stripe.com/c/pay/cs_1' });
  };
  const env = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'openhearts_annual', OH_PRICE: STATED };
  for (let i = 0; i < 2; i++) assert.equal((await checkout(KEY, 'https://x/', 'https://x/', env, stripe)).status, 200);
  assert.deepEqual(sold, ['price_Yearly599', 'price_Yearly599']);
  assert.equal(asked.length, 1, 'kept, not asked for every checkout');
  assert.equal(asked[0].get('lookup_keys[]'), 'openhearts_annual');
  assert.equal(asked[0].get('active'), 'true');
});

test('a lookup key Stripe has no price for is a shop not open; Stripe not answering is said so', async () => {
  forgetPriceIds();
  const none = async () => Response.json({ data: [] });
  const env = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'no_such_key', OH_PRICE: STATED };
  assert.deepEqual(await checkout(KEY, 'https://x/', 'https://x/', env, none), { status: 503, body: { error: 'the shop is not open yet' } });
  const down = async () => new Response('no', { status: 500 });
  assert.equal((await checkout(KEY, 'https://x/', 'https://x/', env, down)).status, 502);
  const gone = { ...env, OH_STRIPE_PRICE: 'price_gone' };
  assert.equal((await checkout(KEY, 'https://x/', 'https://x/', gone, withPrice(down, null))).status, 503, 'a price id Stripe has not got');
  const bad = { ...env, OH_STRIPE_PRICE: 'price_1&mode=payment' };
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
