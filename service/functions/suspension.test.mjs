// An account suspended, let back, and its name or picture taken off and
// put back, each carried out in the account's turn on the operator's
// order (suspension.mjs; docs/how-to/suspend-an-account.md).
// node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { claimWith, entitlementOf, paidFor, ticketFor } from './accounts.mjs';
import { activeInStore, seenAt } from './household.mjs';
import { dayOf, memoryStore } from './rows.mjs';
import { record } from './stripe.mjs';
import { ORDER_KEPT_S, SUSPENDED_WHY, carryOut, orderOf, orderRow } from './suspension.mjs';
import { PICTURES_ROW, WITHHELD_FOR_MS, WITHHELD_WHY, pictureDigest } from './pictures.mjs';
import { pictureScreen } from '../do/withheld.mjs';
import { carry, standing, wouldDo } from '../tool/suspend.mjs';

const KEY = 'ab'.repeat(32);
const OTHER = 'cd'.repeat(32);
const now = Date.now();

/// A subscriber on sub_9 with KEY and a second device, OTHER; and its
/// account.
async function household() {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((now + 300 * 86400000) / 1000) } } }, store, { now });
  await claimWith(OTHER, (await ticketFor(KEY, store, { now })).body.ticket, store, { now });
  return { store, account: (await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).account };
}

/// [act] ordered for [account] as the tool orders it, at [at], and
/// carried out as the account's turn carries it out, at [carried]:
/// {status, body, revoked}.
async function ordered(store, account, act, { active = activeInStore(store), at = now, carried = now, ...options } = {}) {
  const id = `${act.length}`.padStart(2, '0').repeat(16);
  await store.put(...orderRow(id), orderOf(account, act, { ...options, now: at }));
  const revoked = [];
  const out = await carryOut({ op: 'order', account, order: id }, store, active, { now: carried, revoke: async (...args) => revoked.push(args) });
  return { ...out, revoked, id };
}

test('suspended: the account marked, every device refused, and the device in use cut off at the relay, saying why', async () => {
  const { store, account } = await household();
  const active = activeInStore(store);
  await active.put(account, { key: KEY, epoch: 3, at: now, seated: null, tags: ['online', 'pool-a'] });
  const done = await ordered(store, account, 'suspend', { active });
  assert.equal(done.status, 200);
  assert.deepEqual(done.body, { act: 'suspend', suspended: true, flagged: 2, cutOff: true });
  assert.deepEqual(await store.get(`ACCOUNT#${account}`, 'SUSPENDED'), { since: dayOf(now) });
  for (const key of [KEY, OTHER]) {
    assert.equal((await store.get(`KEY#${key}`, 'ENTITLEMENT')).suspended, true);
    assert.equal(await entitlementOf(store, key, { now }), null, 'nothing held: no licence, no activation, no profile');
  }
  // Its sockets closed where it was seen, as a superseded device's are,
  // but saying it is suspended; and the relay told so when it asks.
  assert.deepEqual(done.revoked, [[['online', 'pool-a'], account, 4, SUSPENDED_WHY]]);
  assert.deepEqual(await active.get(account), { key: null, epoch: 4, at: null, seated: null, tags: [], suspended: true });
  assert.deepEqual(await seenAt({ account, key: KEY, epoch: 3, tag: 'online' }, active), { status: 409, body: { error: SUSPENDED_WHY } });
  // The order is spent.
  assert.equal(await store.get(...orderRow(done.id)), null);
  // Ordered again, as the tool does when the first answer is lost: the
  // same end, nothing closed twice.
  const again = await ordered(store, account, 'suspend', { active });
  assert.deepEqual(again.body, { act: 'suspend', suspended: true, flagged: 0, cutOff: false });
  assert.deepEqual(again.revoked, []);
  assert.equal((await active.get(account)).epoch, 4, 'the turn left as it was');
});

