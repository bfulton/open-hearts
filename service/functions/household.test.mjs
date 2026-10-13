// One household at a time (docs/explanation/security-model.md): a code
// spent twice at once lets one device in; asking for a code again is a
// read; a household is held to so many changes an hour; and a body too
// big to be ours is not read. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker from './worker.mjs';
import { claimWith, devicesOn, ticketFor } from './accounts.mjs';
import { Household, forgetHouseholds, inHousehold, sequencer } from './household.mjs';
import { memoryStore } from './rows.mjs';
import { SERVICE_DEFAULTS } from './settings.mjs';
import { record } from './stripe.mjs';
import { SUSPENDED_WHY } from './suspension.mjs';
import { carry } from '../tool/suspend.mjs';

const KEY = 'ab'.repeat(32);
const now = Date.now();

/// Cloudflare KV over a memoryStore's rows, as storeOf reads it.
const kvOf = (store, counts = { put: 0, list: 0 }) => ({
  counts,
  async get(at, kind) {
    const raw = store.rows.get(at);
    return raw === undefined ? null : kind === 'json' ? JSON.parse(raw) : raw;
  },
  async put(at, raw) {
    counts.put++;
    store.rows.set(at, raw);
  },
  async delete(at) {
    store.rows.delete(at);
  },
  async list({ prefix }) {
    counts.list++;
    return { keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true };
  },
});

/// A subscriber on sub_9 with [n] devices, KEY among them; its account
/// is [accountOf] it.
const accountOf = async (store) => (await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).account;

async function household(n = 1) {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((now + 300 * 86400000) / 1000) } } }, store, { now });
  for (let i = 1; i < n; i++) await claimWith(String(i).repeat(64).slice(0, 64), (await ticketFor(KEY, store, { now })).body.ticket, store, { now });
  return store;
}

/// A Durable Object namespace that keeps one Household a name, in this
/// process, as Cloudflare keeps one in the world.
function householdNamespace(env) {
  const objects = new Map();
  return {
    idFromName: (name) => name,
    get(id) {
      if (!objects.has(id)) {
        // An object's own storage, behind the two calls it makes.
        const kept = new Map();
        const storage = { get: async (k) => kept.get(k), put: async (k, v) => void kept.set(k, structuredClone(v)) };
        objects.set(id, new Household({ storage }, env));
      }
      const object = objects.get(id);
      return { fetch: (url, init) => object.fetch(new Request(url, init)) };
    },
  };
}

for (const where of ['in this isolate', 'in a Durable Object']) {
  test(`${where}: one code spent twice at once lets one device in`, async () => {
    forgetHouseholds();
    const store = await household(4);
    const env = { OH_STORE: kvOf(store) };
    if (where === 'in a Durable Object') env.HOUSEHOLD = householdNamespace({ OH_STORE: env.OH_STORE });
    const account = await accountOf(store);
    const code = (await ticketFor(KEY, store, { now })).body.ticket;
    const both = await Promise.all(['77', '88'].map((b) => inHousehold(env, account, { op: 'claim', key: b.repeat(32), code })));
    assert.deepEqual(both.map((c) => c.status).sort(), [200, 409], 'one code, one device');
    assert.equal((await devicesOn(store, account)).length, 5);
  });

  test(`${where}: two codes spent at once into the last place let one device in`, async () => {
    forgetHouseholds();
    const store = await household(4);
    const env = { OH_STORE: kvOf(store) };
    if (where === 'in a Durable Object') env.HOUSEHOLD = householdNamespace({ OH_STORE: env.OH_STORE });
    // Two codes made before either is spent: the reuse hands out the
    // outstanding one, so the second is made by hand.
    const account = await accountOf(store);
    const first = (await ticketFor(KEY, store, { now })).body.ticket;
    store.rows.delete(`ACCOUNT#${account}|TICKET`);
    const second = (await ticketFor(KEY, store, { now })).body.ticket;
    assert.notEqual(first, second);
    const both = await Promise.all([
      inHousehold(env, account, { op: 'claim', key: '77'.repeat(32), code: first }),
      inHousehold(env, account, { op: 'claim', key: '88'.repeat(32), code: second }),
    ]);
    assert.deepEqual(both.map((c) => c.status).sort(), [200, 409]);
    assert.equal((await devicesOn(store, account)).length, 5, 'five, not six');
  });
}

