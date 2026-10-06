// The operator's alerts (alerts.mjs): a subscription bought, and a
// subscriber online, each told once in its time, to our own domain
// only, and never in the way of what was asked. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';

import { alertOnline, alertsOf, alertSubscribed, hashOf, sendAlert } from './alerts.mjs';
import { configEnv } from './deployment.mjs';
import worker, { Household, memoryStore, record, signerOn } from './worker.mjs';
import { keys } from '../do/sign.mjs';

const KEY = 'ab'.repeat(32);
const on = { OH_ALERTS_TO: 'alerts@openhearts.game', OH_ALERT_SUBSCRIBED: 'on', OH_ALERT_ONLINE: 'on', OH_ALERT_QUIET_MINUTES: '60' };

/// The relay's side: a Household object per name, mailing through a
/// recording EMAIL.
function relay(sent, extra = {}) {
  const env = { EMAIL: { send: async (m) => sent.push(m) }, OH_MAIL_FROM: 'noreply@openhearts.game', ...extra };
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

async function subscriber(store, now = Date.now()) {
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((now + 300 * 86400000) / 1000) } } }, store, { now });
  return store.get(`KEY#${KEY}`, 'ENTITLEMENT');
}

test('the config file turns alerts on, and its address is ours or nobody', () => {
  const config = JSON.parse('{"alerts":{"to":"alerts@openhearts.game","subscribed":true,"online":false,"onlineQuietMinutes":30}}');
  assert.deepEqual(alertsOf(configEnv(config)), { to: 'alerts@openhearts.game', subscribed: true, online: false, quietMinutes: 30, notOnline: [] });
  assert.equal(alertsOf(configEnv({})), null);
  assert.equal(alertsOf({ ...on, OH_ALERTS_TO: 'someone@example.com' }), null);
});

test('the committed config tells the operator of both', async () => {
  const config = JSON.parse(await readFile(new URL('../../config/openhearts.json', import.meta.url), 'utf8'));
  const alerts = alertsOf(configEnv(config));
  assert.equal(alerts.subscribed, true);
  assert.equal(alerts.online, true);
});

test('online: told once in the quiet time per subscription, and what it says', async () => {
  const sent = [];
  const store = memoryStore();
  const held = await subscriber(store);
  const env = { ...on, HOUSEHOLD: relay(sent) };
  assert.equal(await alertOnline(env, store, KEY, held), true);
  assert.equal(await alertOnline(env, store, KEY, held), false, 'the same hour');
  assert.equal(sent.length, 1);
  const [mail] = sent;
  assert.equal(mail.to, 'alerts@openhearts.game');
  assert.equal(mail.from.email, 'noreply@openhearts.game');
  assert.equal(mail.subject, 'Open Hearts: a subscriber is online');
  assert.match(mail.text, /Device abababab… on subscription sub_9…/);
  assert.match(mail.text, /stripe subscription, 1 device, paid up to \d{4}-\d\d-\d\d/);
  assert.equal(store.rows.has('ALERT#online|sub_9'), true);
  // Once the row has gone (KV lets it go itself after the quiet time).
  store.rows.delete('ALERT#online|sub_9');
  assert.equal(await alertOnline(env, store, KEY, held), true);
});

test('nothing is told when it is off, or with nobody to send it', async () => {
  const sent = [];
  const store = memoryStore();
  const held = await subscriber(store);
  assert.equal(await alertOnline({ ...on, OH_ALERT_ONLINE: undefined, HOUSEHOLD: relay(sent) }, store, KEY, held), false);
  assert.equal(await alertSubscribed({ ...on, OH_ALERT_SUBSCRIBED: undefined, HOUSEHOLD: relay(sent) }, store, { subscription: 'sub_9', source: 'stripe' }), false);
  assert.equal(await alertOnline({ ...on }, store, KEY, held), false, 'no HOUSEHOLD');
  assert.equal(await alertOnline({ ...on, HOUSEHOLD: relay(sent, { EMAIL: undefined }) }, memoryStore(), KEY, held), false, 'no EMAIL');
  assert.equal(sent.length, 0);
});

