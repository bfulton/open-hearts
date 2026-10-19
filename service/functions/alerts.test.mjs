// The operator's alerts (alerts.mjs): a subscription bought, and a
// subscriber waiting for a person, each told once in its time, to our
// own domain only, and never in the way of what was asked; and a
// player's report of another, told at once whatever the switches say.
// node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';

import { REPORTS_A_DAY, REPORT_NOTE_MOST, alertsOf, alertSubscribed, alertWaiting, reportOf, sendAlert } from './alerts.mjs';
import { copyUrl, pictureDigest } from './pictures.mjs';
import { configEnv } from './deployment.mjs';
import worker from './worker.mjs';
import { Household } from './household.mjs';
import { signerOn } from './licence.mjs';
import { memoryStore } from './rows.mjs';
import { record } from './stripe.mjs';
import { keys } from '../do/sign.mjs';

const KEY = 'ab'.repeat(32);
const on = { OH_ALERTS_TO: 'alerts@openhearts.game', OH_ALERT_SUBSCRIBED: 'on', OH_ALERT_WAITING: 'on' };

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
  const config = JSON.parse('{"alerts":{"to":"alerts@openhearts.game","subscribed":true,"waiting":false,"pictures":true}}');
  assert.deepEqual(alertsOf(configEnv(config)), { to: 'alerts@openhearts.game', subscribed: true, waiting: false, pictures: true });
  assert.equal(alertsOf(configEnv({})), null);
  assert.equal(alertsOf({ ...on, OH_ALERTS_TO: 'someone@example.com' }), null);
});

test('the committed config tells the operator of both', async () => {
  const config = JSON.parse(await readFile(new URL('../../config/openhearts.json', import.meta.url), 'utf8'));
  const alerts = alertsOf(configEnv(config));
  assert.equal(alerts.subscribed, true);
  assert.equal(alerts.waiting, true);
  assert.equal(alerts.pictures, true);
});

/// The account the subscriber's device is on.
const accountOf = async (store) => (await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).account;

test('waiting: told once in a few minutes per subscription, and what it says', async () => {
  const sent = [];
  const store = memoryStore();
  await subscriber(store);
  const account = await accountOf(store);
  const env = { ...on, HOUSEHOLD: relay(sent) };
  const waiting = () => alertWaiting(env, store, { key: KEY, account, pool: 'unrated', target: 100 });
  assert.equal(await waiting(), true);
  assert.equal(await waiting(), false, 'the same few minutes');
  assert.equal(sent.length, 1);
  const [mail] = sent;
  assert.equal(mail.to, 'alerts@openhearts.game');
  assert.equal(mail.from.email, 'noreply@openhearts.game');
  assert.match(mail.text, /Device abababab… on subscription sub_9… is waiting in the unrated pool for a game to 100/);
  assert.equal(store.rows.has('ALERT#waiting|sub_9'), true);
  // Once the row has gone (KV lets it go itself after the time).
  store.rows.delete('ALERT#waiting|sub_9');
  assert.equal(await waiting(), true);
});

test('nothing is told when it is off, or with nobody to send it', async () => {
  const sent = [];
  const store = memoryStore();
  await subscriber(store);
  const account = await accountOf(store);
  const asked = { key: KEY, account, pool: 'rated', target: 50 };
  assert.equal(await alertWaiting({ ...on, OH_ALERT_WAITING: undefined, HOUSEHOLD: relay(sent) }, store, asked), false);
  assert.equal(await alertSubscribed({ ...on, OH_ALERT_SUBSCRIBED: undefined, HOUSEHOLD: relay(sent) }, store, { subscription: 'sub_9', source: 'stripe' }), false);
  assert.equal(await alertWaiting({ ...on }, store, asked), false, 'no HOUSEHOLD');
  assert.equal(await alertWaiting({ ...on, HOUSEHOLD: relay(sent, { EMAIL: undefined }) }, memoryStore(), asked), false, 'no EMAIL');
  assert.equal(sent.length, 0);
});

