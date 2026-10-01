// The Pages worker, in node's own test runner: node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import worker, {
  allowedOrigin,
  askedBy,
  attest,
  checkout,
  claimWith,
  dayAfter,
  dayOf,
  devicesOn,
  dropDevice,
  entitlementOf,
  forgetProviderKeys,
  licence,
  licenceFor,
  loginRow,
  memoryStore,
  mint,
  record,
  requestStatement,
  sameSite,
  serversOf,
  signerOn,
  supersede,
  ticketFor,
  webhookSigned,
  whoSignedIn,
} from './worker.mjs';
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
  assert.equal(allowedOrigin('https://dev.open-hearts.pages.dev'), 'https://dev.open-hearts.pages.dev');
  assert.equal(allowedOrigin('https://open-hearts.pages.dev'), 'https://open-hearts.pages.dev');
  assert.equal(allowedOrigin('http://localhost:8788'), 'http://localhost:8788');
  assert.equal(allowedOrigin('http://127.0.0.1:8788'), 'http://127.0.0.1:8788');
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
  assert.deepEqual(await mint({}, okUpstream), { status: 503, body: { error: 'turn not configured' } });
  assert.deepEqual(await mint({ OH_TURN_KEY_ID: 'kid' }, okUpstream), { status: 503, body: { error: 'turn not configured' } });
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
    body: { error: 'turn not configured' },
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
  const ok = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'OPTIONS', headers: { origin: 'http://127.0.0.1:8788' } }), env);
  assert.equal(ok.status, 204);
  assert.equal(ok.headers.get('access-control-allow-origin'), 'http://127.0.0.1:8788');
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

// ---- the licence --------------------------------------------------------

/// A store with the rows a paid-up subscription leaves.
const subscribed = (key, { renews_at, licensed_until = renews_at, cancelled_at = null }) =>
  memoryStore({
    [`KEY#${key}|ENTITLEMENT`]: JSON.stringify({ subscription: 'sub_1', licensed_until, at: '2026-01-01' }),
    [`SUB#sub_1|META`]: JSON.stringify({ source: 'stripe', txn_ref: 'cs_1', renews_at, cancelled_at }),
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
  const signed = await licenceFor(key, '2026-10-17', { signer, secret: SERVICE_SECRET, service: SERVICE_KEY });
  assert.deepEqual({ ...signed, sig: typeof signed.sig }, { key, until: '2026-10-17', plan: 'year', sig: 'string' });
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`oh-licence/1\n${key}\n2026-10-17\nyear`));
  const digestHex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  assert.equal(signer.verify(SERVICE_KEY, digestHex, signed.sig), true);
  // Another service's key does not verify it, which is the whole point
  // of the app having one baked in.
  const other = 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
  assert.equal(signer.verify(other, digestHex, signed.sig), false);
});

test('a secret and a public key that are not a pair is a refusal, not a licence nobody can read', async () => {
  const wrong = 'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9';
  assert.equal(await licenceFor(KEY, '2026-10-17', { signer, secret: wrong, service: SERVICE_KEY }), null);
});

test('entitlement: one read while the device is paid up', async () => {
  const store = subscribed(KEY, { renews_at: '2027-01-01' });
  const held = await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16) });
  assert.equal(held.subscription, 'sub_1');
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

test('entitlement: a key nobody has heard of gets nothing, unless it is local mode', async () => {
  const store = memoryStore();
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16) }), null);
  const open = await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 16), openHouse: true });
  assert.equal(open.licensed_until, '2026-10-17');
  assert.equal(open.subscription, `local-${KEY.slice(0, 16)}`);
  // And it is a subscription with the device bound under it, like any
  // other, rather than a special case further down.
  assert.deepEqual(await store.get(`SUB#${open.subscription}`, `DEVICE#${KEY}`), { bound_at: '2026-09-16' });
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

