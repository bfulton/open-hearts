// An account deleted from the app (worker.mjs, deleteRoute; deletion.mjs,
// deleteAccount): by any of its devices, everything at once — its web
// subscription ended in Stripe, its name off its kept games, its rows,
// and its device in use cut off at the relay. node --test service/functions
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { gunzipSync, gzipSync } from 'node:zlib';
import { test } from 'node:test';

import { DELETED_WHY, deleteAccount } from './deletion.mjs';
import { Household } from './household.mjs';
import { signerOn } from './licence.mjs';
import { forgottenKey } from './records.mjs';
import { memoryStore } from './rows.mjs';
import { record } from './stripe.mjs';
import worker from './worker.mjs';
import { keys } from '../do/sign.mjs';

const wasm = await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url));
const signer = await signerOn(wasm);
const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const [ada, , bao, cy] = keys;
const origin = 'https://play.openhearts.game';
const sha = async (s) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, '0')).join('');

/// KV as the binding answers, over [store]'s rows.
const kvOf = (store) => ({
  get: async (at, kind) => (store.rows.has(at) ? (kind === 'json' ? JSON.parse(store.rows.get(at)) : store.rows.get(at)) : null),
  put: async (at, raw) => store.rows.set(at, raw),
  delete: async (at) => store.rows.delete(at),
  list: async ({ prefix }) => ({ keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }),
});

/// An R2 bucket in memory, as the binding answers: a page of every key.
function bucketOf() {
  const kept = new Map();
  return {
    kept,
    head: async (key) => (kept.has(key) ? { key } : null),
    get: async (key) => (kept.has(key) ? { body: new Blob([kept.get(key).body]).stream(), customMetadata: kept.get(key).custom } : null),
    put: async (key, body, options = {}) => kept.set(key, { body: Buffer.from(typeof body === 'string' ? body : new Uint8Array(body)), custom: options.customMetadata }),
    list: async ({ prefix, include = [] }) => ({
      objects: [...kept.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({ key, ...(include.includes('customMetadata') ? { customMetadata: kept.get(key).custom } : {}) })),
      truncated: false,
    }),
  };
}

/// A subscriber's account with Ada's device on it, paid on the web: a
/// web subscription, its customer, a kept game with her name on it, and
/// her device in use at the relay, on tag t1.
async function subscribed() {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', customer: 'cus_9', metadata: { key: ada.public } } } }, store);
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', customer: 'cus_9', current_period_end: Math.floor((Date.now() + 300 * 86400000) / 1000) } } }, store);
  const account = (await store.get(`KEY#${ada.public}`, 'ENTITLEMENT')).account;
  await store.put(`ACCOUNT#${account}`, 'PROFILE', { name: 'Ada', icon: null, color: null, picture: null, version: 1 });
  const records = bucketOf();
  const game = { v: 2, spec: { id: 'g1', seats: [{ key: ada.public, licence: { account } }, { key: bao.public, licence: { account: 'b0'.repeat(16) } }] }, record: [], names: { 0: 'Ada', 1: 'Bao' } };
  await records.put('tables/g1.json', gzipSync(JSON.stringify(game)), { customMetadata: { from: bao.public, accounts: `${account},${'b0'.repeat(16)}` } });
  // The relay's side: each Household object with storage of its own,
  // the relay objects told of a revocation.
  const states = new Map();
  const revoked = [];
  const sent = [];
  const relayEnv = {
    OH_STORE: kvOf(store),
    EMAIL: { send: async (m) => sent.push(m) },
    OH_MAIL_FROM: 'noreply@openhearts.game',
    TABLE: { idFromName: (n) => n, get: (tag) => ({ fetch: async (_, init) => (revoked.push({ tag, ...JSON.parse(init.body) }), new Response('{}')) }) },
  };
  const objects = new Map();
  const HOUSEHOLD = {
    idFromName: (name) => name,
    get(name) {
      if (!objects.has(name)) {
        const m = new Map();
        states.set(name, m);
        objects.set(name, new Household({ storage: { get: async (k) => m.get(k), put: async (k, v) => m.set(k, v) } }, relayEnv));
      }
      return { fetch: (url, init) => objects.get(name).fetch(new Request(url, init)) };
    },
  };
  HOUSEHOLD.get(account);
  states.get(account).set('active', { key: ada.public, epoch: 3, at: Date.now(), seated: null, tags: ['t1'] });
  const env = {
    ASSETS: { fetch: async () => new Response(wasm, { status: 200 }) },
    OH_SERVICE_SECRET: SERVICE_SECRET,
    OH_SERVICE_KEY: SERVICE_KEY,
    OH_STORE: kvOf(store),
    OH_RECORDS: records,
    OH_STRIPE_SECRET: 'sk_test_x',
    OH_ALERTS_TO: 'alerts@openhearts.game',
    HOUSEHOLD,
  };
  return { store, records, env, account, states, revoked, sent };
}

