// The Pages worker, in node's own test runner: node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { languages, origin } from '../../site/build.mjs';
import worker from './worker.mjs';
import { accountFor, claimWith, devicesOn, entitlementOf, makeBackups, redeemBackup, ticketFor } from './accounts.mjs';
import { activate, activeInStore, dropDevice, householdOp } from './household.mjs';
import { allowedOrigin, askedBy, requestStatement } from './http.mjs';
import { licence, licenceFor, signerOn } from './licence.mjs';
import { objectsAt, seenFrom } from './places.fixtures.mjs';
import { attest, loginRow } from './logins.mjs';
import { dayAfter, dayOf, memoryStore } from './rows.mjs';
import { SERVICE_DEFAULTS, SITE, forgetSettings, openHouse, useSettings } from './settings.mjs';
import { SUSPENDED_WHY } from './suspension.mjs';
import { forgetProviderKeys, supersede, whoSignedIn } from './signin.mjs';
import { CHECKOUT_LOCALES, STRIPE_VERSION, checkout, checkoutLanguage, endRefunded, manage, record, sameSite, webhookSigned } from './stripe.mjs';
import { stripe as stripeDefinition } from '../../infra/stripe.mjs';
import { STATED, withPrice } from './stripe.fixtures.mjs';
import { mint, serversOf } from './turn.mjs';
import { eventIdOf } from './records.mjs';
import { keys } from '../do/sign.mjs';

const KEY = 'ab'.repeat(32);
const answer = {
  iceServers: [
    { urls: ['stun:stun.cloudflare.com:3478', 'turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:5349?transport=tcp'], username: 'u', credential: 'c' },
  ],
};
const okUpstream = async (url, init) => {
  okUpstream.calls.push({ url, init });
  return new Response(JSON.stringify(answer), { status: 200 });
};
okUpstream.calls = [];
// The same wasm the app signs and verifies with, which the worker
// fetches from the static assets it serves.
const wasm = await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url));
const signer = await signerOn(wasm);

// BIP-340's own test vector, so the pair is published rather than
// derived here: the wasm signs and verifies and does not derive.
const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// Devices that can sign: BIP-340's published pairs again, since a
/// handler acts for a key only on a request that key signed. A
/// device's key is on every event it has said at a table, so anybody
/// can name one; these are the ones a test can also sign for. The
/// second pair is the service's own, above, so it is skipped.
const [ADA, , BAO, CY] = keys;

const sha = async (text) =>
  [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

/// A request as a device makes one (app/lib/net/licence.dart): its
/// key, the second it was made, and its signature over the handler,
/// the key, the second and what it asks for — written out again here
/// rather than borrowed, so that the statement itself is pinned.
const asking = async (pair, handler, { what = '', at = Math.floor(Date.now() / 1000), ...more } = {}) => ({
  key: pair.public,
  at,
  sig: signer.sign(pair.secret, await sha(`oh-request/1\n${handler}\n${pair.public}\n${at}\n${what}`)),
  ...more,
});

/// The hash of BIP-340's first key asking for a code at 1700000000:
/// the same figure is pinned on the app's side, so the two cannot
/// drift apart without both suites saying so.
const REQUEST_VECTOR = '2c77f32dd54af71c904ab632f9d33a5c9fe47242fb2525ced9a01a0988629761';

const assets = {
  fetch: async (url) =>
    String(url).endsWith('/play/schnorr.wasm') ? new Response(wasm, { status: 200 }) : new Response('asset', { status: 200 }),
};
const env = { OH_TURN_KEY_ID: 'kid', OH_TURN_API_TOKEN: 'tok', ASSETS: assets };
const post = (body, origin) =>
  new Request('https://dev.open-hearts.pages.dev/api/turn', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(origin ? { origin } : {}) },
    body: JSON.stringify(body),
  });

test('origins: the site, its branches and a dev machine; nobody else', () => {
  assert.equal(allowedOrigin('https://openhearts.game'), 'https://openhearts.game');
  assert.equal(allowedOrigin('https://www.openhearts.game'), 'https://www.openhearts.game');
  assert.equal(allowedOrigin('https://play.openhearts.game'), 'https://play.openhearts.game', 'the app, at its own host');
  assert.equal(allowedOrigin('https://evil.openhearts.game'), null);
  assert.equal(allowedOrigin('https://openhearts.game.evil.example'), null);
  assert.equal(allowedOrigin('https://openhearts.lol'), null, 'the redirect serves nothing');
  assert.equal(allowedOrigin('https://dev.open-hearts.pages.dev'), 'https://dev.open-hearts.pages.dev');
  assert.equal(allowedOrigin('https://open-hearts.pages.dev'), 'https://open-hearts.pages.dev');
  // A dev machine's own pages, asking a dev machine; never the deployed
  // site, which a page on somebody's localhost has no business calling.
  assert.equal(allowedOrigin('http://localhost:8788', 'http://localhost:8788/api/turn'), 'http://localhost:8788');
  assert.equal(allowedOrigin('http://127.0.0.1:8788', 'http://127.0.0.1:8788/api/turn'), 'http://127.0.0.1:8788');
  assert.equal(allowedOrigin('http://localhost:8788', 'https://dev.open-hearts.pages.dev/api/turn'), null);
  assert.equal(allowedOrigin('http://127.0.0.1:8788'), null);
  // The browser rig's site and app (e2e/drive.mjs), on this machine only.
  assert.equal(allowedOrigin('http://play.openhearts.localhost:8788', 'http://play.openhearts.localhost:8788/api/turn'), 'http://play.openhearts.localhost:8788');
  assert.equal(allowedOrigin('http://play.openhearts.localhost:8788', 'https://play.openhearts.game/api/turn'), null);
  assert.equal(allowedOrigin('https://evil-open-hearts.pages.dev'), null);
  assert.equal(allowedOrigin('https://open-hearts.pages.dev.evil.com'), null);
  assert.equal(allowedOrigin('not a url'), null);
  assert.equal(allowedOrigin(null), null);
});

test('servers: a list or the older single object, urls always a list', () => {
  assert.deepEqual(serversOf(answer), answer.iceServers);
  assert.deepEqual(serversOf({ iceServers: { urls: 'stun:a', username: 'u', credential: 'c' } }), [{ urls: ['stun:a'], username: 'u', credential: 'c' }]);
  assert.deepEqual(serversOf({ iceServers: [{ urls: [] }, { urls: 'stun:b' }] }), [{ urls: ['stun:b'] }]);
  assert.deepEqual(serversOf({}), []);
  assert.deepEqual(serversOf(null), []);
});

test('mint: not configured is said, not guessed', async () => {
  assert.deepEqual(await mint({}, okUpstream), { status: 503, body: { error: 'service not configured: OH_TURN_KEY_ID and OH_TURN_API_TOKEN' } });
  assert.deepEqual(await mint({ OH_TURN_KEY_ID: 'kid' }, okUpstream), { status: 503, body: { error: 'service not configured: OH_TURN_KEY_ID and OH_TURN_API_TOKEN' } });
});

test('mint: credentials from the upstream, with the key and a ttl of four hours', async () => {
  okUpstream.calls.length = 0;
  const out = await mint(env, okUpstream);
  assert.equal(out.status, 200);
  assert.deepEqual(out.body, { iceServers: answer.iceServers, ttl: 4 * 3600 });
  assert.equal(okUpstream.calls.length, 1);
  const { url, init } = okUpstream.calls[0];
  assert.equal(url, 'https://rtc.live.cloudflare.com/v1/turn/keys/kid/credentials/generate-ice-servers');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers.authorization, 'Bearer tok');
  assert.deepEqual(JSON.parse(init.body), { ttl: 4 * 3600 });
});

test('mint: only the OH_-prefixed secret names are read', async () => {
  assert.deepEqual(await mint({ TURN_KEY_ID: 'kid', TURN_API_TOKEN: 'tok' }, okUpstream), {
    status: 503,
    body: { error: 'service not configured: OH_TURN_KEY_ID and OH_TURN_API_TOKEN' },
  });
});

test('mint: an upstream that refuses, is down, or talks nonsense is a bad gateway', async () => {
  assert.deepEqual(await mint(env, async () => new Response('no', { status: 401 })), { status: 502, body: { error: 'turn upstream 401' } });
  assert.deepEqual(await mint(env, async () => { throw new Error('down'); }), { status: 502, body: { error: 'turn upstream unreachable' } });
  assert.deepEqual(await mint(env, async () => new Response('<html>', { status: 200 })), { status: 502, body: { error: 'turn upstream not json' } });
  assert.deepEqual(await mint(env, async () => new Response('{}', { status: 200 })), { status: 502, body: { error: 'turn upstream gave no servers' } });
});

test('the worker: assets pass through, handlers answer, the rest is 404', async () => {
  const asset = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/play/index.html'), env);
  assert.equal(await asset.text(), 'asset');
  const missing = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/nothing'), env);
  assert.equal(missing.status, 404);
  const wrongMethod = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn'), env);
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get('allow'), 'POST, OPTIONS');
});

test('the worker: a preflight from an allowed origin, and none from another', async () => {
  const ok = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'OPTIONS', headers: { origin: 'https://dev.open-hearts.pages.dev' } }), env);
  assert.equal(ok.status, 204);
  assert.equal(ok.headers.get('access-control-allow-origin'), 'https://dev.open-hearts.pages.dev');
  const local = await worker.fetch(new Request('http://127.0.0.1:8788/api/turn', { method: 'OPTIONS', headers: { origin: 'http://127.0.0.1:8788' } }), env);
  assert.equal(local.headers.get('access-control-allow-origin'), 'http://127.0.0.1:8788', 'a dev machine, asking itself');
  const fromLocal = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'OPTIONS', headers: { origin: 'http://127.0.0.1:8788' } }), env);
  assert.equal(fromLocal.headers.get('access-control-allow-origin'), null, 'a localhost page, asking the deployed site');
  assert.equal(ok.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
  const no = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'OPTIONS', headers: { origin: 'https://evil.example' } }), env);
  assert.equal(no.status, 204);
  assert.equal(no.headers.get('access-control-allow-origin'), null);
});

test('the worker: a key is required, then credentials come back, no-store', async () => {
  const bad = await worker.fetch(post({ key: 'short' }), env);
  assert.equal(bad.status, 400);
  const none = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'POST', body: 'not json' }), env);
  assert.equal(none.status, 400);
  // A subscribed device, asking for itself (who is asking, below).
  const held = { ...env, OH_STORE: kvOf(await household(Date.now(), ADA.public)) };
  const realFetch = globalThis.fetch;
  globalThis.fetch = okUpstream;
  try {
    const res = await worker.fetch(post(await asking(ADA, 'turn'), 'https://dev.open-hearts.pages.dev'), held);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('access-control-allow-origin'), 'https://dev.open-hearts.pages.dev');
    const body = await res.json();
    assert.deepEqual(body.iceServers, answer.iceServers);
    assert.equal(body.ttl, 4 * 3600);
    const unconfigured = await worker.fetch(post(await asking(ADA, 'turn')), { ...held, OH_TURN_API_TOKEN: undefined });
    assert.equal(unconfigured.status, 503);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('the worker: local mode hands out its own TURN server, and a deployed origin never does', async () => {
  const local = (body) =>
    new Request('http://127.0.0.1:8788/api/turn', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const rig = { OH_OPEN_HOUSE: '1', OH_TURN_LOCAL: 'turn:127.0.0.1:3478', OH_STORE: kvOf(memoryStore()), ASSETS: assets };
  const res = await worker.fetch(local(await asking(ADA, 'turn')), rig);
  assert.equal(res.status, 200);
  assert.deepEqual((await res.json()).iceServers, [{ urls: ['turn:127.0.0.1:3478'], username: 'rig', credential: 'rig' }]);
  // Set on a deployed project by mistake, it is not open house there, so
  // it is never handed out.
  const held = { ...env, OH_TURN_LOCAL: 'turn:127.0.0.1:3478', OH_STORE: kvOf(await household(Date.now(), ADA.public)) };
  const realFetch = globalThis.fetch;
  globalThis.fetch = okUpstream;
  try {
    const deployed = await worker.fetch(post(await asking(ADA, 'turn')), held);
    assert.deepEqual((await deployed.json()).iceServers, answer.iceServers);
  } finally {
    globalThis.fetch = realFetch;
  }
});

// ---- the licence --------------------------------------------------------

/// The account [subscription] belongs to, and the one [key] is a device of.
const accountOfSub = async (store, subscription) => (await store.get(`SUB#${subscription}`, 'ACCOUNT'))?.account;
const accountOfKey = async (store, key) => (await store.get(`KEY#${key}`, 'ENTITLEMENT'))?.account;

/// The account the tests' stores are made with.
const ACCT = '0a'.repeat(16);

/// A store with the rows a paid-up subscription leaves: its account, the
/// device on it.
const subscribed = (key, { renews_at, licensed_until = renews_at, cancelled_at = null }) =>
  memoryStore({
    [`KEY#${key}|ENTITLEMENT`]: JSON.stringify({ account: ACCT, licensed_until, at: '2026-01-01' }),
    [`ACCOUNT#${ACCT}|META`]: JSON.stringify({ subscription: 'sub_1', created_at: '2026-01-01' }),
    [`ACCOUNT#${ACCT}|DEVICE#${key}`]: JSON.stringify({ bound_at: '2026-01-01' }),
    [`SUB#sub_1|META`]: JSON.stringify({ source: 'stripe', txn_ref: 'cs_1', renews_at, cancelled_at }),
    [`SUB#sub_1|ACCOUNT`]: JSON.stringify({ account: ACCT }),
  });

/// A configured service, whose store each test supplies.
const licensing = () => ({ ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY });

/// storeOf speaks to a KV binding; a Map behind the same two calls is
/// the adapter local mode and these tests use. What each write asked
/// KV for besides the value — an expiry — is kept in [puts].
const kvOf = (store, puts = []) => ({
  get: async (at, kind) => {
    const [pk, sk] = at.split('|');
    const row = await store.get(pk, sk);
    return kind === 'json' ? row : row === null ? null : JSON.stringify(row);
  },
  put: async (at, raw, options) => {
    puts.push({ at, options });
    const [pk, sk] = at.split('|');
    await store.put(pk, sk, JSON.parse(raw));
  },
  delete: async (at) => {
    const [pk, sk] = at.split('|');
    await store.del(pk, sk);
  },
  list: async ({ prefix }) => ({
    keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })),
    list_complete: true,
  }),
});

/// The worker, configured, over [store]; and a way to ask it.
const serving = (store, puts) => ({
  held: { ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kvOf(store, puts) },
  send: (what, body) => new Request(`https://dev.open-hearts.pages.dev/api/${what}`, { method: 'POST', body: JSON.stringify(body) }),
});

test('days: an ISO date in UTC, and a month on from one', () => {
  assert.equal(dayOf(Date.UTC(2026, 8, 16, 23, 59)), '2026-09-16');
  assert.equal(dayAfter(Date.UTC(2026, 8, 16), 31), '2026-10-17');
  assert.equal(dayAfter(Date.UTC(2026, 11, 20), 31), '2027-01-20');
});