test('the licence route: a key is required, and what comes back verifies', async () => {
  const at = 'https://dev.open-hearts.pages.dev/api/licence';
  const withStore = { ...env, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kvOf(subscribed(ADA.public, { renews_at: '2027-01-01' })) };
  const bad = await worker.fetch(new Request(at, { method: 'POST', body: JSON.stringify({ key: 'short' }) }), withStore);
  assert.equal(bad.status, 400);
  const res = await worker.fetch(
    new Request(at, { method: 'POST', headers: { origin: 'http://127.0.0.1:9000' }, body: JSON.stringify(await asking(ADA, 'licence')) }),
    withStore,
  );
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('access-control-allow-origin'), 'http://127.0.0.1:9000');
  const { licence: signed } = await res.json();
  assert.equal(signed.key, ADA.public);
  assert.equal(signed.plan, 'year');
  const canonical = `oh-licence/1\n${signed.key}\n${signed.until}\n${signed.plan}`;
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
  const shop = { OH_STRIPE_SECRET: 'sk_test', OH_STRIPE_PRICE: 'price_1' };
  const out = await checkout(KEY, 'https://x/play/?bought=1', 'https://x/play/', shop, stripe);
  assert.deepEqual(out, { status: 200, body: { url: 'https://checkout.stripe.com/c/pay/cs_test_1' } });
  assert.equal(calls[0].url, 'https://api.stripe.com/v1/checkout/sessions');
  assert.equal(calls[0].init.headers.authorization, 'Bearer sk_test');
  const form = new URLSearchParams(calls[0].init.body);
  assert.equal(form.get('mode'), 'subscription');
  assert.equal(form.get('line_items[0][price]'), 'price_1');
  assert.equal(form.get('success_url'), 'https://x/play/?bought=1');
  assert.equal(form.get('metadata[key]'), KEY);
  assert.equal(form.get('client_reference_id'), KEY);
  assert.equal(form.get('subscription_data[metadata][key]'), KEY, 'so a renewal a year from now still names the device');
});