/// Stripe as its API answers: [status] for each subscription asked
/// about, and what was asked.
function stripeAt(t, status = 'active', { failing = false, missing = false } = {}) {
  const asked = [];
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    asked.push(`${init.method ?? 'GET'} ${url}`);
    if (failing) return new Response('{}', { status: 500 });
    if (missing) return Response.json({ error: { code: 'resource_missing' } }, { status: 404 });
    return Response.json({ status: init.method === 'DELETE' ? 'canceled' : status });
  });
  return asked;
}

async function ask(pair, env) {
  const at = Math.floor(Date.now() / 1000);
  const body = { key: pair.public, at, sig: signer.sign(pair.secret, await sha(`oh-request/1\ndelete\n${pair.public}\n${at}\n`)) };
  return worker.fetch(new Request(`${origin}/api/delete`, { method: 'POST', headers: { origin }, body: JSON.stringify(body) }), env);
}

test('a device deletes its account: the web subscription ends in Stripe, its name comes off its games, its rows go, and its device in use is cut off', async (t) => {
  const { store, records, env, account, states, revoked } = await subscribed();
  const stripe = stripeAt(t);
  const answer = await ask(ada, env);
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), { deleted: true });
  assert.deepEqual(stripe, [
    'GET https://api.stripe.com/v1/subscriptions/sub_9',
    'DELETE https://api.stripe.com/v1/subscriptions/sub_9?cancellation_details%5Bcomment%5D=account+deleted',
  ]);
  assert.ok(records.kept.has(forgottenKey(account)), 'marked, for the games kept from now on');
  assert.deepEqual(JSON.parse(gunzipSync(records.kept.get('tables/g1.json').body)).names, { 1: 'Bao' });
  const left = [...store.rows.keys()].filter((k) => k.includes(account) || k.includes(ada.public) || k.startsWith('SUB#'));
  assert.deepEqual(left, [], 'nothing names the account, its device, or its subscription');
  assert.deepEqual(states.get(account).get('active'), { key: null, epoch: 4, at: null, seated: null, tags: [] }, 'the count goes on, and nothing else is kept');
  assert.deepEqual(revoked, [{ tag: 't1', account, epoch: 4, why: DELETED_WHY }]);
  // Asked again, as a device whose answer was lost asks: no account.
  assert.equal((await ask(ada, env)).status, 404);
  // Stripe's word that the subscription was deleted, which comes next,
  // leaves only the note that it ended: no customer, no account.
  await record({ type: 'customer.subscription.deleted', data: { object: { id: 'sub_9', customer: 'cus_9', status: 'canceled' } } }, store);
  assert.deepEqual([...store.rows.keys()].filter((k) => k.startsWith('SUB#')), ['SUB#sub_9|META']);
  assert.equal((await store.get('SUB#sub_9', 'META')).final, true);
});

test('a subscription already ended in Stripe is not ended again, and only a device on the account may delete it', async (t) => {
  const { store, env, account } = await subscribed();
  const stripe = stripeAt(t, 'canceled');
  assert.equal((await ask(cy, env)).status, 404, 'a device in no account');
  // A device dropped from the account keeps no say, whatever its row
  // still says.
  await store.put(`KEY#${bao.public}`, 'ENTITLEMENT', { account, licensed_until: '2030-01-01' });
  assert.equal((await ask(bao, env)).status, 404);
  assert.deepEqual(stripe, [], 'nothing asked of Stripe for either');
  // One it had before, which Stripe is asked about too; a store's is the
  // store's to end.
  await store.put(`ACCOUNT#${account}`, 'META', { ...(await store.get(`ACCOUNT#${account}`, 'META')), before: ['sub_8', 'GPA.1234'] });
  assert.equal((await ask(ada, env)).status, 200);
  assert.deepEqual(stripe, ['GET https://api.stripe.com/v1/subscriptions/sub_9', 'GET https://api.stripe.com/v1/subscriptions/sub_8']);
});

test('in the account\'s turn, only a device still on the account deletes it', async () => {
  const store = memoryStore();
  const account = 'a0'.repeat(16);
  await store.put(`KEY#${bao.public}`, 'ENTITLEMENT', { account });
  await store.put(`ACCOUNT#${account}`, 'META', { subscription: 'sub_1' });
  const active = { get: async () => null, put: async () => {} };
  // Dropped between the route's look and its turn.
  assert.equal((await deleteAccount({ key: bao.public }, store, active)).status, 404);
  assert.notEqual(await store.get(`ACCOUNT#${account}`, 'META'), null);
  await store.put(`ACCOUNT#${account}`, `DEVICE#${bao.public}`, { added: '2026-01-01' });
  assert.equal((await deleteAccount({ key: bao.public }, store, active)).status, 200);
  assert.equal(await store.get(`ACCOUNT#${account}`, 'META'), null);
});

test('a subscription Stripe has no record of renews nothing, and the account is deleted all the same', async (t) => {
  const { store, env, account } = await subscribed();
  const stripe = stripeAt(t, 'active', { missing: true });
  assert.equal((await ask(ada, env)).status, 200);
  assert.deepEqual(stripe, ['GET https://api.stripe.com/v1/subscriptions/sub_9'], 'nothing to end');
  assert.equal(await store.get(`ACCOUNT#${account}`, 'META'), null);
});