test('a licence is signed over the statement the app checks, and only by its own key', async () => {
  const key = KEY;
  const signed = await licenceFor(key, ACCT, '2026-10-17', { signer, secret: SERVICE_SECRET, service: SERVICE_KEY });
  assert.deepEqual({ ...signed, sig: typeof signed.sig }, { key, account: ACCT, until: '2026-10-17', plan: 'year', sig: 'string' });
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`oh-licence/2\n${key}\n${ACCT}\n2026-10-17\nyear`));
  const digestHex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  assert.equal(signer.verify(SERVICE_KEY, digestHex, signed.sig), true);
  // Another service's key does not verify it, which is the whole point
  // of the app having one baked in.
  const other = 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
  assert.equal(signer.verify(other, digestHex, signed.sig), false);
});

test('a secret and a public key that are not a pair is a refusal, not a licence nobody can read', async () => {
  const wrong = 'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9';
  assert.equal(await licenceFor(KEY, ACCT, '2026-10-17', { signer, secret: wrong, service: SERVICE_KEY }), null);
});

test('entitlement: one read while the device is paid up', async () => {
  const store = subscribed(KEY, { renews_at: '2027-01-01' });
  const held = await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16) });
  assert.equal(held.account, ACCT);
  assert.equal(held.licensed_until, '2027-01-01');
});

test('entitlement: a renewal moves the subscription on, and the device catches up on its own next ask', async () => {
  // The device's row says it ran out in June; the subscription was
  // renewed to next January without touching the devices under it.
  const store = subscribed(KEY, { renews_at: '2027-01-01', licensed_until: '2026-06-01' });
  const held = await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16) });
  assert.equal(held.licensed_until, '2027-01-01');
  // And it is written back, so the next ask is one read again.
  assert.equal((await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).licensed_until, '2027-01-01');
});

test('entitlement: a subscription that stopped being renewed runs out, and nothing is issued after', async () => {
  const store = subscribed(KEY, { renews_at: '2026-06-01', cancelled_at: '2026-03-02' });
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16) }), null);
  // Up to that date it is a subscription like any other: cancelling is
  // not a refund, and the rest of the year was paid for.
  const before = await entitlementOf(store, KEY, { now: Date.UTC(2026, 4, 30) });
  assert.equal(before.licensed_until, '2026-06-01');
});

test('a licence lasts as many days as the service\'s setting, and never past the subscription', async (t) => {
  t.after(forgetSettings);
  useSettings({ licenceDays: 7 });
  const store = memoryStore();
  const open = await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16), openHouse: true });
  assert.equal(open.licensed_until, '2026-09-23');
});

test('entitlement: a key nobody has heard of gets nothing, unless it is local mode', async () => {
  const store = memoryStore();
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16) }), null);
  const open = await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16), openHouse: true });
  assert.equal(open.licensed_until, '2026-10-17');
  // And it is an account with a subscription and the device bound under
  // it, like any other, rather than a special case further down.
  assert.match(open.account, /^[0-9a-f]{32}$/);
  assert.deepEqual(await store.get(`ACCOUNT#${open.account}`, `DEVICE#${KEY}`), { bound_at: '2026-09-16' });
  assert.equal((await store.get(`ACCOUNT#${open.account}`, 'META')).subscription, `local-${KEY.slice(0, 16)}`);
});

test('the licence: a month, and never past what was paid for', async () => {
  const now = Date.UTC(2026, 8, 16);
  const far = await licence(KEY, { ...licensing(), OH_STORE: kvOf(subscribed(KEY, { renews_at: '2027-01-01' })) }, { signer, now });
  assert.equal(far.status, 200);
  assert.equal(far.body.licence.until, '2026-10-17', 'a month');
  const near = await licence(KEY, { ...licensing(), OH_STORE: kvOf(subscribed(KEY, { renews_at: '2026-09-20' })) }, { signer, now });
  assert.equal(near.body.licence.until, '2026-09-20', 'and no further than the subscription');
});

test('the licence: no subscription is 402, and a service half-configured is 503', async () => {
  const now = Date.UTC(2026, 8, 16);
  const none = await licence(KEY, { ...licensing(), OH_STORE: kvOf(memoryStore()) }, { signer, now });
  assert.equal(none.status, 402);
  assert.deepEqual(none.body, { error: 'no subscription' });
  const store = kvOf(subscribed(KEY, { renews_at: '2027-01-01' }));
  for (const missing of ['OH_SERVICE_SECRET', 'OH_SERVICE_KEY', 'OH_STORE']) {
    const out = await licence(KEY, { ...licensing(), OH_STORE: store, [missing]: undefined }, { signer, now });
    assert.equal(out.status, 503, missing);
  }
});

test('the licence: a suspended account is told so, apart from having no subscription', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = subscribed(KEY, { renews_at: '2027-01-01' });
  await store.put(`KEY#${KEY}`, 'ENTITLEMENT', { ...(await store.get(`KEY#${KEY}`, 'ENTITLEMENT')), suspended: true });
  const out = await licence(KEY, { ...licensing(), OH_STORE: kvOf(store) }, { signer, now });
  assert.deepEqual(out, { status: 403, body: { error: SUSPENDED_WHY, suspended: true } });
});

test('the licence route: a key is required, and what comes back verifies', async () => {
  const at = 'https://dev.open-hearts.pages.dev/api/licence';
  const withStore = { ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kvOf(subscribed(ADA.public, { renews_at: '2027-01-01' })) };
  const bad = await worker.fetch(new Request(at, { method: 'POST', body: JSON.stringify({ key: 'short' }) }), withStore);
  assert.equal(bad.status, 400);
  const res = await worker.fetch(
    new Request(at, { method: 'POST', headers: { origin: 'https://dev.open-hearts.pages.dev' }, body: JSON.stringify(await asking(ADA, 'licence')) }),
    withStore,
  );
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('access-control-allow-origin'), 'https://dev.open-hearts.pages.dev');
  const { licence: signed } = await res.json();
  assert.equal(signed.key, ADA.public);
  assert.equal(signed.account, ACCT);
  assert.equal(signed.plan, 'year');
  const canonical = `oh-licence/2\n${signed.key}\n${signed.account}\n${signed.until}\n${signed.plan}`;
  const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical)))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  assert.equal(signer.verify(SERVICE_KEY, digest, signed.sig), true);
});

// ---- buying -------------------------------------------------------------

test('where a buyer may be sent back to: this site, and nowhere else', () => {
  const at = 'https://dev.open-hearts.pages.dev/api/checkout';
  assert.equal(sameSite('https://dev.open-hearts.pages.dev/play/?bought=1', at), 'https://dev.open-hearts.pages.dev/play/?bought=1');
  assert.equal(sameSite('/play/', at), 'https://dev.open-hearts.pages.dev/play/');
  assert.equal(sameSite('https://evil.example/paid', at), null);
  assert.equal(sameSite('https://open-hearts.pages.dev/play/', at), null, 'another branch is another origin');
  assert.equal(sameSite(undefined, at), null);
});

test('checkout: a subscription session carrying the key three ways', async () => {
  const calls = [];
  const stripe = async (url, init) => {
    calls.push({ url, init });
    return new Response(JSON.stringify({ url: 'https://checkout.stripe.com/c/pay/cs_test_1' }), { status: 200 });
  };
  const shop = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'price_1', OH_PRICE: STATED };
  const out = await checkout(KEY, 'https://x/play/?bought=1', 'https://x/play/', shop, withPrice(stripe));
  assert.deepEqual(out, { status: 200, body: { url: 'https://checkout.stripe.com/c/pay/cs_test_1' } });
  assert.equal(calls[0].url, 'https://api.stripe.com/v1/checkout/sessions');
  assert.equal(calls[0].init.headers.authorization, 'Bearer sk_test');
  assert.equal(calls[0].init.headers['stripe-version'], STRIPE_VERSION, "in the webhook's API version, not the account's");
  const form = new URLSearchParams(calls[0].init.body);
  assert.equal(form.get('mode'), 'subscription');
  assert.equal(form.get('managed_payments[enabled]'), 'true', 'sold by Link, Stripe\'s merchant of record');
  for (const field of ['automatic_tax[enabled]', 'tax_id_collection[enabled]', 'payment_method_types[0]', 'customer_update[address]', 'invoice_creation[enabled]']) {
    assert.equal(form.get(field), null, `${field} is Stripe's to set in a Managed Payments checkout`);
  }
  assert.equal(form.get('line_items[0][price]'), 'price_1');
  assert.equal(form.get('success_url'), 'https://x/play/?bought=1');
  assert.equal(form.get('metadata[key]'), KEY);
  assert.equal(form.get('client_reference_id'), KEY);
  assert.equal(form.get('subscription_data[metadata][key]'), KEY, 'so a renewal a year from now still names the device');
  assert.equal(form.get('subscription_data[metadata][lang]'), 'en', 'and the language a change to the terms is told in');
  // Dressed as the app, with the site's own icon.
  assert.equal(form.get('branding_settings[display_name]'), 'Open Hearts');
  assert.equal(form.get('branding_settings[icon][url]'), 'https://x/icon-512.png');
  assert.equal(form.get('branding_settings[background_color]'), '#06231A');
  assert.equal(form.get('branding_settings[button_color]'), '#E4B363');
  // In English when the app asked in no language. Nothing is paid until
  // the buyer ticks Stripe's box agreeing to the terms; its words are
  // Stripe's, since Stripe refuses a Managed Payments checkout with
  // custom text.
  assert.equal(form.get('locale'), 'en');
  assert.equal(form.get('consent_collection[terms_of_service]'), 'required');
  for (const field of [...form.keys()]) assert.ok(!field.startsWith('custom_text'), `${field}: Stripe refuses it with Managed Payments`);
});

test('the service calls Stripe in the API version its webhook is read in', () => {
  assert.equal(STRIPE_VERSION, stripeDefinition.webhooks[0].apiVersion);
  assert.ok(STRIPE_VERSION >= '2025-03-31.basil', 'which Managed Payments needs');
});

/// Stripe, for a refund: the payment's invoice, the invoice's
/// subscription and the subscription's status, as [had] says; each call
/// noted in [calls].
function refundStripe({ invoice = 'in_1', subscription = 'sub_9', status = 'active', down = false } = {}) {
  const calls = [];
  const fake = async (url, init = {}) => {
    const at = new URL(String(url));
    calls.push({ method: init.method ?? 'GET', path: at.pathname, query: Object.fromEntries(at.searchParams), version: init.headers?.['stripe-version'] });
    if (down) return Response.json({ error: {} }, { status: 500 });
    if (at.pathname === '/v1/invoice_payments') return Response.json({ data: invoice ? [{ invoice, payment: { type: 'payment_intent', payment_intent: at.searchParams.get('payment[payment_intent]') } }] : [] });
    if (at.pathname === `/v1/invoices/${invoice}`) return Response.json({ id: invoice, parent: subscription ? { type: 'subscription_details', subscription_details: { subscription } } : null });
    if (at.pathname === `/v1/subscriptions/${subscription}`) return Response.json({ id: subscription, status: init.method === 'DELETE' ? 'canceled' : status });
    return Response.json({ error: {} }, { status: 404 });
  };
  fake.calls = calls;
  return fake;
}

const refunded = (more = {}) => ({ id: 'ch_1', object: 'charge', payment_intent: 'pi_1', amount: 599, amount_refunded: 599, ...more });

test('a refund of a payment for a subscription of ours ends it at once', async () => {
  const store = memoryStore();
  await store.put('SUB#sub_9', 'META', { source: 'stripe' });
  const shop = { OH_STRIPE_SECRET: 'rk_test' };
  const stripe = refundStripe();
  assert.deepEqual(await endRefunded(refunded(), store, shop, stripe), { status: 200, body: { ended: true, subscription: 'sub_9' } });
  assert.deepEqual(
    stripe.calls.map((c) => `${c.method} ${c.path}`),
    ['GET /v1/invoice_payments', 'GET /v1/invoices/in_1', 'GET /v1/subscriptions/sub_9', 'DELETE /v1/subscriptions/sub_9'],
  );
  assert.deepEqual(stripe.calls[0].query, { 'payment[type]': 'payment_intent', 'payment[payment_intent]': 'pi_1', limit: '10' });
  assert.equal(stripe.calls[3].query['cancellation_details[comment]'], 'refunded');
  assert.ok(stripe.calls.every((c) => c.version === STRIPE_VERSION));
  const part = refundStripe();
  assert.equal((await endRefunded(refunded({ amount_refunded: 100 }), store, shop, part)).body.ended, true, 'a part refunded is a refund too, as the terms say');
});

test('a refund ends nothing twice, and nothing that is not ours', async () => {
  const store = memoryStore();
  await store.put('SUB#sub_9', 'META', { source: 'stripe' });
  const shop = { OH_STRIPE_SECRET: 'rk_test' };
  const ended = refundStripe({ status: 'canceled' });
  assert.deepEqual(await endRefunded(refunded(), store, shop, ended), { status: 200, body: { ended: false, subscription: 'sub_9' } });
  assert.ok(!ended.calls.some((c) => c.method === 'DELETE'), 'ended already, by the refund that ended it first');
  for (const [why, stripe, charge] of [
    ['a subscription this service did not sell', refundStripe({ subscription: 'sub_other' }), refunded()],
    ['a payment no invoice was for', refundStripe({ invoice: null }), refunded()],
    ['an invoice no subscription made', refundStripe({ subscription: null }), refunded()],
    ['nothing refunded', refundStripe(), refunded({ amount_refunded: 0 })],
    ['no payment intent', refundStripe(), refunded({ payment_intent: null })],
  ]) {
    assert.deepEqual(await endRefunded(charge, store, shop, stripe), { status: 200, body: { ended: null } }, why);
    assert.ok(!stripe.calls.some((c) => c.method === 'DELETE'), why);
  }
  assert.equal((await endRefunded(refunded(), store, shop, refundStripe({ down: true }))).status, 502, 'Stripe not saying is asked again');
  assert.equal((await endRefunded(refunded(), store, {}, refundStripe())).status, 503);
});

