// One household at a time (docs/security-review.md, 9 and 10): a code
// spent twice at once lets one device in; asking for a code again is a
// read; a household is held to so many changes an hour; and a body too
// big to be ours is not read. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker, {
  SERVICE_DEFAULTS,
  Household,
  claimWith,
  devicesOn,
  forgetHouseholds,
  inHousehold,
  memoryStore,
  record,
  sequencer,
  ticketFor,
} from './worker.mjs';

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

/// A subscriber on sub_9 with [n] devices, KEY among them.
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
      if (!objects.has(id)) objects.set(id, new Household({}, env));
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
    const code = (await ticketFor(KEY, store, { now })).body.ticket;
    const both = await Promise.all(['77', '88'].map((b) => inHousehold(env, 'sub_9', { op: 'claim', key: b.repeat(32), code })));
    assert.deepEqual(both.map((c) => c.status).sort(), [200, 409], 'one code, one device');
    assert.equal((await devicesOn(store, 'sub_9')).length, 5);
  });

  test(`${where}: two codes spent at once into the last place let one device in`, async () => {
    forgetHouseholds();
    const store = await household(4);
    const env = { OH_STORE: kvOf(store) };
    if (where === 'in a Durable Object') env.HOUSEHOLD = householdNamespace({ OH_STORE: env.OH_STORE });
    // Two codes made before either is spent: the reuse hands out the
    // outstanding one, so the second is made by hand.
    const first = (await ticketFor(KEY, store, { now })).body.ticket;
    store.rows.delete('SUB#sub_9|TICKET');
    const second = (await ticketFor(KEY, store, { now })).body.ticket;
    assert.notEqual(first, second);
    const both = await Promise.all([
      inHousehold(env, 'sub_9', { op: 'claim', key: '77'.repeat(32), code: first }),
      inHousehold(env, 'sub_9', { op: 'claim', key: '88'.repeat(32), code: second }),
    ]);
    assert.deepEqual(both.map((c) => c.status).sort(), [200, 409]);
    assert.equal((await devicesOn(store, 'sub_9')).length, 5, 'five, not six');
  });
}

test('asking for a code again is a read: the one outstanding, while it has time', async () => {
  const store = await household(1);
  const counts = { put: 0, list: 0 };
  const kv = kvOf(store, counts);
  const env = { OH_STORE: kv };
  forgetHouseholds();
  const first = await inHousehold(env, 'sub_9', { op: 'ticket', key: KEY });
  const writes = counts.put;
  const lists = counts.list;
  for (let i = 0; i < 5; i++) {
    const again = await inHousehold(env, 'sub_9', { op: 'ticket', key: KEY });
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