test('suspended: a device brought in later is suspended with it, and paying again is no way out', async () => {
  const { store, account } = await household();
  await ordered(store, account, 'suspend');
  // A code from the account brings a device into it, suspended.
  await store.del(`ACCOUNT#${account}`, `DEVICE#${OTHER}`);
  await store.del(`KEY#${OTHER}`, 'ENTITLEMENT');
  const code = (await ticketFor(KEY, store, { now })).body.ticket;
  assert.equal((await claimWith(OTHER, code, store, { now })).status, 200);
  assert.equal((await store.get(`KEY#${OTHER}`, 'ENTITLEMENT')).suspended, true);
  assert.equal(await entitlementOf(store, OTHER, { now }), null);
  // A second subscription bought by one of its devices, its first still
  // paid up, stays with the suspended account rather than making a new
  // one the device would move to.
  await store.put('SUB#sub_10', 'META', { source: 'apple', txn_ref: null, renews_at: dayOf(now + 400 * 86400000), cancelled_at: null });
  assert.equal((await paidFor(store, 'sub_10', KEY, { now })).body.account, account);
  assert.equal(await entitlementOf(store, KEY, { now }), null);
});

test('suspended: a row written before the flag reached it still holds nothing once it runs out', async () => {
  const { store, account } = await household();
  await store.put(`ACCOUNT#${account}`, 'SUSPENDED', { since: dayOf(now) });
  // Run out as the row has it: the account is read on the way, and its
  // mark with it.
  const row = await store.get(`KEY#${KEY}`, 'ENTITLEMENT');
  await store.put(`KEY#${KEY}`, 'ENTITLEMENT', { ...row, licensed_until: dayOf(now - 86400000) });
  assert.equal(await entitlementOf(store, KEY, { now }), null);
});

test('lifted: the mark gone, the devices as they were, and the relay told nothing more of it', async () => {
  const { store, account } = await household();
  const active = activeInStore(store);
  await ordered(store, account, 'suspend', { active });
  const done = await ordered(store, account, 'lift', { active });
  assert.deepEqual(done.body, { act: 'lift', suspended: false, unflagged: 2 });
  assert.equal(await store.get(`ACCOUNT#${account}`, 'SUSPENDED'), null);
  for (const key of [KEY, OTHER]) {
    assert.equal((await store.get(`KEY#${key}`, 'ENTITLEMENT')).suspended, undefined);
    assert.equal((await entitlementOf(store, key, { now })).account, account);
  }
  assert.equal((await active.get(account)).suspended, undefined);
  assert.equal((await seenAt({ account, key: KEY, epoch: 4 }, active)).body.error, 'superseded: another device of this account is in use', 'an old activation is just old');
});

test('a name and a picture taken off, held, and put back, each as a change every device takes', async () => {
  const { store, account } = await household();
  const pk = `ACCOUNT#${account}`;
  await store.put(pk, 'PROFILE', { name: 'Bad Name', icon: 'star', color: 2, picture: '/9j/AAAA', version: 4, updated_at: 'x' });
  const name = await ordered(store, account, 'remove', { name: true });
  assert.deepEqual(name.body, { act: 'remove', removed: ['name'] });
  assert.deepEqual({ ...(await store.get(pk, 'PROFILE')), updated_at: 'x' }, { name: '', icon: 'star', color: 2, picture: '/9j/AAAA', version: 5, updated_at: 'x' });
  const picture = await ordered(store, account, 'remove', { name: true, picture: true });
  assert.deepEqual(picture.body.removed, ['picture'], 'the name is gone already');
  assert.equal((await store.get(pk, 'PROFILE')).picture, null);
  assert.deepEqual({ ...(await store.get(pk, 'HELD')), at: 'x' }, { name: 'Bad Name', picture: '/9j/AAAA', at: 'x' });
  assert.deepEqual((await ordered(store, account, 'remove', { name: true, picture: true })).body.removed, [], 'nothing left to take');
  // Put back, as after a counter-notice.
  const back = await ordered(store, account, 'restore');
  assert.deepEqual(back.body, { act: 'restore', restored: ['name', 'picture'] });
  const profile = await store.get(pk, 'PROFILE');
  assert.equal(profile.name, 'Bad Name');
  assert.equal(profile.picture, '/9j/AAAA');
  assert.equal(profile.version, 7);
  assert.equal(await store.get(pk, 'HELD'), null);
  assert.deepEqual((await ordered(store, account, 'restore')).body.restored, [], 'nothing held');
});