test('the webhook route: a refund ends the subscription, and is sent again when Stripe could not be asked', async () => {
  const store = memoryStore();
  await store.put('SUB#sub_9', 'META', { source: 'stripe' });
  const shop = { ...env, OH_STRIPE_WEBHOOK_SECRET: SIGNING, OH_STORE: kvOf(store), OH_STRIPE_SECRET: 'rk_test' };
  const at = 'https://dev.open-hearts.pages.dev/api/stripe';
  const raw = JSON.stringify({ type: 'charge.refunded', data: { object: refunded() } });
  const send = () => worker.fetch(new Request(at, { method: 'POST', headers: { 'stripe-signature': 'x' }, body: raw }), shop);
  const realFetch = globalThis.fetch;
  try {
    const stripe = refundStripe();
    globalThis.fetch = stripe;
    const signed = async () => worker.fetch(new Request(at, { method: 'POST', headers: { 'stripe-signature': await signHook(raw) }, body: raw }), shop);
    assert.equal((await send()).status, 400, 'unsigned, nothing is asked of Stripe');
    assert.equal(stripe.calls.length, 0);
    assert.equal((await signed()).status, 200);
    assert.ok(stripe.calls.some((c) => c.method === 'DELETE' && c.path === '/v1/subscriptions/sub_9'));
    globalThis.fetch = refundStripe({ down: true });
    assert.equal((await signed()).status, 502);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('checkout: in the language the app asked in, and the subscription marked with it', async () => {
  const forms = [];
  const stripe = async (_, init) => {
    forms.push(new URLSearchParams(init.body));
    return new Response(JSON.stringify({ url: 'https://checkout.stripe.com/c/pay/cs_test_1' }), { status: 200 });
  };
  const shop = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'price_1', OH_PRICE: STATED };
  for (const lang of ['pt', 'de', 'xx', { toString: () => 'es' }]) {
    assert.equal((await checkout(KEY, 'https://x/', 'https://x/', shop, withPrice(stripe), { lang })).status, 200);
  }
  const [pt, de, xx, notAString] = forms;
  assert.equal(pt.get('locale'), 'pt-BR', "the site's Portuguese is Brazil's");
  assert.equal(pt.get('subscription_data[metadata][lang]'), 'pt');
  assert.equal(xx.get('subscription_data[metadata][lang]'), 'en');
  assert.equal(de.get('locale'), 'de');
  assert.equal(de.get('subscription_data[metadata][lang]'), 'de');
  for (const other of [xx, notAString]) assert.equal(other.get('locale'), 'en', 'a language the site has not got is English');
});

test("checkout: the site's languages, each in the locale its pages are in", () => {
  assert.equal(SITE, origin);
  assert.deepEqual(CHECKOUT_LOCALES, Object.fromEntries(languages.map((l) => [l.code, l.lang])));
  for (const l of languages) assert.deepEqual(checkoutLanguage(l.code), { locale: l.lang, 'subscription_data[metadata][lang]': l.code });
});

test('checkout: no keys is a shop that is not open, not a broken one', async () => {
  assert.deepEqual(await checkout(KEY, 'https://x/', 'https://x/', {}), { status: 503, body: { error: 'the shop is not open yet' } });
  const refused = await checkout(KEY, 'https://x/', 'https://x/', { OH_STRIPE_SECRET: 's', OH_STRIPE_PRICE: 'p', OH_PRICE: STATED }, async () => new Response('no', { status: 401 }));
  assert.equal(refused.status, 502);
});

// ---- the webhook --------------------------------------------------------

const SIGNING = 'whsec_test';
const signHook = async (raw, { at = Date.now(), secret = SIGNING } = {}) => {
  const t = Math.floor(at / 1000);
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = [...new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${raw}`)))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return `t=${t},v1=${mac}`;
};

test('the webhook is read only when Stripe signed it, and not from last week', async () => {
  const raw = JSON.stringify({ type: 'ping' });
  assert.equal(await webhookSigned(await signHook(raw), raw, SIGNING), true);
  assert.equal(await webhookSigned(await signHook(raw), `${raw} `, SIGNING), false, 'a body edited in flight');
  assert.equal(await webhookSigned(await signHook(raw, { secret: 'whsec_other' }), raw, SIGNING), false);
  assert.equal(await webhookSigned(await signHook(raw, { at: Date.now() - 86400000 }), raw, SIGNING), false, 'a replay is not a payment');
  assert.equal(await webhookSigned(null, raw, SIGNING), false);
  useSettings({ webhookToleranceS: 60 });
  assert.equal(await webhookSigned(await signHook(raw, { at: Date.now() - 120000 }), raw, SIGNING), false, 'two minutes late, by a one-minute setting');
  forgetSettings();
  assert.equal(await webhookSigned(await signHook(raw, { at: Date.now() - 120000 }), raw, SIGNING), true, 'and in time by the default five');
  assert.equal(await webhookSigned('t=1,v1=nope', raw, SIGNING), false);
  assert.equal(await webhookSigned(await signHook(raw), raw, undefined), false, 'unconfigured takes nothing');
});

test('a paid checkout binds the device; the subscription says how long for', async () => {
  const store = memoryStore();
  const now = Date.UTC(2026, 8, 16);
  // The session lands first, which is the usual order and the awkward
  // one: nothing here knows the date yet.
  await record(
    { type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } },
    store,
    { now },
  );
  // An account made for it, with the device that paid on it.
  const account = await accountOfSub(store, 'sub_9');
  assert.match(account, /^[0-9a-f]{32}$/);
  assert.deepEqual(await store.get(`ACCOUNT#${account}`, `DEVICE#${KEY}`), { bound_at: '2026-09-16' });
  assert.equal((await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).account, account);
  assert.equal((await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).licensed_until, null);
  // Nothing is licensed on a date nobody has given.
  assert.equal(await entitlementOf(store, KEY, { now }), null);

  // Then the subscription's own event, with the date on it.
  await record(
    {
      type: 'customer.subscription.created',
      data: { object: { id: 'sub_9', current_period_end: Math.floor(Date.UTC(2027, 8, 16) / 1000), latest_invoice: 'in_1' } },
    },
    store,
    { now },
  );
  const held = await entitlementOf(store, KEY, { now });
  assert.equal(held.licensed_until, '2027-09-16');
  const out = await licence(KEY, { ...licensing(), OH_STORE: kvOf(store) }, { signer, now });
  assert.equal(out.status, 200);
  assert.equal(out.body.licence.until, '2026-10-17');
});

test('a subscription Stripe ends is over today, and nothing is issued after', async () => {
  const store = memoryStore();
  const now = Date.UTC(2026, 8, 16);
  await record({ type: 'checkout.session.completed', data: { object: { status: 'complete', payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor(Date.UTC(2027, 8, 16) / 1000) } } }, store, { now });
  assert.equal((await entitlementOf(store, KEY, { now })).licensed_until, '2027-09-16');
  await record({ type: 'customer.subscription.deleted', data: { object: { id: 'sub_9' } } }, store, { now: Date.UTC(2026, 9, 1) });
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 9, 2) }), null);
});

test('a webhook that is not ours is taken and not acted on', async () => {
  const store = memoryStore();
  assert.equal(await record({ type: 'invoice.created', data: { object: { id: 'in_1' } } }, store), null);
  assert.equal(await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'unpaid', subscription: 'sub_9', metadata: { key: KEY } } } }, store), null);
  assert.equal(await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: 'nope' } } } }, store), null);
  assert.equal(store.rows.size, 0);
});

test('only a checkout this service made, and paid for, binds a device', async () => {
  const store = memoryStore();
  // A Payment Link, or any other checkout on the account: a key in the
  // URL's client_reference_id, none in the metadata only we write.
  assert.equal(await record({ type: 'checkout.session.completed', data: { object: { status: 'complete', payment_status: 'paid', subscription: 'sub_x', client_reference_id: KEY } } }, store), null);
  // Complete, with a delayed method's money still to come.
  assert.equal(await record({ type: 'checkout.session.completed', data: { object: { status: 'complete', payment_status: 'unpaid', subscription: 'sub_9', metadata: { key: KEY } } } }, store), null);
  // Not a subscription at all.
  assert.equal(await record({ type: 'checkout.session.completed', data: { object: { mode: 'payment', payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store), null);
  assert.equal(store.rows.size, 0);
  // And the delayed money, when it comes.
  const bound = await record({ type: 'checkout.session.async_payment_succeeded', data: { object: { mode: 'subscription', payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store);
  assert.deepEqual(bound, { bound: KEY, subscription: 'sub_9', account: await accountOfSub(store, 'sub_9'), status: 200 });
});

test('the webhook route: unsigned is refused, signed is recorded and acknowledged', async () => {
  const store = memoryStore();
  const shop = { ...env, OH_STRIPE_WEBHOOK_SECRET: SIGNING, OH_STORE: kvOf(store) };
  const at = 'https://dev.open-hearts.pages.dev/api/stripe';
  const raw = JSON.stringify({
    type: 'customer.subscription.created',
    data: { object: { id: 'sub_9', current_period_end: Math.floor(Date.UTC(2027, 8, 16) / 1000) } },
  });
  const forged = await worker.fetch(new Request(at, { method: 'POST', headers: { 'stripe-signature': 't=1,v1=00' }, body: raw }), shop);
  assert.equal(forged.status, 400);
  assert.equal(store.rows.size, 0, 'nothing is read out of a body nobody signed');
  const ok = await worker.fetch(
    new Request(at, { method: 'POST', headers: { 'stripe-signature': await signHook(raw) }, body: raw }),
    shop,
  );
  assert.equal(ok.status, 200);
  assert.equal((await store.get('SUB#sub_9', 'META')).renews_at, '2027-09-16');
});

test('the webhook route: a checkout paid for makes the backup codes and emails them to the payer', async () => {
  const store = memoryStore();
  const got = [];
  const shop = {
    ...env,
    OH_STRIPE_WEBHOOK_SECRET: SIGNING,
    OH_STORE: kvOf(store),
    EMAIL: { send: async (m) => got.push(m) },
    OH_MAIL_FROM: 'noreply@openhearts.game',
  };
  const at = 'https://dev.open-hearts.pages.dev/api/stripe';
  const raw = JSON.stringify({
    type: 'checkout.session.completed',
    data: {
      object: {
        mode: 'subscription',
        payment_status: 'paid',
        subscription: 'sub_9',
        customer: 'cus_1',
        customer_details: { email: 'payer@example.com' },
        metadata: { key: KEY },
        amount_total: 599,
        currency: 'usd',
      },
    },
  });
  const hook = async () =>
    worker.fetch(new Request(at, { method: 'POST', headers: { 'stripe-signature': await signHook(raw) }, body: raw }), shop);
  assert.equal((await hook()).status, 200);
  assert.equal(got.length, 1);
  assert.equal(got[0].to, 'payer@example.com');
  const account = await accountOfSub(store, 'sub_9');
  const row = await store.get(`ACCOUNT#${account}`, 'BACKUP');
  for (const c of row.codes) assert.match(got[0].text, new RegExp(c.code));
  // With what was bought, that it renews and at what, and how to stop
  // it, in a copy the payer keeps.
  assert.equal(got[0].subject, 'Your Open Hearts subscription');
  assert.match(got[0].text, /You paid \$5\.99 USD for a year of it\./);
  assert.match(got[0].text.replace(/\s+/g, ' '), /renews automatically every year, on the date you subscribed, at the price then in force, until you cancel/);
  assert.match(got[0].text.replace(/\s+/g, ' '), /menu, then Subscription, then Manage subscription/);
  assert.match(got[0].html, /<a href="https:\/\/openhearts\.game\/terms">/);
  // Stripe delivers again: nothing new is made or sent, and the account
  // is the same one.
  assert.equal((await hook()).status, 200);
  assert.equal(got.length, 1);
  assert.equal(await accountOfSub(store, 'sub_9'), account);
  assert.deepEqual((await store.get(`ACCOUNT#${account}`, 'BACKUP')).codes, row.codes);

  // The subscription ended a while ago, and the same device buys
  // again: the same account, and the new purchase is told of as the
  // first was.
  const sub = await store.get('SUB#sub_9', 'META');
  await store.put('SUB#sub_9', 'META', { ...sub, renews_at: '2026-01-01', cancelled_at: '2026-01-01', final: true });
  const again = JSON.parse(raw);
  again.data.object.subscription = 'sub_10';
  const body = JSON.stringify(again);
  const bought = await worker.fetch(new Request(at, { method: 'POST', headers: { 'stripe-signature': await signHook(body) }, body }), shop);
  assert.equal(bought.status, 200);
  assert.equal(await accountOfSub(store, 'sub_10'), account);
  assert.equal(got.length, 2);
  assert.equal(got[1].subject, 'Your Open Hearts subscription');
  assert.match(got[1].text, /You paid \$5\.99 USD for a year of it\./);
});

/// [kv], with each call taking a few milliseconds, as KV's calls are
/// real I/O: what two requests at once can interleave on.
const slowly = (kv) =>
  Object.fromEntries(
    Object.entries(kv).map(([name, call]) => [name, async (...args) => (await new Promise((done) => setTimeout(done, 2)), call(...args))]),
  );

/// A paid checkout of sub_race by [KEY], as Stripe delivers it.
const paidCheckout = (subscription = 'sub_race') =>
  JSON.stringify({
    type: 'checkout.session.completed',
    data: {
      object: {
        mode: 'subscription',
        payment_status: 'paid',
        subscription,
        customer: 'cus_1',
        customer_details: { email: 'payer@example.com' },
        metadata: { key: KEY },
      },
    },
  });

test('the webhook route: one checkout delivered twice at once makes one account, and one email', async () => {
  const store = memoryStore();
  const got = [];
  const shop = {
    ...env,
    OH_STRIPE_WEBHOOK_SECRET: SIGNING,
    OH_STORE: slowly(kvOf(store)),
    EMAIL: { send: async (m) => got.push(m) },
    OH_MAIL_FROM: 'noreply@openhearts.game',
  };
  const raw = paidCheckout();
  const hook = async () =>
    worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/stripe', { method: 'POST', headers: { 'stripe-signature': await signHook(raw) }, body: raw }), shop);
  const answers = await Promise.all([hook(), hook()]);
  assert.deepEqual(answers.map((a) => a.status), [200, 200]);
  const made = [...store.rows.keys()].filter((k) => /^ACCOUNT#[0-9a-f]{32}\|META$/.test(k));
  assert.equal(made.length, 1, 'one account for one subscription');
  assert.equal(made[0], `ACCOUNT#${await accountOfSub(store, 'sub_race')}|META`);
  assert.equal(got.length, 1, 'one set of backup codes mailed');
});

test('the webhook route: a checkout its turn could not bind yet is sent again; one it never will is taken', async () => {
  const store = memoryStore();
  const raw = paidCheckout('sub_turned');
  const asked = [];
  // The accounts' turns, answering each op as [answers] says.
  const turns = (answers) => ({
    idFromName: (name) => name,
    get: (name) => ({
      fetch: async (_, init) => {
        const op = JSON.parse(init.body);
        asked.push([name, op.op]);
        return Response.json(answers[op.op]);
      },
    }),
  });
  const hook = async (answers) =>
    worker.fetch(
      new Request('https://dev.open-hearts.pages.dev/api/stripe', { method: 'POST', headers: { 'stripe-signature': await signHook(raw) }, body: raw }),
      { ...env, OH_STRIPE_WEBHOOK_SECRET: SIGNING, OH_STORE: kvOf(store), HOUSEHOLD: turns(answers) },
    );
  const busy = { status: 429, body: { error: 'too many at once: try again in a while' } };
  const bound = { status: 200, body: { account: ACCT, entitlement: {} } };
  assert.equal((await hook({ paid: busy })).status, 503, 'over the allowance: Stripe sends it again');
  assert.deepEqual(asked, [['sub:sub_turned', 'paid']], 'bound in the subscription\'s turn, and nothing mailed');
  assert.equal((await hook({ paid: { status: 500, body: {} } })).status, 503);
  assert.equal((await hook({ paid: bound, made: busy })).status, 503, 'the codes not made yet: sent again');
  asked.length = 0;
  assert.equal((await hook({ paid: bound, made: { status: 200, body: { made_at: 'x', emailed: true } } })).status, 200);
  assert.deepEqual(asked, [['sub:sub_turned', 'paid'], [ACCT, 'made']]);
  // A full account turns the buyer away however often it is asked.
  const full = { status: 409, body: { error: 'the account has all the devices it can take', devices: 5, most: 5 } };
  assert.equal((await hook({ paid: full })).status, 200);
});

test('the checkout route: the key, and somewhere on this site to come back to', async () => {
  const at = 'https://dev.open-hearts.pages.dev/api/checkout';
  const shop = { ...env, OH_STRIPE_SECRET: 'sk', OH_STRIPE_PRICE: 'price_1', OH_PRICE: STATED };
  const send = (body) => new Request(at, { method: 'POST', body: JSON.stringify(body) });
  assert.equal((await worker.fetch(send({ key: 'short', back: '/play/', cancelled: '/play/' }), shop)).status, 400);
  const away = await worker.fetch(send(await asking(ADA, 'checkout', { back: 'https://evil.example/', cancelled: '/play/' })), shop);
  assert.equal(away.status, 400, 'a payment does not land where the caller says');
  const realFetch = globalThis.fetch;
  const sent = [];
  globalThis.fetch = withPrice(async (_, init) => {
    sent.push(new URLSearchParams(init.body));
    return new Response(JSON.stringify({ url: 'https://checkout.stripe.com/c/pay/cs_1' }), { status: 200 });
  });
  try {
    const res = await worker.fetch(send(await asking(ADA, 'checkout', { back: '/play/?bought=1', cancelled: '/play/', lang: 'fr' })), shop);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).url, 'https://checkout.stripe.com/c/pay/cs_1');
    assert.equal(sent.at(-1).get('locale'), 'fr', "in the app's language");
    // A suspended account's device is sold nothing: Stripe is not asked.
    const store = subscribed(ADA.public, { renews_at: '2027-01-01' });
    await store.put(`KEY#${ADA.public}`, 'ENTITLEMENT', { ...(await store.get(`KEY#${ADA.public}`, 'ENTITLEMENT')), suspended: true });
    const asked = sent.length;
    const refused = await worker.fetch(send(await asking(ADA, 'checkout', { back: '/play/?bought=1', cancelled: '/play/' })), { ...shop, OH_STORE: kvOf(store) });
    assert.equal(refused.status, 403);
    assert.deepEqual(await refused.json(), { error: SUSPENDED_WHY, suspended: true });
    assert.equal(sent.length, asked);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('cancelling is not ending: the year paid for still runs, and dunning giving up does end it', async () => {
  const now = Date.UTC(2026, 8, 16);
  const nextYear = Math.floor(Date.UTC(2027, 8, 16) / 1000);
  const start = async () => {
    const store = memoryStore();
    await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
    await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: nextYear } } }, store, { now });
    return store;
  };

  // Cancelled today, running to the end of the year that was paid for.
  const cancelling = await start();
  await record(
    {
      type: 'customer.subscription.updated',
      data: { object: { id: 'sub_9', status: 'active', cancel_at_period_end: true, canceled_at: Math.floor(now / 1000), current_period_end: nextYear } },
    },
    cancelling,
    { now },
  );
  assert.equal((await cancelling.get('SUB#sub_9', 'META')).cancelled_at, '2026-09-16');
  assert.equal((await entitlementOf(cancelling, KEY, { now: Date.UTC(2027, 5, 1) })).licensed_until, '2027-09-16');

  // Dunning gave up: over, and the device's own copy of the date goes
  // with it rather than licensing a year of unpaid play.
  const unpaid = await start();
  await record({ type: 'customer.subscription.updated', data: { object: { id: 'sub_9', status: 'unpaid', current_period_end: nextYear } } }, unpaid, { now });
  assert.equal((await unpaid.get(`KEY#${KEY}`, 'ENTITLEMENT')).licensed_until, '2026-09-16');
  assert.equal(await entitlementOf(unpaid, KEY, { now: Date.UTC(2026, 8, 17) }), null);
});

test('Stripe\'s events in the wrong order do not bring back a subscription that has ended', async () => {
  // Stripe does not promise order, and retries a delivery that failed
  // for days: an update from before the end can land after it.
  const now = Date.UTC(2026, 8, 16);
  const at = (day) => Math.floor(Date.UTC(2026, 8, day) / 1000);
  const nextYear = Math.floor(Date.UTC(2027, 8, 16) / 1000);
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', created: at(16), data: { object: { id: 'sub_9', status: 'active', current_period_end: nextYear } } }, store, { now });
  await record({ type: 'customer.subscription.deleted', created: at(18), data: { object: { id: 'sub_9', status: 'canceled' } } }, store, { now: Date.UTC(2026, 8, 18) });

  // The update that was refused on the 17th, at last.
  const late = { type: 'customer.subscription.updated', created: at(17), data: { object: { id: 'sub_9', status: 'active', current_period_end: nextYear } } };
  await record(late, store, { now: Date.UTC(2026, 8, 19) });
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 20) }), null, 'a refund is not a year of play');

  // And a deleted subscription stays deleted even against an event
  // stamped the same second, which Stripe never sends after a deletion.
  await record({ ...late, created: at(18) }, store, { now: Date.UTC(2026, 8, 19) });
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 20) }), null);

  // Whereas dunning that gave up is not the end: paid after all, it is
  // a subscription again.
  const owed = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: KEY } } } }, owed, { now });
  await record({ type: 'customer.subscription.updated', created: at(16), data: { object: { id: 'sub_9', status: 'unpaid', current_period_end: nextYear } } }, owed, { now });
  await record({ type: 'customer.subscription.updated', created: at(17), data: { object: { id: 'sub_9', status: 'active', current_period_end: nextYear } } }, owed, { now: Date.UTC(2026, 8, 17) });
  assert.equal((await entitlementOf(owed, KEY, { now: Date.UTC(2026, 8, 18) })).licensed_until, '2027-09-16');
});