test('an alert that fails does not throw', async () => {
  const store = memoryStore();
  await subscriber(store);
  const broken = { idFromName: () => 'x', get: () => ({ fetch: async () => { throw new Error('down'); } }) };
  assert.equal(await alertWaiting({ ...on, HOUSEHOLD: broken }, store, { key: KEY, account: await accountOf(store), pool: 'rated', target: 50 }), false);
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

test('a subscriber waiting for a person is told of once; nobody else is, and the answer is the same', async () => {
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
  const ask = async (pair, { pool = 'rated', target = 50 } = {}) => {
    const at = Math.floor(Date.now() / 1000);
    const body = { key: pair.public, at, pool, target, sig: signer.sign(pair.secret, await sha(`oh-request/1\nwaiting\n${pair.public}\n${at}\n${pool} ${target}`)) };
    return worker.fetch(new Request('https://play.openhearts.game/api/waiting', { method: 'POST', headers: { origin: 'https://play.openhearts.game' }, body: JSON.stringify(body) }), env);
  };
  assert.equal((await ask(ada)).status, 200);
  assert.equal((await ask(ada)).status, 200);
  assert.equal(sent.length, 1, 'told once');
  assert.equal(sent[0].subject, 'Open Hearts: someone is waiting for a person');
  assert.match(sent[0].text, new RegExp(`Device ${ada.public.slice(0, 8)}… on subscription sub_9… is waiting in the rated pool for a game to 50`));
  assert.doesNotMatch(sent[0].text, /@/, 'nobody\'s address');
  assert.equal((await ask(keys[2])).status, 402, 'not a subscriber');
  assert.equal((await ask(ada, { pool: 'Rated!' })).status, 400);
  assert.equal((await ask(ada, { target: 0 })).status, 400);
  assert.equal(sent.length, 1);
});

test('a report: who, for what, the table, the name and picture seen, and a short note, or nothing', () => {
  const about = 'b0'.repeat(16);
  assert.deepEqual(reportOf({ about, what: 'picture' }), { about, what: 'picture', table: null, name: null, picture: null, note: '' });
  assert.deepEqual(reportOf({ about: 'cd'.repeat(32), what: 'other', table: 'ef'.repeat(16), name: 'Bao', picture: '01'.repeat(32), note: ' rude ' }), {
    about: 'cd'.repeat(32), what: 'other', table: 'ef'.repeat(16), name: 'Bao', picture: '01'.repeat(32), note: 'rude',
  });
  for (const bad of [
    { about: 'b0'.repeat(15), what: 'name' },
    { about: 'B0'.repeat(16), what: 'name' },
    { about, what: 'face' },
    { about, what: 'name', table: 'nope' },
    { about, what: 'name', name: 'x'.repeat(61) },
    { about, what: 'name', name: 'a\nb' },
    { about, what: 'picture', picture: 'ab' },
    { about, what: 'other', note: 'x'.repeat(REPORT_NOTE_MOST + 1) },
    { about, what: 'other', note: 3 },
    null,
  ]) assert.equal(reportOf(bad), null, JSON.stringify(bad));
  assert.ok(reportOf({ about, what: 'other', note: 'é'.repeat(REPORT_NOTE_MOST) }), 'counted in characters');
});

test('a report reaches the operator at once, switches off or on; once a day each, a few a day, and only from a subscriber', async () => {
  const wasm = await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url));
  const signer = await signerOn(wasm);
  const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
  const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
  const [ada] = keys;
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: ada.public } } } }, store);
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((Date.now() + 300 * 86400000) / 1000) } } }, store);
  const mine = (await store.get(`KEY#${ada.public}`, 'ENTITLEMENT')).account;
  const bao = 'b0'.repeat(16);
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 7]).toString('base64');
  await store.put(`ACCOUNT#${bao}`, 'PROFILE', { name: 'Bao', picture: jpeg });
  const kv = {
    get: async (at, kind) => (store.rows.has(at) ? (kind === 'json' ? JSON.parse(store.rows.get(at)) : store.rows.get(at)) : null),
    put: async (at, raw) => store.rows.set(at, raw),
    delete: async (at) => store.rows.delete(at),
    list: async ({ prefix }) => ({ keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }),
  };
  const sent = [];
  const ASSETS = { fetch: async () => new Response(wasm, { status: 200 }) };
  // Every switch off: a report is not one of them.
  const env = { OH_ALERTS_TO: 'alerts@openhearts.game', ASSETS, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kv, HOUSEHOLD: relay(sent) };
  const sha = async (s) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const ask = async (pair, report, onEnv = env, origin = 'https://play.openhearts.game') => {
    const at = Math.floor(Date.now() / 1000);
    const body = { key: pair.public, at, ...report, sig: signer.sign(pair.secret, await sha(`oh-request/1\nreport\n${pair.public}\n${at}\n${report.about} ${report.what}`)) };
    return worker.fetch(new Request(`${origin}/api/report`, { method: 'POST', headers: { origin }, body: JSON.stringify(body) }), onEnv);
  };
  const digest = await pictureDigest(jpeg);
  const table = 'ef'.repeat(16);
  assert.equal((await ask(ada, { about: bao, what: 'picture', table, picture: digest, name: 'Bao', note: 'not a face' })).status, 200);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, 'alerts@openhearts.game');
  assert.equal(sent[0].subject, "Open Hearts: a player's picture reported");
  const text = sent[0].text;
  assert.match(text, new RegExp(`^Account ${mine} \\(device ${ada.public.slice(0, 8)}…\\) reported account ${bao} for its picture, at .*, at table ${table}\\.`));
  assert.match(text, /What they wrote: not a face/);
  assert.ok(text.includes(`The picture they saw: ${copyUrl(digest)} — its profile picture now`));
  assert.ok(text.includes('The name they saw: Bao — its name now'));
  assert.ok(text.includes(`./oh account remove ${bao} picture --apply`) && text.includes(`./oh account suspend ${bao} --apply`));
  assert.match(text, /handle-abuse-material\.md/);

  // The same report again today: answered the same, not told again.
  assert.equal((await ask(ada, { about: bao, what: 'picture' })).status, 200);
  assert.equal(sent.length, 1);
  // A name since changed is said so.
  await store.put(`ACCOUNT#${bao}`, 'PROFILE', { name: 'Bo', picture: null });
  assert.equal((await ask(ada, { about: bao, what: 'name', name: 'Bao' })).status, 200);
  assert.ok(sent[1].text.includes('The name they saw: Bao — its name now is Bo'));
  assert.equal(sent[1].subject, "Open Hearts: a player's name reported");

  // Nobody to tell: said so, and not counted against the reporter.
  const nobody = { ...env, OH_ALERTS_TO: undefined };
  assert.equal((await ask(ada, { about: bao, what: 'other' }, nobody)).status, 503);
  assert.equal(sent.length, 2);
  // A few a day.
  for (let n = 2; n < REPORTS_A_DAY; n++) assert.equal((await ask(ada, { about: n.toString(16).padStart(32, '0'), what: 'other' })).status, 200, `report ${n + 1}`);
  assert.equal(sent.length, REPORTS_A_DAY);
  assert.equal((await ask(ada, { about: 'f0'.repeat(16), what: 'other' })).status, 429);
  assert.equal(sent.length, REPORTS_A_DAY);

  // Not of oneself, not malformed, and not from a device without a subscription.
  assert.equal((await ask(ada, { about: mine, what: 'name' })).status, 400);
  assert.equal((await ask(ada, { about: bao, what: 'face' })).status, 400);
  assert.equal((await ask(keys[2], { about: bao, what: 'name' })).status, 402);
  assert.equal(sent.length, REPORTS_A_DAY);
  // Local mode answers, and tells nobody.
  assert.equal((await ask(ada, { about: 'e0'.repeat(16), what: 'other' }, { ...env, OH_OPEN_HOUSE: 'on' }, 'http://localhost:8788')).status, 200);
  assert.equal(sent.length, REPORTS_A_DAY);
});