test('a subscription the config names is never told online, and others still are', async () => {
  const sent = [];
  const store = memoryStore();
  const held = await subscriber(store);
  const env = { ...on, OH_ALERT_NOT_ONLINE: `0123456789abcdef,${await hashOf('sub_9')}`, HOUSEHOLD: relay(sent) };
  assert.equal(await alertOnline(env, store, KEY, held), false);
  const other = 'cd'.repeat(16);
  await store.put(`ACCOUNT#${other}`, 'META', { subscription: 'sub_10' });
  assert.equal(await alertOnline(env, store, KEY, { ...held, account: other }), true);
  assert.equal(sent.length, 1);
  assert.equal(await hashOf('sub_9'), (await import('node:crypto')).createHash('sha256').update('sub_9').digest('hex').slice(0, 16));
});

test('an alert that fails does not throw', async () => {
  const store = memoryStore();
  const held = await subscriber(store);
  const broken = { idFromName: () => 'x', get: () => ({ fetch: async () => { throw new Error('down'); } }) };
  assert.equal(await alertOnline({ ...on, HOUSEHOLD: broken }, store, KEY, held), false);
});

test('subscribed: once, however often the webhook comes', async () => {
  const sent = [];
  const store = memoryStore();
  await subscriber(store);
  const env = { ...on, HOUSEHOLD: relay(sent) };
  assert.equal(await alertSubscribed(env, store, { subscription: 'sub_9', source: 'stripe', key: KEY }), true);
  assert.equal(await alertSubscribed(env, store, { subscription: 'sub_9', source: 'stripe', key: KEY }), false);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].subject, 'Open Hearts: a new subscription');
  assert.match(sent[0].text, /A new stripe subscription, sub_9…/);
  assert.match(sent[0].text, /Bought on device abababab…/);
  assert.doesNotMatch(sent[0].text, /@/, 'nobody\'s address');
});

test('the object mails our own domain and nobody else', async () => {
  const sent = [];
  const env = { EMAIL: { send: async (m) => sent.push(m) }, OH_MAIL_FROM: 'noreply@openhearts.game' };
  assert.equal((await sendAlert({ op: 'alert', to: 'victim@example.com', subject: 's', text: 't' }, env)).status, 400);
  assert.equal((await sendAlert({ op: 'alert', to: 'alerts@openhearts.game.example.com', subject: 's', text: 't' }, env)).status, 400);
  assert.equal((await sendAlert({ op: 'alert', to: 'alerts@openhearts.game', subject: 's', text: 't' }, env)).status, 200);
  assert.equal(sent.length, 1);
});

test('the licence route tells of a subscriber; the answer is the same', async () => {
  const wasm = await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url));
  const signer = await signerOn(wasm);
  // BIP-340's published pairs, as worker.test.mjs uses them.
  const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
  const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
  const [ada] = keys;
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: ada.public } } } }, store);
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((Date.now() + 300 * 86400000) / 1000) } } }, store);
  const kv = {
    get: async (at, kind) => (store.rows.has(at) ? (kind === 'json' ? JSON.parse(store.rows.get(at)) : store.rows.get(at)) : null),
    put: async (at, raw) => store.rows.set(at, raw),
    delete: async (at) => store.rows.delete(at),
    list: async ({ prefix }) => ({ keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }),
  };
  const sent = [];
  const ASSETS = { fetch: async () => new Response(wasm, { status: 200 }) };
  const env = { ...on, ASSETS, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kv, HOUSEHOLD: relay(sent) };
  const sha = async (s) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const ask = async () => {
    const at = Math.floor(Date.now() / 1000);
    const body = { key: ada.public, at, sig: signer.sign(ada.secret, await sha(`oh-request/1\nlicence\n${ada.public}\n${at}\n`)) };
    return worker.fetch(new Request('https://openhearts.game/api/licence', { method: 'POST', headers: { origin: 'https://openhearts.game' }, body: JSON.stringify(body) }), env);
  };
  assert.equal((await ask()).status, 200);
  assert.equal((await ask()).status, 200);
  assert.equal(sent.length, 1);
  assert.match(sent[0].text, new RegExp(`Device ${ada.public.slice(0, 8)}… on subscription sub_9…`));
});