// ---- a subscription is a person's ---------------------------------------

const OTHER = 'cd'.repeat(32);
const THIRD = 'ef'.repeat(32);

/// A store with [key] subscribed and its subscription running a year out.
const household = async (now, key = KEY) => {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor(Date.UTC(2027, 8, 16) / 1000) } } }, store, { now });
  return store;
};

test('a code brings a second device in, and is spent doing it', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const made = await ticketFor(KEY, store, { now });
  assert.equal(made.status, 200);
  assert.match(made.body.ticket, /^[0-9a-f]{32}$/);
  assert.deepEqual([made.body.devices, made.body.most], [1, 5]);
  // Nothing about the subscription travels with it.
  assert.equal(made.body.ticket.includes('sub_9'), false);

  const claimed = await claimWith(OTHER, made.body.ticket, store, { now });
  assert.equal(claimed.status, 200);
  assert.equal((await entitlementOf(store, OTHER, { now })).licensed_until, '2027-09-16');
  assert.deepEqual((await devicesOn(store, await accountOfSub(store, 'sub_9'))).map((d) => d.key), [KEY, OTHER]);

  // Spent: a photograph of the screen a minute later is worth nothing.
  const again = await claimWith(THIRD, made.body.ticket, store, { now });
  assert.equal(again.status, 409);
  assert.equal(await entitlementOf(store, THIRD, { now }), null);
});

test('a code runs out, and one nobody made was never a code', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const made = await ticketFor(KEY, store, { now });
  const late = await claimWith(OTHER, made.body.ticket, store, { now: now + 11 * 60000 });
  assert.equal(late.status, 410);
  assert.equal(await entitlementOf(store, OTHER, { now }), null);
  assert.equal((await claimWith(OTHER, 'ab'.repeat(16), store, { now })).status, 404);
  assert.equal((await claimWith(OTHER, 'not a code', store, { now })).status, 400);
});

test('five devices is a household; a sixth is refused, and no code is made for one', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const keys = ['11', '22', '33', '44'].map((b) => b.repeat(32));
  for (const key of keys) {
    const made = await ticketFor(KEY, store, { now });
    assert.equal(made.status, 200, `a code for ${key.slice(0, 4)}`);
    assert.equal((await claimWith(key, made.body.ticket, store, { now })).status, 200);
  }
  assert.equal((await devicesOn(store, await accountOfSub(store, 'sub_9'))).length, 5);
  const sixth = await ticketFor(KEY, store, { now });
  assert.equal(sixth.status, 409);
  assert.deepEqual(sixth.body, { error: 'the account has all the devices it can take', devices: 5, most: 5 });
});

test('a code made before the fifth device cannot let a sixth in', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  // Made while there was room, spent after there was not.
  const early = await ticketFor(KEY, store, { now });
  for (const key of ['11', '22', '33', '44'].map((b) => b.repeat(32))) {
    const made = await ticketFor(KEY, store, { now });
    await claimWith(key, made.body.ticket, store, { now });
  }
  const late = await claimWith(OTHER, early.body.ticket, store, { now });
  assert.equal(late.status, 409, 'the count is read where it is spent, not where it is made');
  assert.equal((await devicesOn(store, await accountOfSub(store, 'sub_9'))).length, 5);
});

test('any device can drop another, and the dropped one stops being licensed', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const made = await ticketFor(KEY, store, { now });
  await claimWith(OTHER, made.body.ticket, store, { now });

  // The one that arrived second drops the first, which is the case that
  // matters: a phone dropping a laptop that was lost.
  const dropped = await dropDevice(OTHER, KEY, store, { now });
  assert.equal(dropped.status, 200);
  assert.equal(dropped.body.devices, 1);
  assert.deepEqual((await devicesOn(store, await accountOfSub(store, 'sub_9'))).map((d) => d.key), [OTHER]);
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 17) }), null);
  assert.equal((await entitlementOf(store, OTHER, { now })).licensed_until, '2027-09-16');

  // And nobody drops a device off somebody else's subscription.
  assert.equal((await dropDevice(THIRD, OTHER, store, { now })).status, 402);
  assert.equal((await dropDevice(OTHER, THIRD, store, { now })).status, 404);
});

test('the routes: backup codes shown, one claimed with the licence back, and replaced', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now, ADA.public);
  const { held, send } = serving(store);
  const shown = await worker.fetch(send('backups', await asking(ADA, 'backups')), held);
  assert.equal(shown.status, 200);
  const { codes } = await shown.json();
  assert.equal(codes.length, 5);
  assert.equal((await worker.fetch(send('backups', await asking(CY, 'backups')), held)).status, 402, 'not on the subscription');

  // Typed the way a person types it, and spent with the licence back.
  const typed = codes[0].code.toLowerCase().replaceAll('-', ' ');
  const claimed = await worker.fetch(send('claim', await asking(BAO, 'claim', { what: typed, ticket: typed })), held);
  assert.equal(claimed.status, 200);
  assert.equal((await claimed.json()).licence.key, BAO.public);

  // Replacing is signed as such: a plain read cannot be replayed as one.
  const plain = await asking(ADA, 'backups');
  assert.equal((await worker.fetch(send('backups', { ...plain, rotate: true }), held)).status, 401);
  const replaced = await worker.fetch(send('backups', await asking(ADA, 'backups', { what: 'rotate', rotate: true })), held);
  assert.equal(replaced.status, 200);
  const fresh = (await replaced.json()).codes.map((c) => c.code);
  assert.equal(fresh.includes(codes[1].code), false);
  const old = codes[1].code;
  assert.equal((await worker.fetch(send('claim', await asking(CY, 'claim', { what: old, ticket: old })), held)).status, 404);

  // Sending is signed as such too.
  assert.equal((await worker.fetch(send('backups', { ...plain, send: true }), held)).status, 401);
  const sentTo = await worker.fetch(send('backups', await asking(ADA, 'backups', { what: 'send', send: true })), held);
  assert.equal(sentTo.status, 200);
  assert.equal(typeof (await sentTo.json()).emailed, 'boolean');
});