test('Stripe not answering deletes nothing, and the device can ask again', async (t) => {
  const { store, records, env, account } = await subscribed();
  const before = new Map(store.rows);
  stripeAt(t, 'active', { failing: true });
  assert.equal((await ask(ada, env)).status, 502);
  assert.deepEqual(store.rows, before);
  assert.ok(!records.kept.has(forgottenKey(account)));
  assert.deepEqual(JSON.parse(gunzipSync(records.kept.get('tables/g1.json').body)).names, { 0: 'Ada', 1: 'Bao' });
});

test('under a legal hold, the asking is noted and answered the same, and nothing is deleted or ended', async (t) => {
  const { store, records, env, account, revoked } = await subscribed();
  await store.put(`ACCOUNT#${account}`, 'HOLD', { since: '2026-10-01', until: '2027-10-01', ref: '123', deleteAsked: null });
  const before = [...store.rows.keys()].sort();
  const stripe = stripeAt(t);
  const answer = await ask(ada, env);
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), { deleted: true });
  assert.equal((await store.get(`ACCOUNT#${account}`, 'HOLD')).deleteAsked, new Date().toISOString().slice(0, 10));
  assert.deepEqual([...store.rows.keys()].sort(), before);
  assert.deepEqual(stripe, []);
  assert.ok(!records.kept.has(forgottenKey(account)));
  assert.deepEqual(revoked, []);
});

test('a kept game that would not be written back keeps the name, the operator is told, and the rest is deleted', async (t) => {
  const { store, records, env, account, sent } = await subscribed();
  stripeAt(t);
  const odd = `{"v":2,"spec":{"id":"g2","seats":[{"licence":{"account":"${account}"}}]},"record":[{"at":2.0}],"names":{"0":"Ada"}}`;
  await records.put('tables/g2.json', gzipSync(odd), { customMetadata: { accounts: account } });
  assert.equal((await ask(ada, env)).status, 200);
  assert.equal(gunzipSync(records.kept.get('tables/g2.json').body).toString(), odd, 'as it was');
  assert.equal(sent.length, 1);
  assert.match(sent[0].subject, /a deleted account's name is still on a kept game/);
  assert.ok(sent[0].text.includes(account) && sent[0].text.includes('tables/g2.json'));
  assert.equal(await store.get(`ACCOUNT#${account}`, 'META'), null, 'and the account is gone');
});

/// An order as the relay writes one when PhotoDNA matches a picture
/// (service/do/known.mjs), asked of the service.
async function ordered(t, order) {
  const id = 'e'.repeat(32);
  await t.store.put(`ORDER#${id}`, 'META', order);
  return worker.fetch(new Request(`${origin}/api/order`, { method: 'POST', body: JSON.stringify({ order: id }) }), t.env);
}

test("a termination the relay orders on a PhotoDNA match ends the account, and its web subscription in Stripe with nothing refunded; one without the word leaves Stripe alone", async (t) => {
  const s = await subscribed();
  const stripe = stripeAt(t);
  const res = await ordered(s, { account: s.account, act: 'terminate', at: new Date().toISOString(), endWeb: true });
  assert.equal(res.status, 200);
  assert.deepEqual((await res.json()).endedWeb, ['sub_9']);
  assert.deepEqual(stripe, [
    'GET https://api.stripe.com/v1/subscriptions/sub_9',
    'DELETE https://api.stripe.com/v1/subscriptions/sub_9?cancellation_details%5Bcomment%5D=terminated+under+the+terms',
  ]);
  assert.ok((await s.store.get(`ACCOUNT#${s.account}`, 'SUSPENDED')).terminated, 'terminated');
  assert.ok(!stripe.some((a) => a.includes('refund')), 'nothing refunded');

  const plain = await subscribed();
  const quiet = stripeAt(t);
  assert.equal((await ordered(plain, { account: plain.account, act: 'terminate', at: new Date().toISOString() })).status, 200);
  assert.deepEqual(quiet, [], "an operator's own termination ends Stripe from the tool, not here");
});

test("Stripe not answering a relay's termination is a 502, to be ordered again; the account is ended all the same", async (t) => {
  const s = await subscribed();
  stripeAt(t, 'active', { failing: true });
  const res = await ordered(s, { account: s.account, act: 'terminate', at: new Date().toISOString(), endWeb: true });
  assert.equal(res.status, 502);
  assert.ok((await s.store.get(`ACCOUNT#${s.account}`, 'SUSPENDED')).terminated);
  t.mock.restoreAll();
  const again = stripeAt(t);
  assert.equal((await ordered(s, { account: s.account, act: 'terminate', at: new Date().toISOString(), endWeb: true })).status, 200);
  assert.equal(again.filter((a) => a.startsWith('DELETE')).length, 1);
});