test('checkout: no keys is a shop that is not open, not a broken one', async () => {
  assert.deepEqual(await checkout(KEY, 'https://x/', 'https://x/', {}), { status: 503, body: { error: 'the shop is not open yet' } });
  const refused = await checkout(KEY, 'https://x/', 'https://x/', { OH_STRIPE_SECRET: 's', OH_STRIPE_PRICE: 'p' }, async () => new Response('no', { status: 401 }));
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
  assert.deepEqual(await store.get('SUB#sub_9', `DEVICE#${KEY}`), { bound_at: '2026-09-16' });
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
  await record({ type: 'checkout.session.completed', data: { object: { status: 'complete', subscription: 'sub_9', client_reference_id: KEY } } }, store, { now });
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

test('the checkout route: the key, and somewhere on this site to come back to', async () => {
  const at = 'https://dev.open-hearts.pages.dev/api/checkout';
  const shop = { ...env, OH_STRIPE_SECRET: 'sk', OH_STRIPE_PRICE: 'price_1' };
  const send = (body) => new Request(at, { method: 'POST', body: JSON.stringify(body) });
  assert.equal((await worker.fetch(send({ key: 'short', back: '/play/', cancelled: '/play/' }), shop)).status, 400);
  const away = await worker.fetch(send(await asking(ADA, 'checkout', { back: 'https://evil.example/', cancelled: '/play/' })), shop);
  assert.equal(away.status, 400, 'a payment does not land where the caller says');
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({ url: 'https://checkout.stripe.com/c/pay/cs_1' }), { status: 200 });
  try {
    const res = await worker.fetch(send(await asking(ADA, 'checkout', { back: '/play/?bought=1', cancelled: '/play/' })), shop);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).url, 'https://checkout.stripe.com/c/pay/cs_1');
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
  assert.deepEqual((await devicesOn(store, 'sub_9')).map((d) => d.key), [KEY, OTHER]);

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
  assert.equal((await devicesOn(store, 'sub_9')).length, 5);
  const sixth = await ticketFor(KEY, store, { now });
  assert.equal(sixth.status, 409);
  assert.deepEqual(sixth.body, { error: 'five devices already', devices: 5, most: 5 });
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
  assert.equal((await devicesOn(store, 'sub_9')).length, 5);
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
  assert.deepEqual((await devicesOn(store, 'sub_9')).map((d) => d.key), [OTHER]);
  assert.equal(await entitlementOf(store, KEY, { now: Date.UTC(2026, 8, 17) }), null);
  assert.equal((await entitlementOf(store, OTHER, { now })).licensed_until, '2027-09-16');

  // And nobody drops a device off somebody else's subscription.
  assert.equal((await dropDevice(THIRD, OTHER, store, { now })).status, 402);
  assert.equal((await dropDevice(OTHER, THIRD, store, { now })).status, 404);
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
// is anybody's, and each of these was answered for anybody before.

test('a key alone is nobody: a household is not listed, dropped from or joined by whoever can read a key', async () => {
  const now = Date.now();
  const store = await household(now, ADA.public);
  const { held, send } = serving(store);

  // Ada's key, as a stranger read it off the relay.
  assert.equal((await worker.fetch(send('devices', { key: ADA.public }), held)).status, 401, 'her devices are not listed to him');
  assert.equal((await worker.fetch(send('devices', { key: ADA.public, drop: ADA.public }), held)).status, 401);
  assert.deepEqual((await devicesOn(store, 'sub_9')).map((d) => d.key), [ADA.public], 'nor is she dropped off what she paid for');
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

test('TURN is for a device that holds a licence, and asks for it itself', async () => {
  // Credentials are a relay anybody can push anything through, billed
  // to the project by the gigabyte: they were minted for any 64 hex.
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
  // Paying for somebody else's key moved their device onto a
  // subscription the payer could then end.
  const shop = { ...env, OH_STRIPE_SECRET: 'sk', OH_STRIPE_PRICE: 'price_1' };
  const send = (body) => new Request('https://dev.open-hearts.pages.dev/api/checkout', { method: 'POST', body: JSON.stringify(body) });
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({ url: 'https://checkout.stripe.com/c/pay/cs_1' }), { status: 200 });
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
  assert.equal((await entitlementOf(store, KEY, { now })).subscription, 'sub_9', 'still on her own');
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
  assert.deepEqual((await devicesOn(store, 'sub_9')).map((d) => d.key), [KEY], 'gone from the first');
  // Bound the same day, so the tiebreak is the key: both are there,
  // whichever way round they sort.
  assert.deepEqual((await devicesOn(store, 'sub_2')).map((d) => d.key).sort(), [OTHER, THIRD].sort());
  assert.equal((await entitlementOf(store, OTHER, { now })).subscription, 'sub_2');

  // A subscription that has ended keeps nobody.
  await record({ type: 'customer.subscription.deleted', data: { object: { id: 'sub_9' } } }, store, { now });
  const after = Date.UTC(2026, 8, 18);
  const again = await ticketFor(THIRD, store, { now: after });
  assert.equal((await claimWith(KEY, again.body.ticket, store, { now: after })).status, 200);
  assert.equal((await entitlementOf(store, KEY, { now: after })).subscription, 'sub_2');

  // Nor does local mode's open house, which licenses any device that
  // asks and so is where every device in the browser suite starts.
  const local = memoryStore();
  await entitlementOf(local, OTHER, { now, openHouse: true });
  await entitlementOf(local, THIRD, { now, openHouse: true });
  const code = await ticketFor(THIRD, local, { now });
  assert.equal((await claimWith(OTHER, code.body.ticket, local, { now })).status, 200);
  assert.equal((await entitlementOf(local, OTHER, { now })).subscription, `local-${THIRD.slice(0, 16)}`);
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

test('two devices spending one code at once both get in', { todo: 'KV has no compare-and-set: a code is read unspent by both before either writes (needs a Durable Object or D1 for the household; docs/security-review.md)' }, async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  for (const key of ['11', '22', '33'].map((b) => b.repeat(32))) {
    await claimWith(key, (await ticketFor(KEY, store, { now })).body.ticket, store, { now });
  }
  const last = await ticketFor(KEY, store, { now });
  const both = await Promise.all([OTHER, THIRD].map((key) => claimWith(key, last.body.ticket, store, { now })));
  assert.deepEqual(both.map((c) => c.status).sort(), [200, 409], 'one code, one device');
  assert.equal((await devicesOn(store, 'sub_9')).length, 5);
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

test('attest binds an account to one device, and says so when it is already on another', async () => {
  const store = memoryStore();
  const who = { provider: 'google', sub: 'sub-1' };
  const now = Date.UTC(2026, 8, 16);
  assert.deepEqual(await attest(who, KEY, store, signedInAs, { now }), { status: 200, body: { attested: '2026-09-16' } });
  assert.deepEqual(await store.get(await loginRow(who, signedInAs), 'IDENTITY'), { key: KEY, created_at: '2026-09-16' });
  // Nothing on the key's own side leads back to the provider's subject.
  assert.deepEqual(await store.get(`KEY#${KEY}`, 'META'), { provider: 'google', attested_at: '2026-09-16' });

  // The same device again is the same binding, not a second one.
  assert.equal((await attest(who, KEY, store, signedInAs, { now })).status, 200);
  // Another device is a refusal: moving is supersede's to say.
  assert.equal((await attest(who, OTHER, store, signedInAs, { now })).status, 409);
});

test('supersede brings the subscription to the new device and takes the old one off it', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const who = { provider: 'google', sub: 'sub-1' };
  await attest(who, KEY, store, signedInAs, { now });

  const moved = await supersede(who, OTHER, store, signedInAs, { now: Date.UTC(2026, 9, 1) });
  assert.deepEqual(moved.body, { superseded: KEY, at: '2026-10-01' });
  assert.deepEqual(await store.get(`KEY#${OTHER}`, 'SUPERSEDES'), { predecessor: KEY, at: '2026-10-01' });
  assert.equal((await entitlementOf(store, OTHER, { now })).subscription, 'sub_9');
  assert.deepEqual((await devicesOn(store, 'sub_9')).map((d) => d.key), [KEY, OTHER]);
  // The login points at the new device from here, so the next sign-in
  // on it is not a supersession of itself.
  assert.deepEqual((await supersede(who, OTHER, store, signedInAs, { now })).body, { superseded: null, at: '2026-09-16' });
});

test('a full household superseded drops the device that was replaced, not somebody else\'s', async () => {
  const now = Date.UTC(2026, 8, 16);
  const store = await household(now);
  const keys = ['11', '22', '33', '44'].map((b) => b.repeat(32));
  for (const key of keys) {
    const made = await ticketFor(KEY, store, { now });
    await claimWith(key, made.body.ticket, store, { now });
  }
  assert.equal((await devicesOn(store, 'sub_9')).length, 5);
  const who = { provider: 'google', sub: 'sub-1' };
  await attest(who, KEY, store, signedInAs, { now });
  await supersede(who, OTHER, store, signedInAs, { now });
  const after = (await devicesOn(store, 'sub_9')).map((d) => d.key);
  assert.equal(after.length, 5);
  assert.equal(after.includes(OTHER), true, 'the new device is on it');
  assert.equal(after.includes(KEY), false, 'the one it replaced is not');
  for (const key of keys) assert.equal(after.includes(key), true, 'and nobody else was moved for it');
});

test('supersede has nothing to move for an account nobody has signed in with', async () => {
  const store = memoryStore();
  assert.equal((await supersede({ provider: 'google', sub: 'nobody' }, KEY, store, signedInAs)).status, 404);
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

    // The same account on a new phone: attest refuses, supersede moves.
    const theirs = await p.token({ sub: 'sub-1', nonce: await nonceFor(BAO.public) });
    assert.equal((await worker.fetch(send('attest', await asking(BAO, 'attest', { provider: 'google', token: theirs })), held)).status, 409);
    const moved = await worker.fetch(send('supersede', await asking(BAO, 'supersede', { provider: 'google', token: theirs })), held);
    assert.equal(moved.status, 200);
    assert.equal((await moved.json()).licence.key, BAO.public);
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
    assert.equal(moved.status, 404, 'his account is on no device, so there is nothing to carry');
    assert.equal(await entitlementOf(store, BAO.public, { now }), null);
    assert.deepEqual((await devicesOn(store, 'sub_9')).map((d) => d.key), [ADA.public]);
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
  assert.deepEqual(await whoSignedIn('google', 'local:sub-1', KEY, local), { provider: 'google', sub: 'sub-1' });
  assert.equal(await whoSignedIn('google', 'local:sub-1', KEY, signedInAs), null, 'not in production');
  assert.equal(await whoSignedIn('nobody', 'local:sub-1', KEY, local), null);
  assert.equal(await whoSignedIn('google', 'local:', KEY, local), null);
});