test("backup codes go only to the payer of the account they are of, and Stripe is asked only for a device of it", async () => {
  const store = await household(Date.now(), ADA.public);
  const account = await accountOfSub(store, 'sub_9');
  await store.put('SUB#sub_9', 'CUSTOMER', { customer: 'cus_ada' });
  const { codes } = await makeBackups(store, account);
  const mailed = [];
  const { send } = serving(store);
  const held = {
    ...env,
    OH_SERVICE_SECRET: SERVICE_SECRET,
    OH_SERVICE_KEY: SERVICE_KEY,
    OH_STORE: kvOf(store),
    OH_STRIPE_SECRET: 'sk',
    EMAIL: { send: async (m) => mailed.push(m) },
    OH_MAIL_FROM: 'noreply@openhearts.game',
  };
  const asked = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => (asked.push(String(url)), Response.json({ email: 'ada@example.com' }));
  try {
    // Bao comes in with a code, and keeps the licence it is given.
    const typed = codes[0].code;
    const { licence: kept } = await (await worker.fetch(send('claim', await asking(BAO, 'claim', { what: typed, ticket: typed })), held)).json();
    const sendCodes = async (licence) => worker.fetch(send('backups', { ...(await asking(BAO, 'backups', { what: 'send', send: true })), licence }), held);
    assert.equal((await sendCodes(kept)).status, 200);
    assert.deepEqual(asked, ['https://api.stripe.com/v1/customers/cus_ada']);
    assert.equal(mailed.length, 1);

    // Then it buys a subscription of its own, which moves it to an
    // account of its own, and asks again with the licence it still holds.
    await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_bao', metadata: { key: BAO.public } } } }, store);
    assert.notEqual(await accountOfKey(store, BAO.public), account);
    asked.length = 0;
    assert.equal((await sendCodes(kept)).status, 402);
    assert.deepEqual(asked, [], 'nobody asked Stripe for the payer of an account it is not in');
    assert.equal(mailed.length, 1, 'and its new account\'s codes mailed to nobody');
    assert.equal((await worker.fetch(send('backups', { ...(await asking(BAO, 'backups')), licence: kept }), held)).status, 402, 'nor shown');
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("a device brought in by a code is licensed at once, though the store where it asked has yet to hear of it", async () => {
  const store = await household(Date.now(), ADA.public);
  const account = await accountOfSub(store, 'sub_9');
  const { codes } = await makeBackups(store, account);
  const { send } = serving(store);
  const held = { ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: seenFrom(kvOf(store)), HOUSEHOLD: objectsAt(seenFrom(kvOf(store))) };

  // The app asks for its licence as it starts, and has none; a few
  // seconds later its person types a backup code.
  assert.equal((await worker.fetch(send('licence', await asking(BAO, 'licence')), held)).status, 402);
  const typed = codes[0].code;
  const claimed = await worker.fetch(send('claim', await asking(BAO, 'claim', { what: typed, ticket: typed })), held);
  assert.equal(claimed.status, 200);
  const { licence: signed } = await claimed.json();
  const { licence: theirs } = await (await worker.fetch(send('licence', await asking(ADA, 'licence')), held)).json();
  assert.deepEqual([signed.key, signed.account, signed.until], [BAO.public, account, theirs.until], 'as long as the device that was there already');

  // A code off another device's screen, the same.
  assert.equal((await worker.fetch(send('licence', await asking(CY, 'licence')), held)).status, 402);
  const { ticket } = (await ticketFor(ADA.public, store)).body;
  const scanned = await worker.fetch(send('claim', await asking(CY, 'claim', { what: ticket, ticket })), held);
  assert.equal(scanned.status, 200);
  assert.equal((await scanned.json()).licence.key, CY.public);
});

test('a device brought into a suspended account is told so, though the store where it asked has yet to hear of it', async () => {
  const store = await household(Date.now(), ADA.public);
  const account = await accountOfSub(store, 'sub_9');
  const { codes } = await makeBackups(store, account);
  await store.put(`ACCOUNT#${account}`, 'SUSPENDED', { since: dayOf(Date.now()) });
  const { send } = serving(store);
  const held = { ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: seenFrom(kvOf(store)), HOUSEHOLD: objectsAt(seenFrom(kvOf(store))) };
  assert.equal((await worker.fetch(send('licence', await asking(BAO, 'licence')), held)).status, 402);
  const typed = codes[0].code;
  const claimed = await worker.fetch(send('claim', await asking(BAO, 'claim', { what: typed, ticket: typed })), held);
  assert.deepEqual([claimed.status, await claimed.json()], [403, { error: SUSPENDED_WHY, suspended: true }], 'not offered a subscription it cannot use');
});

test('a device just brought in takes its account up at once, showing its licence where the store has yet to hear of it', async () => {
  const store = await household(Date.now(), ADA.public);
  const account = await accountOfSub(store, 'sub_9');
  const { codes } = await makeBackups(store, account);
  const { send } = serving(store);
  const held = { ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: seenFrom(kvOf(store)), HOUSEHOLD: objectsAt(seenFrom(kvOf(store))) };
  assert.equal((await worker.fetch(send('licence', await asking(BAO, 'licence')), held)).status, 402);
  const typed = codes[0].code;
  const { licence: mine } = await (await worker.fetch(send('claim', await asking(BAO, 'claim', { what: typed, ticket: typed })), held)).json();
  const activate = async (pair, more = {}) => worker.fetch(send('activate', await asking(pair, 'activate', { what: 'open ', want: 'open', ...more })), held);

  // The store here has nothing for it yet, for up to a minute: with no
  // licence shown, the handler has no account to ask.
  assert.equal((await activate(BAO)).status, 402);
  // Its licence names the account, whose object brought it in and knows it.
  const took = await activate(BAO, { licence: mine });
  assert.equal(took.status, 200);
  assert.equal((await took.json()).activation.account, account);
  const profile = await worker.fetch(send('profile', await asking(BAO, 'profile', { licence: mine })), held);
  assert.equal(profile.status, 200);

  // A licence is taken only as the service's word for the device showing
  // it, and only while it is good: another device's, one altered, or one
  // run out is no word at all, though the account's object knows this
  // device.
  const { licence: hers } = await (await worker.fetch(send('licence', await asking(ADA, 'licence')), held)).json();
  assert.equal((await activate(BAO, { licence: hers })).status, 402, "another device's licence");
  assert.equal((await activate(BAO, { licence: { ...mine, until: dayAfter(Date.now(), 400) } })).status, 402, 'one altered');
  const old = await licenceFor(BAO.public, account, dayAfter(Date.now(), -2), { signer, secret: SERVICE_SECRET, service: SERVICE_KEY });
  assert.equal((await activate(BAO, { licence: old })).status, 402, 'one run out');
  assert.equal((await activate(BAO, { licence: { ...mine, sig: undefined } })).status, 402, 'one unsigned');
  assert.equal((await activate(BAO, { licence: 'not one' })).status, 402);
  // A signature that is not one is none, though its first 64 bytes are
  // the service's: read as it stands, it would run on past the
  // signer's 64 into the rest of its memory.
  assert.equal((await activate(BAO, { licence: { ...mine, sig: `${mine.sig}00` } })).status, 402, 'one too long');
  assert.equal((await activate(BAO, { licence: { ...mine, sig: mine.sig.repeat(40) } })).status, 402, 'one far too long');
  assert.equal((await activate(BAO, { licence: { ...mine, sig: mine.sig.toUpperCase() } })).status, 402, 'one not as the service writes it');
  assert.equal((await activate(BAO, { licence: mine })).status, 200, 'and the signer reads the next as ever');
});

test("a device just moved shows its licence for the account it is in, over what the store here last read", async () => {
  // The store here read the device's row while it was another
  // account's; its new account's object has since written it in.
  const store = await household(Date.now(), ADA.public);
  const account = await accountOfSub(store, 'sub_9');
  const here = seenFrom(kvOf(store));
  const held = { ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: here, HOUSEHOLD: objectsAt(seenFrom(kvOf(store))) };
  const before = '0b'.repeat(16);
  await store.put(`KEY#${BAO.public}`, 'ENTITLEMENT', { account: before, licensed_until: '2027-09-16', at: dayOf(Date.now()) });
  assert.equal((await here.get(`KEY#${BAO.public}|ENTITLEMENT`, 'json')).account, before);
  const { codes } = await makeBackups(store, account);
  await redeemBackup(BAO.public, codes[0].code, store);
  const mine = await licenceFor(BAO.public, account, dayAfter(Date.now(), 30), { signer, secret: SERVICE_SECRET, service: SERVICE_KEY });
  const { send } = serving(store);
  const took = await worker.fetch(send('activate', await asking(BAO, 'activate', { what: 'open ', want: 'open', licence: mine })), held);
  assert.equal(took.status, 200, "asked of the account it is in, not the one the store here last read");
  assert.equal((await took.json()).activation.account, account);
});

test('the routes: a code, a claim that answers with the licence, and the devices list', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now, ADA.public);
  const { held, send } = serving(store);

  const made = await worker.fetch(send('ticket', await asking(ADA, 'ticket')), held);
  assert.equal(made.status, 200);
  const { ticket } = await made.json();

  const claimed = await worker.fetch(send('claim', await asking(BAO, 'claim', { what: ticket, ticket })), held);
  assert.equal(claimed.status, 200);
  const { licence: signed } = await claimed.json();
  assert.equal(signed.key, BAO.public, 'the device that scanned it is playing, not waiting to be told');

  const listed = await worker.fetch(send('devices', await asking(BAO, 'devices')), held);
  const { devices, most } = await listed.json();
  assert.deepEqual(devices.map((d) => d.key), [ADA.public, BAO.public]);
  assert.equal(most, 5);

  const after = await worker.fetch(send('devices', await asking(BAO, 'devices', { what: ADA.public, drop: ADA.public })), held);
  assert.deepEqual((await after.json()).devices.map((d) => d.key), [BAO.public]);

  const unknown = await worker.fetch(send('ticket', await asking(CY, 'ticket')), held);
  assert.equal(unknown.status, 402);
});

test('a dropped device does not come back on its next ask', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const made = await ticketFor(KEY, store, { now });
  await claimWith(OTHER, made.body.ticket, store, { now });
  await dropDevice(KEY, OTHER, store, { now });
  // The subscription itself is still paid up to next year, so a row
  // that merely ran out would be dated back from it on the next ask.
  assert.equal((await store.get('SUB#sub_9', 'META')).renews_at, '2027-09-16');
  for (const day of [Date.UTC(2026, 8, 16), Date.UTC(2026, 8, 17), Date.UTC(2027, 0, 1)]) {
    assert.equal(await entitlementOf(store, OTHER, { now: day }), null, new Date(day).toISOString().slice(0, 10));
  }
});

// ---- who is asking ------------------------------------------------------
// A key is public: it signs every event a device says at a table, and
// the relays hand those to anybody. So a request that only names one
// is anybody's.

test('a key alone is nobody: a household is not listed, dropped from or joined by whoever can read a key', async () => {
  const now = Date.now();
  const store = await household(now, ADA.public);
  const { held, send } = serving(store);

  // Ada's key, as a stranger read it off the relay.
  assert.equal((await worker.fetch(send('devices', { key: ADA.public }), held)).status, 401, 'her devices are not listed to him');
  assert.equal((await worker.fetch(send('devices', { key: ADA.public, drop: ADA.public }), held)).status, 401);
  assert.deepEqual((await devicesOn(store, await accountOfSub(store, 'sub_9'))).map((d) => d.key), [ADA.public], 'nor is she dropped off what she paid for');
  assert.equal((await worker.fetch(send('ticket', { key: ADA.public }), held)).status, 401, 'nor is a code made against it');
  assert.equal((await worker.fetch(send('licence', { key: ADA.public }), held)).status, 401, 'nor is he told whether she pays');

  // Signed, but by his own key; or for another handler; or what it
  // asks for is not what was signed; or signed an hour ago.
  const second = Math.floor(now / 1000);
  for (const [why, what, body] of [
    ['his signature', 'devices', { ...(await asking(BAO, 'devices')), key: ADA.public }],
    ['a licence request is not a code request', 'ticket', await asking(ADA, 'licence')],
    ['the device to drop is part of what is signed', 'devices', await asking(ADA, 'devices', { drop: BAO.public })],
    ['an old request is not a new one', 'ticket', await asking(ADA, 'ticket', { at: second - 3600 })],
    ['nor one from the future', 'ticket', await asking(ADA, 'ticket', { at: second + 3600 })],
  ]) {
    assert.equal((await worker.fetch(send(what, body), held)).status, 401, why);
  }

  // Her own, signed: answered, and a code made by her is spent by a
  // device that signs for itself.
  const made = await worker.fetch(send('ticket', await asking(ADA, 'ticket')), held);
  assert.equal(made.status, 200);
  const { ticket } = await made.json();
  assert.equal((await worker.fetch(send('claim', { key: BAO.public, ticket }), held)).status, 401, 'a claim names the device it binds');
  assert.equal((await worker.fetch(send('claim', await asking(BAO, 'claim', { ticket: 'ab'.repeat(16) })), held)).status, 401, 'and the code it spends');
  const claimed = await worker.fetch(send('claim', await asking(BAO, 'claim', { what: ticket, ticket })), held);
  assert.equal(claimed.status, 200);
  assert.equal((await claimed.json()).licence.key, BAO.public);
  const listed = await worker.fetch(send('devices', await asking(BAO, 'devices')), held);
  assert.deepEqual((await listed.json()).devices.map((d) => d.key).sort(), [ADA.public, BAO.public].sort());
});

test('what a request signs is pinned, here and in the app (app/test/licence_test.dart)', async () => {
  const statement = requestStatement('ticket', ADA.public, 1700000000);
  assert.equal(statement, `oh-request/1\nticket\n${ADA.public}\n1700000000\n`);
  assert.equal(await sha(statement), REQUEST_VECTOR);
  // And a signature over it is taken from the key it names, then, and
  // from nobody else or any other time.
  const body = await asking(ADA, 'ticket', { at: 1700000000 });
  const then = 1700000000 * 1000;
  assert.deepEqual(await askedBy(body, 'ticket', '', signer, { now: then }), { key: ADA.public });
  assert.equal((await askedBy(body, 'ticket', '', signer, { now: then + 301000 })).status, 401);
  assert.equal((await askedBy({ ...body, key: BAO.public }, 'ticket', '', signer, { now: then })).status, 401);
  assert.equal((await askedBy({ ...body, sig: 'zz' }, 'ticket', '', signer, { now: then })).status, 401);
  assert.equal((await askedBy({ ...body, at: '1700000000' }, 'ticket', '', signer, { now: then })).status, 401);
  assert.equal((await askedBy({ key: 'short' }, 'ticket', '', signer, { now: then })).status, 400);
});

test('how far a request\'s clock may be from ours is the service\'s setting', async (t) => {
  t.after(forgetSettings);
  const body = await asking(ADA, 'ticket', { at: 1700000000 });
  const then = 1700000000 * 1000;
  useSettings({ requestToleranceS: 60 });
  assert.equal((await askedBy(body, 'ticket', '', signer, { now: then + 61000 })).status, 401);
  assert.deepEqual(await askedBy(body, 'ticket', '', signer, { now: then + 59000 }), { key: ADA.public });
});

test('TURN is for a device that holds a licence, and asks for it itself', async () => {
  // Credentials are a relay anybody can push anything through, billed
  // to the project by the gigabyte.
  const store = await household(Date.now(), ADA.public);
  const held = { ...env, OH_STORE: kvOf(store) };
  const send = (body) => new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'POST', body: JSON.stringify(body) });
  const realFetch = globalThis.fetch;
  okUpstream.calls.length = 0;
  globalThis.fetch = okUpstream;
  try {
    assert.equal((await worker.fetch(send({ key: ADA.public }), held)).status, 401, 'a key read off a relay');
    assert.equal((await worker.fetch(send(await asking(CY, 'turn')), held)).status, 402, 'a device with no subscription');
    assert.equal(okUpstream.calls.length, 0, 'and neither of them cost an upstream call');
    const ok = await worker.fetch(send(await asking(ADA, 'turn')), held);
    assert.equal(ok.status, 200);
    assert.deepEqual((await ok.json()).iceServers, answer.iceServers);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a checkout is opened only by the device it is for', async () => {
  // Paying for somebody else's key would move their device onto a
  // subscription the payer can end.
  const shop = { ...env, OH_STRIPE_SECRET: 'sk', OH_STRIPE_PRICE: 'price_1', OH_PRICE: STATED };
  const send = (body) => new Request('https://dev.open-hearts.pages.dev/api/checkout', { method: 'POST', body: JSON.stringify(body) });
  const realFetch = globalThis.fetch;
  globalThis.fetch = withPrice(async () => new Response(JSON.stringify({ url: 'https://checkout.stripe.com/c/pay/cs_1' }), { status: 200 }));
  try {
    assert.equal((await worker.fetch(send({ key: ADA.public, back: '/play/?bought=1', cancelled: '/play/' }), shop)).status, 401);
    const ok = await worker.fetch(send(await asking(ADA, 'checkout', { back: '/play/?bought=1', cancelled: '/play/' })), shop);
    assert.equal(ok.status, 200);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a code does not take a device off a subscription somebody paid for, so a link cannot', async () => {
  // A claim link is spent the moment the app opens it. A stranger with
  // a subscription of his own sends one to Ada; her device would leave
  // the subscription she paid for for his, and he would drop it there.
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_2', metadata: { key: THIRD } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_2', current_period_end: Math.floor(Date.UTC(2027, 0, 1) / 1000) } } }, store, { now });
  const his = await ticketFor(THIRD, store, { now });
  const taken = await claimWith(KEY, his.body.ticket, store, { now });
  assert.equal(taken.status, 409);
  assert.match(taken.body.error, /another subscription/);
  assert.equal((await entitlementOf(store, KEY, { now })).account, await accountOfSub(store, 'sub_9'), 'still on her own');
  assert.equal((await dropDevice(THIRD, KEY, store, { now })).status, 404, 'and not his to drop');
  assert.deepEqual((await store.get(`TICKET#${his.body.ticket}`, 'META')).used_at, null, 'nor is his code spent on her');
});