test('a name or picture chosen after one was taken off, and taken off in its turn, is the one put back', async () => {
  const { store, account } = await household();
  const pk = `ACCOUNT#${account}`;
  await store.put(pk, 'PROFILE', { name: 'First', icon: null, color: null, picture: '/9j/AAAA', version: 1 });
  await ordered(store, account, 'remove', { name: true, picture: true });
  await store.put(pk, 'PROFILE', { ...(await store.get(pk, 'PROFILE')), name: 'Second', picture: '/9j/BBBB', version: 3 });
  await ordered(store, account, 'remove', { name: true, picture: true });
  assert.deepEqual({ ...(await store.get(pk, 'HELD')), at: 'x' }, { name: 'Second', picture: '/9j/BBBB', at: 'x' });
  await ordered(store, account, 'restore');
  const profile = await store.get(pk, 'PROFILE');
  assert.deepEqual([profile.name, profile.picture], ['Second', '/9j/BBBB']);
});

test('a picture taken off is withheld at the relay, as the relay sees it in a pool, until it is put back', async () => {
  const { store, account } = await household();
  const pk = `ACCOUNT#${account}`;
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 7, 7, 7, 7]).toString('base64');
  await store.put(pk, 'PROFILE', { name: 'Ada', icon: null, color: null, picture: jpeg, version: 1 });
  // A name taken off is nothing to the relay.
  await ordered(store, account, 'remove', { name: true });
  assert.equal(await store.get(...PICTURES_ROW), null);

  await ordered(store, account, 'remove', { picture: true });
  const row = await store.get(...PICTURES_ROW);
  assert.deepEqual(row, { pictures: [{ sha256: await pictureDigest(jpeg), until: now + WITHHELD_FOR_MS }] });
  // The picture a device of the account puts out in a pool, as it puts
  // it out (packages/table, matching.dart): the one the relay withholds.
  const inPool = { kind: 4244, id: 'e1', content: JSON.stringify({ kind: 'picture', jpeg }) };
  assert.equal(await pictureScreen({ read: () => store.get(...PICTURES_ROW) }).withheld(inPool), WITHHELD_WHY);
  // Carried out again, as after a lost answer: still one listing.
  await ordered(store, account, 'remove', { picture: true });
  assert.equal((await store.get(...PICTURES_ROW)).pictures.length, 1);
  // The player puts the same picture up again, and it is taken off
  // again a day later: still one listing, withheld from then.
  await store.put(pk, 'PROFILE', { ...(await store.get(pk, 'PROFILE')), picture: jpeg, version: 9 });
  await ordered(store, account, 'remove', { picture: true, at: now + 86400000, carried: now + 86400000 });
  assert.deepEqual((await store.get(...PICTURES_ROW)).pictures, [{ sha256: await pictureDigest(jpeg), until: now + 86400000 + WITHHELD_FOR_MS }]);

  // Put back, as after a counter-notice: no longer withheld.
  await ordered(store, account, 'restore');
  assert.deepEqual(await store.get(...PICTURES_ROW), { pictures: [] });
  assert.equal(await pictureScreen({ read: () => store.get(...PICTURES_ROW) }).withheld(inPool), null);
});

