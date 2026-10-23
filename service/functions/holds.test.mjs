// A legal hold (holds.mjs): while it holds, an account's data is kept as
// it is — not deleted, nothing taken off it put back, and nothing held
// overwritten by a later removal.
// node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { forgetAccount } from './deletion.mjs';
import { HOLD_DAYS, Held, hold, holdOf, holdRow, isReportRef } from './holds.mjs';
import { activeInStore } from './household.mjs';
import { dayAfter, dayOf, memoryStore } from './rows.mjs';
import { record } from './stripe.mjs';
import { carryOut, orderOf, orderRow } from './suspension.mjs';

const KEY = 'ab'.repeat(32);
const now = Date.parse('2026-11-02T12:00:00Z');

async function subscriber() {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
  const account = (await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).account;
  await store.put(`ACCOUNT#${account}`, 'PROFILE', { name: 'N', icon: null, color: null, picture: 'AAAA', version: 1 });
  return { store, account };
}

async function ordered(store, account, act, options = {}) {
  const id = `${act.length}`.padStart(2, '0').repeat(16);
  await store.put(...orderRow(id), orderOf(account, act, { ...options, now }));
  return carryOut({ op: 'order', account, order: id }, store, activeInStore(store), { now, revoke: async () => {} });
}

test('a hold: a year from the day it is placed, its report\'s number added later, and its day never moved', async () => {
  const { store, account } = await subscriber();
  const row = await hold(store, account, { now });
  assert.deepEqual(row, { since: '2026-11-02', until: dayAfter(now, HOLD_DAYS), ref: null, deleteAsked: null });
  assert.equal(row.until, '2027-11-02');
  const later = await hold(store, account, { ref: '123456789', now: now + 3 * 86400000 });
  assert.deepEqual(later, { ...row, ref: '123456789' });
  assert.deepEqual(await hold(store, account, { ref: '999', now }), later, 'one report\'s number is kept');
  assert.ok(isReportRef('123456789') && isReportRef('CT-2026-1'));
  for (const bad of ['', 'a b', '<x>', 'x'.repeat(41), 7]) assert.ok(!isReportRef(bad), String(bad));
});

test('held: the account\'s data is not deleted, dry or not, until the hold is released', async () => {
  const { store, account } = await subscriber();
  await hold(store, account, { now });
  await assert.rejects(forgetAccount(store, account), Held);
  await assert.rejects(forgetAccount(store, account, { dry: true }), /held since 2026-11-02, until at least 2027-11-02/);
  assert.ok(await store.get(`ACCOUNT#${account}`, 'PROFILE'), 'nothing deleted');
  await store.del(...holdRow(account));
  assert.ok((await forgetAccount(store, account)).includes(`ACCOUNT#${account}|PROFILE`));
});

test('held: what was taken off is not put back, and a later removal keeps what was held first', async () => {
  const { store, account } = await subscriber();
  assert.equal((await ordered(store, account, 'remove', { picture: true })).status, 200);
  await hold(store, account, { now });
  const restored = await ordered(store, account, 'restore');
  assert.equal(restored.status, 409);
  assert.match(restored.body.error, /held since 2026-11-02: nothing taken off it is put back/);
  assert.equal((await store.get(`ACCOUNT#${account}`, 'PROFILE')).picture, null);
  // A new picture, taken off in its turn: the first stays held.
  const profile = await store.get(`ACCOUNT#${account}`, 'PROFILE');
  await store.put(`ACCOUNT#${account}`, 'PROFILE', { ...profile, picture: 'BBBB', name: 'M' });
  assert.equal((await ordered(store, account, 'remove', { picture: true, name: true })).status, 200);
  const held = await store.get(`ACCOUNT#${account}`, 'HELD');
  assert.equal(held.picture, 'AAAA');
  assert.equal(held.name, 'M', 'a part held for the first time is held as before');
  assert.deepEqual(held.later, [{ picture: 'BBBB', at: new Date(now).toISOString() }]);
  // Not held, the latest is what is held, as before.
  const free = await subscriber();
  await ordered(free.store, free.account, 'remove', { picture: true });
  await free.store.put(`ACCOUNT#${free.account}`, 'PROFILE', { ...(await free.store.get(`ACCOUNT#${free.account}`, 'PROFILE')), picture: 'CCCC' });
  await ordered(free.store, free.account, 'remove', { picture: true });
  assert.equal((await free.store.get(`ACCOUNT#${free.account}`, 'HELD')).picture, 'CCCC');
  assert.equal(await holdOf(free.store, free.account), null);
  assert.equal(dayOf(now), '2026-11-02');
});