test('a device leaves a subscription by dropping itself, and one that has ended or was nobody\'s purchase holds nothing', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_2', metadata: { key: THIRD } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_2', current_period_end: Math.floor(Date.UTC(2027, 0, 1) / 1000) } } }, store, { now });

  // Moving on purpose: dropped from the first, then the code.
  const made = await ticketFor(KEY, store, { now });
  await claimWith(OTHER, made.body.ticket, store, { now });
  await dropDevice(OTHER, OTHER, store, { now });
  const moving = await ticketFor(THIRD, store, { now });
  assert.equal((await claimWith(OTHER, moving.body.ticket, store, { now })).status, 200);
  assert.deepEqual((await devicesOn(store, await accountOfSub(store, 'sub_9'))).map((d) => d.key), [KEY], 'gone from the first');
  // Bound the same day, so the tiebreak is the key: both are there,
  // whichever way round they sort.
  assert.deepEqual((await devicesOn(store, await accountOfSub(store, 'sub_2'))).map((d) => d.key).sort(), [OTHER, THIRD].sort());
  assert.equal((await entitlementOf(store, OTHER, { now })).account, await accountOfSub(store, 'sub_2'));

  // A subscription that has ended keeps nobody.
  await record({ type: 'customer.subscription.deleted', data: { object: { id: 'sub_9' } } }, store, { now });
  const after = Date.UTC(2026, 8, 18);
  const again = await ticketFor(THIRD, store, { now: after });
  assert.equal((await claimWith(KEY, again.body.ticket, store, { now: after })).status, 200);
  assert.equal((await entitlementOf(store, KEY, { now: after })).account, await accountOfSub(store, 'sub_2'));

  // Nor does local mode's open house, which licenses any device that
  // asks and so is where every device in the browser suite starts.
  const local = memoryStore();
  await entitlementOf(local, OTHER, { now, openHouse: true });
  await entitlementOf(local, THIRD, { now, openHouse: true });
  const code = await ticketFor(THIRD, local, { now });
  assert.equal((await claimWith(OTHER, code.body.ticket, local, { now })).status, 200);
  assert.equal((await entitlementOf(local, OTHER, { now })).account, await accountOfKey(local, THIRD));

  // Nor does a preview's invitation (ops/preview.mjs): an account the
  // operator made, its backup code handed on. A device of one moves to
  // another with the second's code, as a tester handed two would.
  const previews = memoryStore();
  const invited = async (subscription) => {
    await previews.put(`SUB#${subscription}`, 'META', { source: 'invited', txn_ref: null, renews_at: dayAfter(now, 365), cancelled_at: null });
    const account = await accountFor(previews, subscription, { make: true, now });
    return { account, code: (await makeBackups(previews, account, { now })).codes[0].code };
  };
  const first = await invited('invited-1');
  const second = await invited('invited-2');
  assert.equal((await redeemBackup(OTHER, first.code, previews, { now })).status, 200);
  assert.equal((await entitlementOf(previews, OTHER, { now })).licensed_until, dayAfter(now, 365), 'licensed for the year the invitation runs');
  assert.equal((await redeemBackup(OTHER, second.code, previews, { now })).status, 200);
  assert.equal((await entitlementOf(previews, OTHER, { now })).account, second.account);
  assert.deepEqual(await devicesOn(previews, first.account), [], 'gone from the first');
});

test('a code\'s row is let go by the store, spent or not, rather than kept for ever', async () => {
  const store = await household(Date.now(), ADA.public);
  const puts = [];
  const { held, send } = serving(store, puts);
  const made = await worker.fetch(send('ticket', await asking(ADA, 'ticket')), held);
  const { ticket } = await made.json();
  const ttl = (p) => p.options?.expirationTtl;
  const written = puts.filter((p) => p.at === `TICKET#${ticket}|META`);
  assert.equal(written.length, 1);
  assert.ok(ttl(written[0]) >= 10 * 60 && ttl(written[0]) <= 86400, `kept a while and then let go: ${ttl(written[0])}`);
  await worker.fetch(send('claim', await asking(BAO, 'claim', { what: ticket, ticket })), held);
  const spent = puts.filter((p) => p.at === `TICKET#${ticket}|META`);
  assert.equal(spent.length, 2);
  assert.ok(ttl(spent[1]) > 0, 'a write without an expiry would keep the spent code for ever');
});

// ---- who this is, where a provider will say ------------------------------

/// A provider of this test's own: a key pair, the key set it publishes,
/// and tokens it signs. Nothing here is Apple's or Google's except the
/// shape, which is the shape of every OpenID token.
async function provider({ iss, aud, kid = 'k1' } = {}) {
  const pair = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  const jwk = { ...(await crypto.subtle.exportKey('jwk', pair.publicKey)), kid, alg: 'RS256', use: 'sig' };
  delete jwk.key_ops;
  delete jwk.ext;
  const b64 = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const part = (o) => b64(new TextEncoder().encode(JSON.stringify(o)));
  return {
    jwk,
    fetch: async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 }),
    async token(claims, { alg = 'RS256', signer = pair.privateKey } = {}) {
      const head = part({ alg, kid, typ: 'JWT' });
      const body = part({ iss, aud, exp: Math.floor(Date.now() / 1000) + 600, iat: Math.floor(Date.now() / 1000), ...claims });
      const sig = new Uint8Array(await crypto.subtle.sign({ name: 'RSASSA-PKCS1-v1_5' }, signer, new TextEncoder().encode(`${head}.${body}`)));
      return `${head}.${body}.${b64(sig)}`;
    },
  };
}

/// The nonce a token has to carry: the hash of the device's own key.
const nonceFor = async (key) =>
  [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`oh-signin/1\n${key}`)))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

const signedInAs = { OH_GOOGLE_AUDIENCE: 'oh.apps.googleusercontent.com', OH_ID_HMAC: 'pepper' };

test('the nonce a token carries is the hash the app makes of its key', async () => {
  // The same figure is pinned on the app's side (app/test/sign_in_test.dart).
  assert.equal(await nonceFor(KEY), '584421408c2fc1b0fffb975b25e2ba2dd1b547b6760dfa23e0985ff7bf1789f2');
});

test('a sign-in token is read only when the provider signed it, for us, for this device, and not yet run out', async () => {
  forgetProviderKeys();
  const p = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const nonce = await nonceFor(KEY);
  const good = await p.token({ sub: 'sub-1', nonce });
  assert.deepEqual(await whoSignedIn('google', good, KEY, signedInAs, p.fetch), { provider: 'google', sub: 'sub-1' });

  const cases = {
    'another app\'s audience': await p.token({ sub: 'sub-1', nonce, aud: 'someone.else' }),
    'another issuer': await p.token({ sub: 'sub-1', nonce, iss: 'https://evil.example' }),
    'run out': await p.token({ sub: 'sub-1', nonce, exp: Math.floor(Date.now() / 1000) - 1 }),
    'no subject': await p.token({ nonce }),
    'minted for another device': await p.token({ sub: 'sub-1', nonce: await nonceFor(OTHER) }),
    'no nonce at all': await p.token({ sub: 'sub-1' }),
  };
  for (const [why, token] of Object.entries(cases)) {
    forgetProviderKeys();
    assert.equal(await whoSignedIn('google', token, KEY, signedInAs, p.fetch), null, why);
  }

  // Signed by somebody else entirely, with the same key id.
  forgetProviderKeys();
  const impostor = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const forged = await impostor.token({ sub: 'sub-1', nonce });
  assert.equal(await whoSignedIn('google', forged, KEY, signedInAs, p.fetch), null, 'a token the provider did not sign');

  // And nothing at all without the audience configured, or for a
  // provider nobody has heard of.
  forgetProviderKeys();
  assert.equal(await whoSignedIn('google', good, KEY, { OH_ID_HMAC: 'pepper' }, p.fetch), null);
  assert.equal(await whoSignedIn('nobody', good, KEY, signedInAs, p.fetch), null);
});

test('the identifier is stored keyed, never raw, and only where there is a secret to key it with', async () => {
  const who = { provider: 'google', sub: 'sub-1' };
  const row = await loginRow(who, signedInAs);
  assert.match(row, /^LOGIN#google#[0-9a-f]{64}$/);
  assert.equal(row.includes('sub-1'), false, 'a leaked table joins to nothing');
  // A different pepper is a different row: two leaks do not join either.
  assert.notEqual(await loginRow(who, { OH_ID_HMAC: 'other' }), row);
  // And the provider is part of what is keyed, so two providers that
  // handed out the same subject are two accounts.
  assert.notEqual(await loginRow({ provider: 'apple', sub: 'sub-1' }, signedInAs), row);
  assert.equal(await loginRow(who, {}), null);
});

test('a sign-in is linked to one account, and an account to one sign-in', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const account = await accountOfSub(store, 'sub_9');
  const who = { provider: 'google', sub: 'sub-1' };
  const login = await loginRow(who, signedInAs);
  assert.deepEqual(await attest(who, KEY, store, login, { now }), { status: 200, body: { attested: '2026-09-16', account } });
  assert.deepEqual(await store.get(login, 'IDENTITY'), { account, created_at: '2026-09-16' });
  assert.deepEqual(await store.get(`ACCOUNT#${account}`, 'LOGIN'), { provider: 'google', login, at: '2026-09-16' });
  // Nothing on the key's own side leads back to the provider's subject.
  assert.equal(await store.get(`KEY#${KEY}`, 'META'), null);

  // Again, or from another device of the account: the same link.
  assert.equal((await attest(who, KEY, store, login, { now })).status, 200);
  await claimWith(OTHER, (await ticketFor(KEY, store, { now })).body.ticket, store, { now });
  assert.equal((await attest(who, OTHER, store, login, { now })).status, 200);

  // A device of another account, or another sign-in for this one: one
  // person, one account, one sign-in.
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_2', metadata: { key: THIRD } } } }, store, { now });
  assert.deepEqual((await attest(who, THIRD, store, login, { now })).body, { error: 'that sign-in is linked to another account' });
  const other = await loginRow({ provider: 'apple', sub: '001234.abcd' }, signedInAs);
  assert.deepEqual((await attest({ provider: 'apple', sub: '001234.abcd' }, KEY, store, other, { now })).body, { error: 'this account is linked to another sign-in' });
  // And a device with no account has nothing to link.
  assert.equal((await attest(who, 'aa'.repeat(32), store, login, { now })).status, 402);
});

test('signing in brings a device into the account the sign-in is linked to, as a backup code would', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const account = await accountOfSub(store, 'sub_9');
  const held = { OH_STORE: kvOf(store) };
  const who = { provider: 'google', sub: 'sub-1' };
  const login = await loginRow(who, signedInAs);
  await attest(who, KEY, store, login, { now });

  const joined = await supersede(who, OTHER, store, held, login, { now: Date.UTC(2026, 9, 1) });
  assert.deepEqual(joined.body, { account, at: '2026-10-01' });
  assert.equal((await entitlementOf(store, OTHER, { now })).account, account);
  // A device the person still holds is not dropped by signing in on
  // another: they are both the account's, one in use at a time.
  assert.deepEqual((await devicesOn(store, account)).map((d) => d.key).sort(), [KEY, OTHER].sort());
  assert.equal((await supersede(who, OTHER, store, held, login, { now })).status, 200, 'again is nothing new');
});

test('a full account turns a sign-in away as it turns a code away', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  for (const key of ['11', '22', '33', '44'].map((b) => b.repeat(32))) {
    await claimWith(key, (await ticketFor(KEY, store, { now })).body.ticket, store, { now });
  }
  const who = { provider: 'google', sub: 'sub-1' };
  const login = await loginRow(who, signedInAs);
  await attest(who, KEY, store, login, { now });
  const turned = await supersede(who, OTHER, store, { OH_STORE: kvOf(store) }, login, { now });
  assert.equal(turned.status, 409);
  assert.equal(turned.body.error, 'the account has all the devices it can take');
});

test('a sign-in linked to no account has nothing to bring a device into', async () => {
  const store = memoryStore();
  const who = { provider: 'google', sub: 'nobody' };
  const said = await supersede(who, KEY, store, { OH_STORE: kvOf(store) }, await loginRow(who, signedInAs));
  assert.deepEqual([said.status, said.body.error], [404, 'that sign-in is not linked to an account']);
});

test('a sign-in does not take a device off an account somebody paid for; once that has ended, it does', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const account = await accountOfSub(store, 'sub_9');
  // OTHER bought its own, on the web.
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_mine', metadata: { key: OTHER } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_mine', current_period_end: Math.floor(Date.UTC(2027, 2, 1) / 1000) } } }, store, { now });
  const mine = await accountOfSub(store, 'sub_mine');
  const who = { provider: 'google', sub: 'sub-1' };
  const login = await loginRow(who, signedInAs);
  await attest(who, KEY, store, login, { now });
  const held = { OH_STORE: kvOf(store) };

  const refused = await supersede(who, OTHER, store, held, login, { now });
  assert.equal(refused.status, 409);
  assert.match(refused.body.error, /another subscription/);
  assert.equal((await entitlementOf(store, OTHER, { now })).account, mine, 'what was bought here stays here');

  await record({ type: 'customer.subscription.deleted', data: { object: { id: 'sub_mine', status: 'canceled' } } }, store, { now });
  const later = now + 86400000;
  assert.equal((await supersede(who, OTHER, store, held, login, { now: later })).status, 200);
  assert.equal((await entitlementOf(store, OTHER, { now: later })).account, account);
  assert.deepEqual((await devicesOn(store, mine)).map((d) => d.key), [], 'not counted against both');
});

test('an audience may be several: Apple names the bundle on an iPhone and the Services ID on the web', async () => {
  forgetProviderKeys();
  const apple = { OH_APPLE_AUDIENCE: 'game.openhearts.web, game.openhearts.app', OH_ID_HMAC: 'pepper' };
  const p = await provider({ iss: 'https://appleid.apple.com' });
  const nonce = await nonceFor(KEY);
  for (const aud of ['game.openhearts.web', 'game.openhearts.app']) {
    forgetProviderKeys();
    const token = await p.token({ sub: '001234.abcd', nonce, aud });
    assert.deepEqual(await whoSignedIn('apple', token, KEY, apple, p.fetch), { provider: 'apple', sub: '001234.abcd' }, aud);
  }
  for (const aud of ['game.openhearts', 'game.openhearts.web, game.openhearts.app', '']) {
    forgetProviderKeys();
    const token = await p.token({ sub: '001234.abcd', nonce, aud });
    assert.equal(await whoSignedIn('apple', token, KEY, apple, p.fetch), null, `not ours: ${JSON.stringify(aud)}`);
  }
  // An audience that is only commas and spaces is none.
  forgetProviderKeys();
  const any = await p.token({ sub: '001234.abcd', nonce, aud: '' });
  assert.equal(await whoSignedIn('apple', any, KEY, { ...apple, OH_APPLE_AUDIENCE: ' , ' }, p.fetch), null);
});

test('local mode: a local: sign-in links one device\'s account and brings the next device into it, end to end', async () => {
  const store = memoryStore();
  const { held: base } = serving(store);
  const held = { ...base, ...signedInAs, OH_OPEN_HOUSE: '1' };
  const send = (what, body) => new Request(`http://127.0.0.1:8788/api/${what}`, { method: 'POST', body: JSON.stringify(body) });

  // Ada's device is licensed by the open house, and she signs in on it.
  const first = await worker.fetch(send('attest', await asking(ADA, 'attest', { provider: 'apple', token: 'local:ada' })), held);
  assert.equal(first.status, 200);
  const attested = await first.json();
  assert.equal(attested.licence.key, ADA.public);

  // A new phone signs in, and is a device of her account.
  const moved = await worker.fetch(send('supersede', await asking(BAO, 'supersede', { provider: 'apple', token: 'local:ada' })), held);
  assert.equal(moved.status, 200);
  const said = await moved.json();
  assert.equal(said.account, attested.account);
  assert.equal(said.licence.key, BAO.public);
  assert.equal(said.licence.account, attested.account);
  assert.equal((await entitlementOf(store, BAO.public)).account, (await entitlementOf(store, ADA.public)).account);

  // A sign-in nobody has linked has nowhere to bring a device.
  const nowhere = await worker.fetch(send('supersede', await asking(CY, 'supersede', { provider: 'google', token: 'local:cy' })), held);
  assert.deepEqual([nowhere.status, (await nowhere.json()).error], [404, 'that sign-in is not linked to an account']);

  // And the same token anywhere but this machine is nobody.
  const away = new Request('https://dev.open-hearts.pages.dev/api/attest', { method: 'POST', body: JSON.stringify(await asking(CY, 'attest', { provider: 'google', token: 'local:cy' })) });
  assert.deepEqual([(await worker.fetch(away, held)).status], [401]);
});