test('an order is carried out once, for its own account, while it is fresh', async () => {
  const { store, account } = await household();
  const active = activeInStore(store);
  const go = (op) => carryOut({ op: 'order', ...op }, store, active, { now });
  assert.equal((await go({ account, order: 'f'.repeat(32) })).status, 404, 'none written');
  assert.equal((await go({ account, order: 'nope' })).status, 400);
  await store.put(...orderRow('1'.repeat(32)), orderOf('9'.repeat(32), 'suspend', { now }));
  assert.equal((await go({ account, order: '1'.repeat(32) })).status, 404, "another account's order");
  const stale = await ordered(store, account, 'suspend', { at: now - (ORDER_KEPT_S + 1) * 1000 });
  assert.equal(stale.status, 410);
  assert.equal(await store.get(`ACCOUNT#${account}`, 'SUSPENDED'), null, 'nothing done');
  await store.put(...orderRow('2'.repeat(32)), { account, act: 'delete everything', at: new Date(now).toISOString() });
  assert.equal((await go({ account, order: '2'.repeat(32) })).status, 400);
  // An account that does not exist is not marked.
  const nobody = '9'.repeat(32);
  await store.put(...orderRow('3'.repeat(32)), orderOf(nobody, 'suspend', { now }));
  assert.deepEqual(await go({ account: nobody, order: '3'.repeat(32) }), { status: 404, body: { error: 'no such account' } });
  assert.equal(await store.get(`ACCOUNT#${nobody}`, 'SUSPENDED'), null);
});

test("the operator's tool: says how the account stands, and asks the service until the store has shown it the order", async () => {
  const { store, account } = await household();
  await store.put(`ACCOUNT#${account}`, 'PROFILE', { name: 'N', icon: null, color: null, picture: null, version: 1 });
  const stands = await standing(store, account);
  assert.deepEqual(stands, { exists: true, suspended: null, devices: 2, name: true, picture: false, held: { name: false, picture: false } });
  assert.equal((await standing(store, '9'.repeat(32))).exists, false);
  assert.match(wouldDo('suspend', stands), /would refuse its 2 device\(s\) licences and activations, and cut the one in use off/);
  assert.equal(wouldDo('remove', stands, { picture: true }), 'nothing of that on its profile');
  assert.equal(wouldDo('lift', stands), 'not suspended: nothing to lift');

  const puts = [];
  const watched = { ...store, put: async (pk, sk, value, options) => (puts.push({ pk, options }), store.put(pk, sk, value)) };
  const asked = [];
  const answers = [404, 404, 200];
  const fetchImpl = async (url, init) => {
    asked.push({ url, order: JSON.parse(init.body).order });
    const status = answers.shift();
    return Response.json(status === 200 ? { act: 'suspend' } : { error: 'no such order' }, { status });
  };
  const done = await carry(watched, account, 'suspend', {}, { origin: 'https://service.test', fetchImpl, wait: 0 });
  assert.deepEqual(done, { status: 200, body: { act: 'suspend' } });
  assert.equal(asked.length, 3, 'asked again while the order was not to be found');
  assert.equal(asked[0].url, 'https://service.test/api/order');
  assert.equal(new Set(asked.map((a) => a.order)).size, 1, 'one order, asked about three times');
  assert.deepEqual(puts, [{ pk: `ORDER#${asked[0].order}`, options: { ttl: ORDER_KEPT_S } }], 'written once, to run out by itself');
  assert.deepEqual((await store.get(`ORDER#${asked[0].order}`, 'META')).act, 'suspend');

  // A refusal is the answer; a service never found is given up on.
  assert.equal((await carry(store, account, 'suspend', {}, { origin: 'x', fetchImpl: async () => Response.json({ error: 'no' }, { status: 410 }), wait: 0 })).status, 410);
  let tries = 0;
  const gone = await carry(store, account, 'suspend', {}, { origin: 'x', fetchImpl: async () => (tries++, Promise.reject(new Error('offline'))), tries: 3, wait: 0 });
  assert.equal(tries, 3);
  assert.deepEqual(gone, { status: 0, body: { error: 'offline' } });
});