test("an operator's order, through the service to the account's own object: its device in use cut off at the relay, saying it is suspended", async () => {
  forgetHouseholds();
  const store = await household(2);
  const account = await accountOf(store);
  // The relay's objects, as the account's object tells them.
  const told = [];
  const TABLE = {
    idFromName: (tag) => tag,
    get: (tag) => ({ fetch: async (url, init) => (told.push({ tag, path: new URL(url).pathname, ...JSON.parse(init.body) }), new Response('ok\n')) }),
  };
  const env = { OH_STORE: kvOf(store) };
  env.HOUSEHOLD = householdNamespace({ OH_STORE: env.OH_STORE, TABLE });
  // In use, and seen at the relay's presence.
  assert.equal((await inHousehold(env, account, { op: 'activate', key: KEY, account, want: 'open' })).status, 200);
  assert.equal((await inHousehold(env, account, { op: 'seen', key: KEY, account, epoch: 1, tag: 'online' })).status, 200);
  // The tool, asking this worker.
  const fetchImpl = (url, init) => worker.fetch(new Request(url, init), env);
  const done = await carry(store, account, 'suspend', {}, { origin: 'https://dev.open-hearts.pages.dev', fetchImpl, wait: 0 });
  assert.deepEqual(done, { status: 200, body: { act: 'suspend', suspended: true, flagged: 2, cutOff: true } });
  assert.deepEqual(told, [{ tag: 'online', path: '/revoke', account, epoch: 2, why: SUSPENDED_WHY }]);
  // Its devices take nothing up, told why, and an activation from
  // before is turned away at the relay, saying why.
  assert.deepEqual(await inHousehold(env, account, { op: 'activate', key: KEY, account, want: 'take' }), { status: 403, body: { error: SUSPENDED_WHY, suspended: true } });
  assert.deepEqual(await inHousehold(env, account, { op: 'seen', key: KEY, account, epoch: 1, tag: 'pool' }), { status: 409, body: { error: SUSPENDED_WHY } });
  // Let back: a device takes the account up again.
  assert.equal((await carry(store, account, 'lift', {}, { origin: 'https://dev.open-hearts.pages.dev', fetchImpl, wait: 0 })).status, 200);
  assert.equal((await inHousehold(env, account, { op: 'activate', key: KEY, account, want: 'open' })).status, 200);
});

test('an order the store has not got wakes no account', async () => {
  forgetHouseholds();
  const store = await household(1);
  let woken = 0;
  const env = { OH_STORE: kvOf(store), HOUSEHOLD: { idFromName: (n) => n, get: () => (woken++, { fetch: async () => Response.json({}) }) } };
  const ask = (body) => worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/order', { method: 'POST', body }), env);
  assert.equal((await ask(JSON.stringify({ order: 'e'.repeat(32) }))).status, 404);
  assert.equal((await ask(JSON.stringify({ order: 'not one' }))).status, 400);
  assert.equal((await ask('not json')).status, 400);
  assert.equal((await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/order'), env)).status, 405);
  assert.equal(woken, 0);
});

test('asking for a code again is a read: the one outstanding, while it has time', async () => {
  const store = await household(1);
  const counts = { put: 0, list: 0 };
  const kv = kvOf(store, counts);
  const env = { OH_STORE: kv };
  forgetHouseholds();
  const account = await accountOf(store);
  const first = await inHousehold(env, account, { op: 'ticket', key: KEY });
  const writes = counts.put;
  const lists = counts.list;
  for (let i = 0; i < 5; i++) {
    const again = await inHousehold(env, account, { op: 'ticket', key: KEY });
    assert.equal(again.body.ticket, first.body.ticket);
  }
  assert.equal(counts.put, writes, 'no writes');
  assert.equal(counts.list, lists, 'no listings');
  // Spent, or nearly run out: a new one.
  assert.notEqual((await ticketFor(KEY, store, { now: now + 9 * 60000 })).body.ticket, first.body.ticket);
});

test('a household is held to so many changes an hour', async () => {
  let t = now;
  const next = sequencer({ now: () => t });
  const said = [];
  for (let i = 0; i < SERVICE_DEFAULTS.householdChangesPerHour + 3; i++) said.push((await next('change', async () => ({ status: 200 }))).status);
  assert.equal(said.filter((s) => s === 200).length, SERVICE_DEFAULTS.householdChangesPerHour);
  assert.equal(said.at(-1), 429);
  assert.equal((await next('read', async () => ({ status: 200 }))).status, 200, 'reading has its own allowance');
  t += 3600000;
  assert.equal((await next('change', async () => ({ status: 200 }))).status, 200, 'an hour on, room again');
});

test('a body too big to be one of ours is not read', async () => {
  const big = JSON.stringify({ key: KEY, pad: 'x'.repeat(20000) });
  const res = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/licence', { method: 'POST', body: big }), {});
  assert.equal(res.status, 400);
  const event = await worker.fetch(
    new Request('https://dev.open-hearts.pages.dev/api/stripe', { method: 'POST', body: 'x'.repeat(600 * 1024) }),
    { OH_STRIPE_WEBHOOK_SECRET: 'whsec' },
  );
  assert.equal(event.status, 413);
});