test('the sign-in route: a token that does not check out is 401, and one that does comes back with the licence', async () => {
  forgetProviderKeys();
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now, ADA.public);
  const p = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const realFetch = globalThis.fetch;
  globalThis.fetch = p.fetch;
  try {
    const { held: base, send } = serving(store);
    const held = { ...base, ...signedInAs };

    const nonsense = await worker.fetch(send('attest', await asking(ADA, 'attest', { provider: 'google', token: 'not.a.token' })), held);
    assert.equal(nonsense.status, 401);

    const token = await p.token({ sub: 'sub-1', nonce: await nonceFor(ADA.public) });
    const ok = await worker.fetch(send('attest', await asking(ADA, 'attest', { provider: 'google', token })), held);
    assert.equal(ok.status, 200);
    const said = await ok.json();
    assert.equal(said.attested, dayOf(Date.now()));
    assert.equal(said.licence.key, ADA.public, 'a device that has just proved who it is does not ask twice');

    // The same person on a new phone: it has no account to link, and
    // signing in brings it into hers.
    const theirs = await p.token({ sub: 'sub-1', nonce: await nonceFor(BAO.public) });
    assert.equal((await worker.fetch(send('attest', await asking(BAO, 'attest', { provider: 'google', token: theirs })), held)).status, 402);
    const moved = await worker.fetch(send('supersede', await asking(BAO, 'supersede', { provider: 'google', token: theirs })), held);
    assert.equal(moved.status, 200);
    const joined = await moved.json();
    assert.equal(joined.licence.key, BAO.public);
    assert.equal(joined.account, await accountOfSub(store, 'sub_9'));
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a device signing in is licensed at once, though the store where it asked has yet to hear of it', async () => {
  forgetProviderKeys();
  const store = await household(Date.now(), ADA.public);
  const p = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const realFetch = globalThis.fetch;
  globalThis.fetch = p.fetch;
  try {
    const { send } = serving(store);
    const held = { ...env, ...signedInAs, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: seenFrom(kvOf(store)), HOUSEHOLD: objectsAt(seenFrom(kvOf(store))) };
    const mine = await p.token({ sub: 'sub-1', nonce: await nonceFor(ADA.public) });
    assert.equal((await worker.fetch(send('attest', await asking(ADA, 'attest', { provider: 'google', token: mine })), held)).status, 200);

    // A new phone asks for its licence as it starts, and has none; then
    // its person signs in.
    assert.equal((await worker.fetch(send('licence', await asking(BAO, 'licence')), held)).status, 402);
    const theirs = await p.token({ sub: 'sub-1', nonce: await nonceFor(BAO.public) });
    const moved = await worker.fetch(send('supersede', await asking(BAO, 'supersede', { provider: 'google', token: theirs })), held);
    assert.equal(moved.status, 200);
    const said = await moved.json();
    assert.equal(said.licence?.key, BAO.public);
    assert.deepEqual(Object.keys(said).sort(), ['account', 'at', 'licence'], 'and nothing else of what the object said');
  } finally {
    globalThis.fetch = realFetch;
  }
});

/// Accounts' objects, each seeing the store from where it runs
/// (places.fixtures.mjs, objectsAt), and what each was asked.
const watchedObjects = (there) => {
  const objects = objectsAt(there);
  const asked = [];
  return {
    asked,
    idFromName: objects.idFromName,
    get: (id) => {
      const object = objects.get(id);
      return { fetch: async (url, init) => (asked.push(JSON.parse(init.body)), object.fetch(url, init)) };
    },
  };
};

/// Google's keys for a sign-in, as [p] serves them, and Cloudflare's
/// TURN for credentials (okUpstream).
const upstreams = (p) => (url, init) => (String(url).startsWith('https://rtc.live.cloudflare.com/') ? okUpstream(url, init) : p.fetch(url, init));

test('a device just brought in is asked of its account by each handler at once, showing its licence where the store here has yet to hear of it', async () => {
  forgetProviderKeys();
  const kept = new Map();
  const records = {
    head: async (k) => (kept.has(k) ? {} : null),
    get: async (k) => (kept.has(k) ? { body: new Blob([kept.get(k)]).stream() } : null),
    put: async (k, body) => kept.set(k, Buffer.from(body)),
  };
  const store = await household(Date.now(), ADA.public);
  const account = await accountOfSub(store, 'sub_9');
  const { codes } = await makeBackups(store, account);
  const { send } = serving(store);
  const objects = watchedObjects(seenFrom(kvOf(store)));
  const held = { ...env, ...signedInAs, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: seenFrom(kvOf(store)), HOUSEHOLD: objects, OH_RECORDS: records };
  const p = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const realFetch = globalThis.fetch;
  globalThis.fetch = upstreams(p);
  try {
    assert.equal((await worker.fetch(send('licence', await asking(BAO, 'licence')), held)).status, 402);
    const typed = codes[0].code;
    const { licence: mine } = await (await worker.fetch(send('claim', await asking(BAO, 'claim', { what: typed, ticket: typed })), held)).json();
    // The device in use, as the app takes its account up before all else.
    assert.equal((await worker.fetch(send('activate', await asking(BAO, 'activate', { what: 'open ', want: 'open', licence: mine })), held)).status, 200);

    // Each as the app asks it, and what each answers once the account is
    // found: a game nobody kept, a record that is not one, and a report
    // with nowhere here to go are past the asking. Without its licence,
    // the store here has no account for the device, for up to a minute.
    const table = '0123456789abcdef0123456789abcdef';
    const someone = 'b0'.repeat(16);
    const token = await p.token({ sub: 'sub-2', nonce: await nonceFor(BAO.public) });
    const asks = [
      ['ticket', {}, 200],
      ['backups', {}, 200],
      ['devices', {}, 200],
      ['profile', {}, 200],
      ['attest', { provider: 'google', token }, 200],
      ['turn', {}, 200],
      ['waiting', { what: 'rated 50', pool: 'rated', target: 50 }, 200],
      ['review', { what: table, table }, 404],
      ['record', { what: table, table, record: 'not a record' }, 400],
      ['report', { what: `${someone} name`, about: someone }, 503, { what: 'name' }],
    ];
    for (const [handler, ask, past, after = {}] of asks) {
      const asked = async (more) => worker.fetch(send(handler, { ...(await asking(BAO, handler, { ...ask, ...more })), ...after }), held);
      assert.equal((await asked({})).status, 402, `${handler}, with no licence shown`);
      assert.equal((await asked({ licence: mine })).status, past, `${handler}, with its licence`);
    }

    // A device the store here knows is asked of as ever: its licence,
    // which the store backs, costs a handler that decides here nothing.
    const { licence: hers } = await (await worker.fetch(send('licence', await asking(ADA, 'licence')), held)).json();
    objects.asked.length = 0;
    assert.equal((await worker.fetch(send('turn', await asking(ADA, 'turn', { licence: hers })), held)).status, 200);
    assert.equal((await worker.fetch(send('waiting', await asking(ADA, 'waiting', { what: 'rated 50', pool: 'rated', target: 50, licence: hers })), held)).status, 200);
    assert.deepEqual(objects.asked, [], 'no object asked');
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("a device dropped from its account, still holding its licence, is refused, and spends nothing of what the account's own devices have", async () => {
  forgetProviderKeys();
  const store = await household(Date.now(), ADA.public);
  const account = await accountOfSub(store, 'sub_9');
  const { codes } = await makeBackups(store, account);
  const { send } = serving(store);
  const held = { ...env, ...signedInAs, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: seenFrom(kvOf(store)), HOUSEHOLD: objectsAt(seenFrom(kvOf(store))) };
  const p = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const realFetch = globalThis.fetch;
  globalThis.fetch = upstreams(p);
  okUpstream.calls.length = 0;
  try {
    assert.equal((await worker.fetch(send('licence', await asking(BAO, 'licence')), held)).status, 402);
    const typed = codes[0].code;
    const { licence: kept } = await (await worker.fetch(send('claim', await asking(BAO, 'claim', { what: typed, ticket: typed })), held)).json();
    const { licence: hers } = await (await worker.fetch(send('licence', await asking(ADA, 'licence')), held)).json();
    // Ada drops it. It keeps the licence it was given, good for a month.
    assert.equal((await worker.fetch(send('devices', await asking(ADA, 'devices', { what: BAO.public, drop: BAO.public, licence: hers })), held)).status, 200);
    const ask = async (pair, handler, more = {}) => worker.fetch(send(handler, await asking(pair, handler, { ...more, licence: pair === BAO ? kept : hers })), held);
    const open = { what: 'open ', want: 'open' };

    // The account it names does not know it now, and says so.
    assert.equal((await ask(BAO, 'activate', open)).status, 402);
    assert.equal((await ask(BAO, 'turn')).status, 402);
    assert.equal(okUpstream.calls.length, 0, 'no credentials made for it');
    // Asked and asked again, it spends what is kept for devices the store
    // where they ask has yet to hear of, the size of the account's reads...
    for (let spent = 2; spent < SERVICE_DEFAULTS.householdReadsPerHour; spent++) assert.equal((await ask(BAO, 'activate', open)).status, 402);
    const token = await p.token({ sub: 'sub-2', nonce: await nonceFor(BAO.public) });
    const drop = { what: ADA.public, drop: ADA.public };
    for (const [handler, more] of [['activate', open], ['ticket'], ['backups'], ['devices'], ['devices', drop], ['profile'], ['attest', { provider: 'google', token }]]) {
      assert.equal((await ask(BAO, handler, more)).status, 429, `${handler}: spent for the hour`);
    }
    // ...and nothing of what the account's own devices have.
    assert.equal((await ask(ADA, 'activate', open)).status, 200, 'taking it up');
    assert.equal((await ask(ADA, 'devices')).status, 200, 'reading it');
    assert.equal((await ask(ADA, 'backups', { what: 'rotate', rotate: true })).status, 200, 'changing it');
    assert.equal((await ask(ADA, 'turn')).status, 200);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a sign-in binds only a key that asked to be bound, so nobody\'s account is put on somebody else\'s device', async () => {
  // The nonce is the caller's to choose, so a stranger can have the
  // provider sign his own account over Ada's key. Bound to her key, his
  // account would then supersede it — and carry her subscription to his.
  forgetProviderKeys();
  const now = Date.now();
  const store = await household(now, ADA.public);
  const p = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const realFetch = globalThis.fetch;
  globalThis.fetch = p.fetch;
  try {
    const { held: base, send } = serving(store);
    const held = { ...base, ...signedInAs };
    const overHers = await p.token({ sub: 'mallory', nonce: await nonceFor(ADA.public) });
    const bound = await worker.fetch(send('attest', { key: ADA.public, provider: 'google', token: overHers }), held);
    assert.equal(bound.status, 401, 'her key did not ask');
    const overMine = await p.token({ sub: 'mallory', nonce: await nonceFor(BAO.public) });
    const moved = await worker.fetch(send('supersede', await asking(BAO, 'supersede', { provider: 'google', token: overMine })), held);
    assert.equal(moved.status, 404, 'his sign-in is linked to no account, so there is nothing to come into');
    assert.equal(await entitlementOf(store, BAO.public, { now }), null);
    assert.deepEqual((await devicesOn(store, await accountOfSub(store, 'sub_9'))).map((d) => d.key), [ADA.public]);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a token whose signature is not base64 is a sign-in that does not check out, not a fall', async () => {
  forgetProviderKeys();
  const p = await provider({ iss: 'https://accounts.google.com', aud: signedInAs.OH_GOOGLE_AUDIENCE });
  const good = await p.token({ sub: 'sub-1', nonce: await nonceFor(KEY) });
  const [head, body] = good.split('.');
  assert.equal(await whoSignedIn('google', `${head}.${body}.not*base64`, KEY, signedInAs, p.fetch), null);
});

test('local mode has a token of its own, and it is nothing anywhere else', async () => {
  const local = { ...signedInAs, OH_OPEN_HOUSE: '1' };
  const open = { open: true };
  assert.deepEqual(await whoSignedIn('google', 'local:sub-1', KEY, local, fetch, open), { provider: 'google', sub: 'sub-1' });
  assert.equal(await whoSignedIn('google', 'local:sub-1', KEY, signedInAs), null, 'not in production');
  assert.equal(await whoSignedIn('nobody', 'local:sub-1', KEY, local, fetch, open), null);
  assert.equal(await whoSignedIn('google', 'local:', KEY, local, fetch, open), null);
  // The house is open only where it is set and only on this machine: set
  // in a production project by mistake, it opens nothing.
  assert.equal(openHouse(local, new Request('http://127.0.0.1:8788/api/attest')), true);
  assert.equal(openHouse(local, new Request('http://localhost/api/licence')), true);
  assert.equal(openHouse(local, new Request('https://open-hearts.pages.dev/api/attest')), false);
  assert.equal(openHouse(signedInAs, new Request('http://127.0.0.1:8788/api/attest')), false);
});

// ---- managing a web subscription ------------------------------------------

/// Stripe, as far as the portal needs it: what was asked, and an answer.
const stripeFake = ({ customerOf = {}, portal = 'https://billing.stripe.com/p/session/test_1' } = {}) => {
  const calls = [];
  const f = async (url, init = {}) => {
    calls.push({ url, init });
    const sub = url.match(/\/v1\/subscriptions\/(.+)$/)?.[1];
    if (sub) return customerOf[sub] ? Response.json({ id: sub, customer: customerOf[sub] }) : new Response('no', { status: 404 });
    if (url.endsWith('/v1/billing_portal/sessions')) return Response.json({ url: portal });
    return new Response('no', { status: 400 });
  };
  f.calls = calls;
  return f;
};

test('a checkout keeps its customer, and so does a subscription event, for the portal', async () => {
  const store = memoryStore();
  const now = Date.UTC(2026, 8, 16);
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', customer: 'cus_A1', metadata: { key: KEY } } } }, store, { now });
  assert.deepEqual(await store.get('SUB#sub_9', 'CUSTOMER'), { customer: 'cus_A1' });
  await record({ type: 'customer.subscription.updated', data: { object: { id: 'sub_8', customer: 'cus_B2', current_period_end: 1800000000 } } }, store, { now });
  assert.deepEqual(await store.get('SUB#sub_8', 'CUSTOMER'), { customer: 'cus_B2' });
  await record({ type: 'customer.subscription.updated', data: { object: { id: 'sub_7', customer: 'not a customer' } } }, store, { now });
  assert.equal(await store.get('SUB#sub_7', 'CUSTOMER'), null);
  // A household's devices are listed without it.
  assert.deepEqual((await devicesOn(store, await accountOfSub(store, 'sub_9'))).map((d) => d.key), [KEY]);
});

test('any device on a web subscription opens its portal, and comes back to this site', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  await store.put('SUB#sub_9', 'CUSTOMER', { customer: 'cus_A1' });
  await claimWith(OTHER, (await ticketFor(KEY, store, { now })).body.ticket, store, { now });
  const stripe = stripeFake();
  const env = { OH_STRIPE_SECRET: 'sk_test' };
  for (const key of [KEY, OTHER]) {
    const out = await manage(key, 'https://x/play/', store, env, stripe);
    assert.deepEqual(out, { status: 200, body: { url: 'https://billing.stripe.com/p/session/test_1' } });
  }
  const form = new URLSearchParams(stripe.calls[0].init.body);
  assert.equal(form.get('customer'), 'cus_A1');
  assert.equal(form.get('return_url'), 'https://x/play/');
  assert.equal(stripe.calls[0].init.headers.authorization, 'Bearer sk_test');
});

test('a subscription with no customer on record: Stripe is asked once, and it is kept', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const stripe = stripeFake({ customerOf: { sub_9: 'cus_Old' } });
  const env = { OH_STRIPE_SECRET: 'sk_test' };
  assert.equal((await manage(KEY, 'https://x/', store, env, stripe)).status, 200);
  assert.equal((await manage(KEY, 'https://x/', store, env, stripe)).status, 200);
  assert.equal(stripe.calls.filter((c) => c.url.includes('/v1/subscriptions/')).length, 1);
  assert.deepEqual(await store.get('SUB#sub_9', 'CUSTOMER'), { customer: 'cus_Old' });
  assert.equal((await manage(KEY, 'https://x/', await household(now), env, stripeFake())).status, 502, 'and one Stripe does not know');
});

test('no portal for a device off the subscription, a store or open-house one, or a shop not open', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  await store.put('SUB#sub_9', 'CUSTOMER', { customer: 'cus_A1' });
  const env = { OH_STRIPE_SECRET: 'sk_test' };
  assert.equal((await manage(OTHER, 'https://x/', store, env, stripeFake())).status, 402, 'never on it');
  await claimWith(OTHER, (await ticketFor(KEY, store, { now })).body.ticket, store, { now });
  await dropDevice(KEY, OTHER, store, { now });
  assert.equal((await manage(OTHER, 'https://x/', store, env, stripeFake())).status, 402, 'dropped');
  const open = memoryStore();
  await entitlementOf(open, KEY, { now, openHouse: true });
  assert.equal((await manage(KEY, 'https://x/', open, env, stripeFake())).status, 409, 'local mode bought nothing');
  assert.equal((await manage(KEY, 'https://x/', store, {}, stripeFake())).status, 503);
});

test('the manage route: signed by the device, and back only to this site', async () => {
  const now = Date.now();
  const store = await household(now, ADA.public);
  await store.put('SUB#sub_9', 'CUSTOMER', { customer: 'cus_A1' });
  const { held, send } = serving(store);
  const shop = { ...held, OH_STRIPE_SECRET: 'sk_test' };
  const realFetch = globalThis.fetch;
  globalThis.fetch = stripeFake();
  try {
    assert.equal((await worker.fetch(send('manage', { key: ADA.public, back: 'https://dev.open-hearts.pages.dev/play/' }), shop)).status, 401);
    assert.equal((await worker.fetch(send('manage', await asking(ADA, 'manage', { back: 'https://elsewhere.example/' })), shop)).status, 400);
    const ok = await worker.fetch(send('manage', await asking(ADA, 'manage', { back: 'https://dev.open-hearts.pages.dev/play/' })), shop);
    assert.equal(ok.status, 200);
    assert.equal((await ok.json()).url, 'https://billing.stripe.com/p/session/test_1');
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a game\'s record: sent by a player signed for its table, kept, and shown only to an account\'s device in use', async () => {
  const kept = new Map();
  const bucket = {
    head: async (k) => (kept.has(k) ? {} : null),
    get: async (k) => (kept.has(k) ? { body: new Blob([kept.get(k)]).stream() } : null),
    put: async (k, body) => kept.set(k, Buffer.from(body)),
  };
  const store = await household(Date.now(), ADA.public);
  const { held, send } = serving(store);
  const env = { ...held, OH_RECORDS: bucket };
  const table = '0123456789abcdef0123456789abcdef';
  // A play of Ada's, made as the table makes one (records.mjs).
  const body = { hand: 0, turn: 4, seat: 0, card: '2C' };
  const id = await eventIdOf(table, { author: ADA.public, kind: 'play', body });
  const play = { id, author: ADA.public, kind: 'play', body, sig: signer.sign(ADA.secret, id) };
  // Each person's seat with the service's licence for its key, as a
  // seating carries them.
  const service = { signer, secret: SERVICE_SECRET, service: SERVICE_KEY };
  const seats = [
    { key: ADA.public, licence: await licenceFor(ADA.public, ACCT, '2027-01-01', service) },
    { key: BAO.public, licence: await licenceFor(BAO.public, '0b'.repeat(16), '2027-01-01', service) },
    { bot: 'Romeo' },
    { bot: 'Juliet' },
  ];
  const recordOf = (seats) => JSON.stringify({ v: 3, spec: { id: table, seats }, log: [{ n: 0, t: 1000, e: play }] });
  const record = recordOf(seats);
  // Signed for another table: not this one's.
  const wrong = await worker.fetch(send('record', await asking(ADA, 'record', { what: 'f'.repeat(32), table, record })), env);
  assert.equal(wrong.status, 401);
  // Sent by a device with no subscription, or not its account's in use.
  assert.equal((await worker.fetch(send('record', await asking(CY, 'record', { what: table, table, record })), env)).status, 402);
  assert.equal((await worker.fetch(send('record', await asking(ADA, 'record', { what: table, table, record })), env)).status, 409);
  assert.equal((await worker.fetch(send('review', await asking(ADA, 'review', { what: table, table })), env)).status, 409, 'nor looked at');
  assert.equal(kept.size, 0);
  await worker.fetch(send('activate', await asking(ADA, 'activate', { what: 'open ', want: 'open' })), env);
  // Seats the app would not show: Bao's without its licence.
  const unlicensed = recordOf(seats.map((s, i) => (i === 1 ? { key: BAO.public } : s)));
  const refused = await worker.fetch(send('record', await asking(ADA, 'record', { what: table, table, record: unlicensed })), env);
  assert.equal(refused.status, 403);
  assert.deepEqual(await refused.json(), { error: 'seat 1 has no licence for its key' });
  assert.equal(kept.size, 0);
  const sent = await worker.fetch(send('record', await asking(ADA, 'record', { what: table, table, record })), env);
  assert.equal(sent.status, 200);
  assert.deepEqual(await sent.json(), { kept: true });

  // Not by its address alone: looking at games is live play.
  assert.equal((await worker.fetch(new Request(`https://dev.open-hearts.pages.dev/api/record/${table}`), env)).status, 404);
  assert.equal((await worker.fetch(send('review', await asking(CY, 'review', { what: table, table })), env)).status, 402, 'no subscription');
  const got = await worker.fetch(send('review', await asking(ADA, 'review', { what: table, table })), env);
  assert.equal(got.status, 200);
  assert.equal(got.headers.get('content-encoding'), 'gzip');
  const { gunzipSync } = await import('node:zlib');
  assert.equal(gunzipSync(Buffer.from(await got.arrayBuffer())).toString(), record);

  // Nor a game the account is at.
  await worker.fetch(send('activate', await asking(ADA, 'activate', { what: `renew ${table}`, want: 'renew', seated: table })), env);
  assert.equal((await worker.fetch(send('review', await asking(ADA, 'review', { what: table, table })), env)).status, 403);
});

// ---- one device at a time ------------------------------------------------

/// [store] with ADA on sub_9 and BAO brought in by a code: one account,
/// two devices.
const twoDevices = async (now) => {
  const store = await household(now, ADA.public);
  await claimWith(BAO.public, (await ticketFor(ADA.public, store, { now })).body.ticket, store, { now });
  return store;
};

test("an account's object holds a device by both of its own rows: the device's entitlement naming the account, and the account's row for the device", async () => {
  // What it answers is what taking the account up goes by, and what a
  // handler deciding where the device asks goes by when the store there
  // has yet to hear of the device (licence.mjs, heldAccount).
  const now = Date.now();
  const store = await twoDevices(now);
  const account = await accountOfKey(store, ADA.public);
  const held = async (key, of = account) => (await householdOp({ op: 'held', key, account: of }, store, { now })).status;
  assert.equal(await held(BAO.public), 200);
  // A device that moved on from another account, whose row there was
  // left behind (its new account's object read the old one's name from
  // a store that had yet to show it), is not held there.
  const before = '0b'.repeat(16);
  await store.put(`ACCOUNT#${before}`, `DEVICE#${BAO.public}`, { bound_at: dayOf(now) });
  assert.equal(await held(BAO.public, before), 402);
  assert.equal((await activate({ key: BAO.public, account: before, want: 'open' }, store, activeInStore(store), { now })).status, 402, 'nor taken up there');
  // Nor is one whose row in the account has gone, whatever its own row says.
  await store.del(`ACCOUNT#${account}`, `DEVICE#${BAO.public}`);
  assert.equal(await held(BAO.public), 402);
  assert.equal((await activate({ key: BAO.public, account, want: 'open' }, store, activeInStore(store), { now })).status, 402, 'nor taken up');
});

test('the newest device to take an account up is the one in use, at once; the one before is superseded', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await twoDevices(now);
  const account = await accountOfSub(store, 'sub_9');
  const active = activeInStore(store);
  const ask = (key, want, more = {}) => activate({ key, account, want, ...more }, store, active, { now });

  assert.deepEqual((await ask(ADA.public, 'open')).body, { epoch: 1, licensed_until: '2027-09-16', took: false, profile: 0 });
  assert.equal((await ask(ADA.public, 'renew')).body.epoch, 1, 'still hers');
  assert.equal((await ask(BAO.public, 'renew')).status, 409, 'a renewal takes nothing');

  const took = await ask(BAO.public, 'open');
  assert.deepEqual(took.body, { epoch: 2, licensed_until: '2027-09-16', took: true, profile: 0 });
  const superseded = await ask(ADA.public, 'renew');
  assert.equal(superseded.status, 409);
  assert.equal(superseded.body.superseded, true);

  // Taken back, the same way: the newest to ask.
  assert.equal((await ask(ADA.public, 'open')).body.epoch, 3);
  // At a table, the other is asked first; told to, it takes it anyway.
  const table = '0123456789abcdef0123456789abcdef';
  assert.equal((await ask(ADA.public, 'renew', { seated: table })).status, 200);
  assert.deepEqual((await ask(BAO.public, 'open')).body, { error: 'in a game on another device', seated: true });
  assert.equal((await ask(BAO.public, 'take')).body.epoch, 4);
  assert.equal((await ask(ADA.public, 'renew')).status, 409);
  // A device at a table that has not been heard from for a while is not
  // in use: the account is simply taken.
  await ask(BAO.public, 'renew', { seated: table });
  const later = await activate({ key: ADA.public, account, want: 'open' }, store, active, { now: now + 50 * 60000 });
  assert.equal(later.body.epoch, 5);

  // Nobody else's device, and no device without a subscription.
  assert.equal((await ask(CY.public, 'take')).status, 402);
  await record({ type: 'customer.subscription.deleted', data: { object: { id: 'sub_9' } } }, store, { now });
  assert.equal((await activate({ key: ADA.public, account, want: 'renew' }, store, active, { now: now + 2 * 86400000 })).status, 402);
});

test('the relay is told to close a superseded device\'s sockets where it has seen them, and a dropped device in use is cut off too', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await twoDevices(now);
  const account = await accountOfSub(store, 'sub_9');
  const told = [];
  const revoke = async (tags, a, epoch) => told.push({ tags, account: a, epoch });
  const op = (o) => householdOp({ account, ...o }, store, { now, revoke });

  assert.equal((await op({ op: 'activate', key: ADA.public, want: 'open' })).body.epoch, 1);
  assert.equal((await op({ op: 'seen', key: ADA.public, epoch: 1, tag: 'online' })).status, 200);
  assert.equal((await op({ op: 'seen', key: ADA.public, epoch: 1, tag: 'queue:rated' })).status, 200);
  assert.equal((await op({ op: 'seen', key: ADA.public, epoch: 1, tag: 'online' })).status, 200);
  assert.equal(told.length, 0);

  await op({ op: 'activate', key: BAO.public, want: 'open' });
  assert.deepEqual(told, [{ tags: ['online', 'queue:rated'], account, epoch: 2 }]);
  assert.equal((await op({ op: 'seen', key: ADA.public, epoch: 1, tag: 'online' })).status, 409, 'and the relay opens none for it');
  assert.equal((await op({ op: 'seen', key: BAO.public, epoch: 2, tag: 'online' })).status, 200);

  // The list says which is in use.
  const listed = (await op({ op: 'list', key: ADA.public })).body.devices;
  assert.deepEqual(listed.map((d) => [d.key, d.active ?? false]).sort(), [[ADA.public, false], [BAO.public, true]].sort());

  // Dropped while in use: cut off now, not at the end of its hour.
  told.length = 0;
  assert.equal((await op({ op: 'drop', key: ADA.public, device: BAO.public })).status, 200);
  assert.deepEqual(told, [{ tags: ['online'], account, epoch: 3 }]);
  assert.equal((await op({ op: 'seen', key: BAO.public, epoch: 2, tag: 'online' })).status, 409);
});

test('the activation route: signed by the service, an hour and never past the day paid to; what is asked is signed', async () => {
  const now = Date.now();
  const store = await twoDevices(now);
  const account = await accountOfSub(store, 'sub_9');
  const { held, send } = serving(store);
  const opened = await worker.fetch(send('activate', await asking(ADA, 'activate', { what: 'open ', want: 'open' })), held);
  assert.equal(opened.status, 200);
  const { activation } = await opened.json();
  assert.deepEqual({ ...activation, sig: typeof activation.sig }, { account, key: ADA.public, epoch: 1, until: activation.until, sig: 'string' });
  assert.ok(activation.until > now / 1000 + 3500 && activation.until <= now / 1000 + 3600, 'an hour');
  const digest = await sha(`oh-active/1\n${account}\n${ADA.public}\n1\n${activation.until}`);
  assert.equal(signer.verify(SERVICE_KEY, digest, activation.sig), true);

  // Taking the account is the device's own word: a renewal is not
  // replayed as a take, nor anybody's request made for another key.
  const plain = await asking(BAO, 'activate', { what: 'renew ', want: 'renew' });
  assert.equal((await worker.fetch(send('activate', { ...plain, want: 'take' }), held)).status, 401);
  assert.equal((await worker.fetch(send('activate', await asking(BAO, 'activate', { what: 'nope ', want: 'nope' })), held)).status, 400);
  const took = await worker.fetch(send('activate', await asking(BAO, 'activate', { what: 'take ', want: 'take' })), held);
  assert.deepEqual([took.status, (await took.json()).took], [200, true]);
  const old = await worker.fetch(send('activate', await asking(ADA, 'activate', { what: 'renew ', want: 'renew' })), held);
  assert.equal(old.status, 409);
  assert.match((await old.json()).error, /^superseded:/);

  // A subscription paid to tomorrow gives no more than that.
  const short = await household(now, CY.public);
  await record({ type: 'customer.subscription.updated', data: { object: { id: 'sub_9', current_period_end: Math.floor(now / 1000) } } }, short, { now });
  const { held: shortHeld } = serving(short);
  const near = await worker.fetch(send('activate', await asking(CY, 'activate', { what: 'open ', want: 'open' })), shortHeld);
  const until = (await near.json()).activation.until;
  assert.ok(until <= Date.parse(`${dayOf(now)}T00:00:00Z`) / 1000 + 86400, 'not past the end of the day paid to');
});
