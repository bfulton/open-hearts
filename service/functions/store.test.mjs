// Buying in a store (worker.mjs, "buying in a store"): an App Store
// transaction is taken only when its chain ends at the trusted root and
// Apple's marks are where Apple puts them; a Play token only when Play
// says what it is; and a purchase puts a device on its subscription by
// the household's rules. node --test service/functions
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { afterEach, test } from 'node:test';
import worker, {
  APPLE_ROOT_G3,
  appleSigned,
  appleTransaction,
  certOf,
  devicesOn,
  entitlementOf,
  forgetAppleRoots,
  forgetHouseholds,
  forgetPlayAccess,
  forgetProviderKeys,
  memoryStore,
  playPurchase,
  record,
  signedBy,
  signerOn,
  storeAccountOf,
  trustAppleRoots,
} from './worker.mjs';
import { keys } from '../do/sign.mjs';
import * as pki from './store.fixtures.mjs';

const der = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const b64url = (bytes) => Buffer.from(bytes).toString('base64url');

const BUNDLE = 'game.openhearts.app';
const PRODUCT = 'openhearts_annual';
const PACKAGE = 'game.openhearts.app';
const DAY = 86400000;

afterEach(() => {
  forgetAppleRoots();
  forgetHouseholds();
  forgetPlayAccess();
  forgetProviderKeys();
});

/// A JWS the way the App Store makes one, signed by the test leaf over
/// [chain] (leaf, intermediate, root: base64 DER).
async function appleJws(payload, { chain = [pki.leaf, pki.mid, pki.root], alg = 'ES256', key = pki.leafKey } = {}) {
  const head = b64url(Buffer.from(JSON.stringify({ alg, x5c: chain })));
  const body = b64url(Buffer.from(JSON.stringify(payload)));
  const pkcs8 = der(key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''));
  const k = await crypto.subtle.importKey('pkcs8', pkcs8, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, k, new TextEncoder().encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}

const now = Date.now();

/// A transaction as StoreKit 2 signs one.
const transaction = (more = {}) => ({
  transactionId: '2000000123456789',
  originalTransactionId: '2000000000000001',
  bundleId: BUNDLE,
  productId: PRODUCT,
  type: 'Auto-Renewable Subscription',
  purchaseDate: now - DAY,
  expiresDate: now + 364 * DAY,
  signedDate: now - 1000,
  environment: 'Production',
  ...more,
});

const appleEnv = { OH_APPLE_BUNDLE_ID: BUNDLE, OH_APPLE_PRODUCT: PRODUCT };

// ---- the chain -----------------------------------------------------------

test('the pinned root is Apple\'s own, and verifies Apple\'s own intermediate', async () => {
  const fingerprint = Buffer.from(await crypto.subtle.digest('SHA-256', APPLE_ROOT_G3)).toString('hex');
  assert.equal(fingerprint, '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179');
  const root = certOf(APPLE_ROOT_G3);
  const wwdr = certOf(der(pki.appleWwdrG6));
  assert.equal(root.curve.namedCurve, 'P-384');
  assert.equal(wwdr.ca, true);
  assert.ok(wwdr.extensions.has('1.2.840.113635.100.6.2.1'), "Apple's mark on its intermediate");
  assert.equal(await signedBy(wwdr, root), true);
  // And not by a root of the same shape that is not Apple's.
  assert.equal(await signedBy(wwdr, certOf(der(pki.root))), false);
});

test('a JWS whose chain ends at a trusted root, with Apple\'s marks, is read', async () => {
  trustAppleRoots([der(pki.root)]);
  const payload = transaction();
  assert.deepEqual(await appleSigned(await appleJws(payload), { now }), payload);
});

test('Apple\'s root alone is trusted unless a test says otherwise', async () => {
  assert.equal(await appleSigned(await appleJws(transaction()), { now }), null);
});

test('a chain that only looks like the App Store\'s is not taken', async () => {
  trustAppleRoots([der(pki.root)]);
  const t = transaction();
  const cases = {
    'an intermediate without the WWDR mark': { chain: [pki.leaf, pki.midplain, pki.root] },
    'a leaf without the App Store mark': { chain: [pki.leafplain, pki.mid, pki.root] },
    'an intermediate of the same name signed by another root': { chain: [pki.leaf, pki.midother, pki.root] },
    'a chain ending at a root nobody trusts': { chain: [pki.leaf, pki.midother, pki.other] },
    'the leaf as its own intermediate': { chain: [pki.leaf, pki.leaf, pki.root] },
    'an intermediate with the mark that is not a CA': { chain: [pki.leaf, pki.midnotca, pki.root] },
    'an intermediate with the right key under another name': { chain: [pki.leaf, pki.midrenamed, pki.root] },
    'two certificates': { chain: [pki.leaf, pki.root] },
    'another algorithm named': { alg: 'ES384' },
  };
  for (const [why, how] of Object.entries(cases)) assert.equal(await appleSigned(await appleJws(t, how), { now }), null, why);
  // Signed by a key that is not the leaf's.
  const otherKey = (await import('node:crypto')).generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.equal(await appleSigned(await appleJws(t, { key: otherKey }), { now }), null, 'not the leaf\'s signature');
  // A payload changed after it was signed.
  const [h, , s] = (await appleJws(t)).split('.');
  const forged = `${h}.${b64url(Buffer.from(JSON.stringify({ ...t, expiresDate: now + 9999 * DAY })))}.${s}`;
  assert.equal(await appleSigned(forged, { now }), null, 'a payload edited in flight');
  for (const junk of [null, '', 'a.b', 'a.b.c', 42]) assert.equal(await appleSigned(junk, { now }), null, String(junk));
});

test('a JWS is checked at the moment it says it was signed, and not one from the future', async () => {
  trustAppleRoots([der(pki.root)]);
  const leaf = certOf(der(pki.leaf));
  assert.equal(await appleSigned(await appleJws(transaction({ signedDate: leaf.notBefore - 1000 })), { now }), null, 'before the leaf was good');
  assert.equal(await appleSigned(await appleJws(transaction({ signedDate: now + 3600000 })), { now }), null, 'in the future');
  assert.notEqual(await appleSigned(await appleJws(transaction({ signedDate: leaf.notBefore + 60000 })), { now }), null, 'earlier, by a certificate good then');
});

test('a transaction is ours only for this app, this product, as a subscription', async () => {
  trustAppleRoots([der(pki.root)]);
  const t = await appleTransaction(await appleJws(transaction({ appAccountToken: 'A0D2E1EE-61D4-4116-92A5-9BBDA8AC7B99' })), appleEnv, { now });
  assert.equal(t.subscription, 'apple:2000000000000001');
  assert.equal(t.gone, false);
  assert.equal(t.account, 'a0d2e1ee-61d4-4116-92a5-9bbda8ac7b99');
  for (const more of [{ bundleId: 'com.other.app' }, { productId: 'coins_100' }, { type: 'Non-Consumable' }, { originalTransactionId: '../x' }, { expiresDate: undefined }]) {
    assert.equal((await appleTransaction(await appleJws(transaction(more)), appleEnv, { now })).status, 401, JSON.stringify(more));
  }
  assert.equal((await appleTransaction(await appleJws(transaction({ revocationDate: now })), appleEnv, { now })).gone, true);
  assert.equal((await appleTransaction('x', {}, { now })).status, 503, 'no store set up');
});

test('the store account a purchase names, pinned on both sides', async () => {
  const key = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
  assert.deepEqual(await storeAccountOf(key), {
    google: 'a0d2e1ee61d4911692a59bbda8ac7b994078d916759c7eaaf166d43072748199',
    apple: 'a0d2e1ee-61d4-4116-92a5-9bbda8ac7b99',
  });
});

// ---- the service, asked -----------------------------------------------------

const wasm = await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url));
const signer = await signerOn(wasm);
const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const [ADA, , BAO, CY] = keys;

const sha = async (text) => Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))).toString('hex');
const asking = async (pair, handler, what, more = {}) => {
  const at = Math.floor(Date.now() / 1000);
  return { key: pair.public, at, sig: signer.sign(pair.secret, await sha(`oh-request/1\n${handler}\n${pair.public}\n${at}\n${what}`)), ...more };
};

const kvOf = (store) => ({
  get: async (at, kind) => {
    const [pk, sk] = at.split('|');
    const row = await store.get(pk, sk);
    return kind === 'json' ? row : row === null ? null : JSON.stringify(row);
  },
  put: async (at, raw) => {
    const [pk, sk] = at.split('|');
    await store.put(pk, sk, JSON.parse(raw));
  },
  delete: async (at) => {
    const [pk, sk] = at.split('|');
    await store.del(pk, sk);
  },
  list: async ({ prefix }) => ({ keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }),
});

const assets = { fetch: async (url) => (String(url).endsWith('/play/schnorr.wasm') ? new Response(wasm) : new Response('asset')) };

const serving = (store, more = {}) => ({
  env: { ASSETS: assets, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kvOf(store), ...appleEnv, ...more },
  send: (what, body, headers = {}) =>
    new Request(`https://dev.open-hearts.pages.dev/api/${what}`, { method: 'POST', headers, body: typeof body === 'string' ? body : JSON.stringify(body) }),
});

const bring = async (pair, store, proof) => ({ ...(await asking(pair, 'store', proof)), store, proof });

test('the device that bought it is licensed on it; another restoring it joins the household', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  const ada = await storeAccountOf(ADA.public);
  const proof = await appleJws(transaction({ appAccountToken: ada.apple }));

  const bought = await worker.fetch(send('store', await bring(ADA, 'apple', proof)), env);
  assert.equal(bought.status, 200);
  assert.equal((await bought.json()).licence.key, ADA.public);
  const meta = await store.get('SUB#apple:2000000000000001', 'META');
  assert.equal(meta.source, 'apple');
  assert.equal(meta.renews_at, new Date(now + 364 * DAY).toISOString().slice(0, 10));

  // The same Apple account restoring it on another phone.
  const restored = await worker.fetch(send('store', await bring(BAO, 'apple', proof)), env);
  assert.equal(restored.status, 200);
  const account = (await store.get('SUB#apple:2000000000000001', 'ACCOUNT')).account;
  assert.deepEqual((await devicesOn(store, account)).map((d) => d.key).sort(), [ADA.public, BAO.public].sort());
  assert.equal((await entitlementOf(store, BAO.public, { now })).account, account, 'one account, two devices');
});

test('the proof is what is signed, and a proof Apple did not sign is refused', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  const proof = await appleJws(transaction());
  // Signed over another proof: this one was not what the device asked with.
  const swapped = { ...(await asking(ADA, 'store', 'something else')), store: 'apple', proof };
  assert.equal((await worker.fetch(send('store', swapped), env)).status, 401);
  forgetAppleRoots();
  assert.deepEqual(
    await (await worker.fetch(send('store', await bring(ADA, 'apple', proof)), env)).json(),
    { error: 'not from the store' },
  );
  assert.equal((await worker.fetch(send('store', await bring(ADA, 'amazon', proof)), env)).status, 400);
  assert.equal((await worker.fetch(send('store', await bring(ADA, 'apple', '')), env)).status, 400);
  assert.equal((await worker.fetch(send('store', await bring(ADA, 'apple', proof)), { ...env, OH_APPLE_PRODUCT: undefined })).status, 503);
});

test('a lapsed or refunded purchase licenses nobody, and is written down as such', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  const lapsed = await appleJws(transaction({ expiresDate: now - DAY }));
  const said = await worker.fetch(send('store', await bring(ADA, 'apple', lapsed)), env);
  assert.equal(said.status, 402);
  assert.deepEqual(await said.json(), { error: 'not paid' });
  assert.equal(await entitlementOf(store, ADA.public, { now }), null);
  const refunded = await appleJws(transaction({ originalTransactionId: '2000000000000002', revocationDate: now - 1000 }));
  assert.equal((await worker.fetch(send('store', await bring(ADA, 'apple', refunded)), env)).status, 402);
  assert.equal((await store.get('SUB#apple:2000000000000002', 'META')).renews_at, new Date(now).toISOString().slice(0, 10));
});

test('the buyer moves onto what it paid for; anyone else does not leave a paid-up subscription for it', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  // Both on a web subscription that is paid up.
  for (const pair of [ADA, BAO]) {
    await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: pair.public } } } }, store, { now });
  }
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((now + 200 * DAY) / 1000) } } }, store, { now });
  const { env, send } = serving(store);
  const proof = await appleJws(transaction({ appAccountToken: (await storeAccountOf(ADA.public)).apple }));
  assert.equal((await worker.fetch(send('store', await bring(BAO, 'apple', proof)), env)).status, 409, 'not the buyer');
  assert.equal((await worker.fetch(send('store', await bring(ADA, 'apple', proof)), env)).status, 200, 'the buyer');
  const web = (await store.get('SUB#sub_9', 'ACCOUNT')).account;
  const apple = (await store.get('SUB#apple:2000000000000001', 'ACCOUNT')).account;
  assert.notEqual(web, apple, 'an account with a subscription paid up keeps it; the new one is an account of its own');
  assert.deepEqual((await devicesOn(store, web)).map((d) => d.key), [BAO.public]);
  assert.equal((await entitlementOf(store, ADA.public, { now })).account, apple);
});

test('a store subscription carries no more devices than any other', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  const proof = await appleJws(transaction());
  const pairs = [...keys.filter((k) => k.public !== SERVICE_KEY)];
  const answers = [];
  for (const pair of pairs.slice(0, 6)) answers.push((await worker.fetch(send('store', await bring(pair, 'apple', proof)), env)).status);
  assert.deepEqual(answers, [200, 200, 200, 200, 200, 409].slice(0, answers.length));
});

// ---- Apple's notifications -------------------------------------------------

const notification = async (type, t, { subtype, signedDate = now, renewal = null, bundleId = BUNDLE } = {}) => ({
  signedPayload: await appleJws({
    notificationType: type,
    ...(subtype ? { subtype } : {}),
    notificationUUID: crypto.randomUUID(),
    signedDate,
    data: {
      bundleId,
      environment: 'Production',
      signedTransactionInfo: await appleJws(t),
      ...(renewal ? { signedRenewalInfo: await appleJws(renewal) } : {}),
    },
  }),
});

test('Apple\'s notifications renew, end and come back; an old one changes nothing', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  const proof = await appleJws(transaction());
  await worker.fetch(send('store', await bring(ADA, 'apple', proof)), env);
  const day = (ms) => new Date(ms).toISOString().slice(0, 10);

  const renewed = transaction({ transactionId: '2000000123456790', expiresDate: now + 729 * DAY, signedDate: now + 1000 });
  assert.equal((await worker.fetch(send('apple', await notification('DID_RENEW', renewed, { signedDate: now + 1000 })), env)).status, 200);
  assert.equal((await store.get('SUB#apple:2000000000000001', 'META')).renews_at, day(now + 729 * DAY));

  // Refunded: over today, and the device's own copy with it.
  const refunded = transaction({ revocationDate: now + 2000, signedDate: now + 2000 });
  await worker.fetch(send('apple', await notification('REFUND', refunded, { signedDate: now + 2000 })), env);
  assert.equal((await store.get('SUB#apple:2000000000000001', 'META')).renews_at, day(now));
  assert.equal((await store.get(`KEY#${ADA.public}`, 'ENTITLEMENT')).licensed_until, day(now));

  // The renewal again, delivered late: not news.
  await worker.fetch(send('apple', await notification('DID_RENEW', renewed, { signedDate: now + 1000 })), env);
  assert.equal((await store.get('SUB#apple:2000000000000001', 'META')).renews_at, day(now));

  // Bought again later: the same original transaction, paid up again.
  const again = transaction({ transactionId: '2000000123456799', expiresDate: now + 400 * DAY, signedDate: now + 3000 });
  await worker.fetch(send('apple', await notification('SUBSCRIBED', again, { subtype: 'RESUBSCRIBE', signedDate: now + 3000 })), env);
  assert.equal((await store.get('SUB#apple:2000000000000001', 'META')).renews_at, day(now + 400 * DAY));
});

test('a notification that says it has ended ends it, whatever date the transaction carries', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  for (const type of ['EXPIRED', 'GRACE_PERIOD_EXPIRED', 'REVOKE']) {
    const t = transaction({ originalTransactionId: String(2000000000000100 + type.length), expiresDate: now + DAY });
    await worker.fetch(send('apple', await notification(type, t)), env);
    assert.equal((await store.get(`SUB#apple:${t.originalTransactionId}`, 'META')).renews_at, new Date(now).toISOString().slice(0, 10), type);
  }
});

test('a renewal that failed is paid for to the end of its grace period', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  const t = transaction({ expiresDate: now - 1000 });
  const renewal = { originalTransactionId: t.originalTransactionId, gracePeriodExpiresDate: now + 6 * DAY, signedDate: now };
  await worker.fetch(send('apple', await notification('DID_FAIL_TO_RENEW', t, { subtype: 'GRACE_PERIOD', renewal })), env);
  assert.equal((await store.get('SUB#apple:2000000000000001', 'META')).renews_at, new Date(now + 6 * DAY).toISOString().slice(0, 10));
});

test('a notification Apple did not sign is refused; one for another app is read and left', async () => {
  trustAppleRoots([der(pki.root)]);
  const store = memoryStore();
  const { env, send } = serving(store);
  const forged = await notification('DID_RENEW', transaction(), {});
  forgetAppleRoots();
  assert.equal((await worker.fetch(send('apple', forged), env)).status, 400);
  trustAppleRoots([der(pki.root)]);
  const elsewhere = await worker.fetch(send('apple', await notification('DID_RENEW', transaction(), { bundleId: 'com.other.app' })), env);
  assert.deepEqual([elsewhere.status, await elsewhere.json()], [200, { recorded: null }]);
  assert.equal(await store.get('SUB#apple:2000000000000001', 'META'), null);
  assert.equal((await worker.fetch(send('apple', 'not json'), env)).status, 400);
});

// ---- Google Play -------------------------------------------------------------

const rsa = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
);
const pkcs8Pem = async (key) =>
  `-----BEGIN PRIVATE KEY-----\n${Buffer.from(await crypto.subtle.exportKey('pkcs8', key)).toString('base64')}\n-----END PRIVATE KEY-----\n`;
const SERVICE_ACCOUNT = JSON.stringify({ client_email: 'play@open-hearts.iam.gserviceaccount.com', private_key: await pkcs8Pem(rsa.privateKey) });
const playEnv = { OH_PLAY_PACKAGE: PACKAGE, OH_PLAY_PRODUCT: PRODUCT, OH_PLAY_SERVICE_ACCOUNT: SERVICE_ACCOUNT };

/// Google, as far as Play needs it: the token endpoint (which checks
/// the assertion was signed by the service account), the purchase as
/// [purchases] says it is, and acknowledgements, counted.
function google(purchases, { jwks = null } = {}) {
  const calls = [];
  const f = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    url = String(url);
    if (url === 'https://oauth2.googleapis.com/token') {
      const assertion = new URLSearchParams(init.body).get('assertion');
      const [h, c, s] = assertion.split('.');
      const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', rsa.publicKey, Buffer.from(s, 'base64url'), new TextEncoder().encode(`${h}.${c}`));
      const claims = JSON.parse(Buffer.from(c, 'base64url'));
      if (!ok || claims.scope !== 'https://www.googleapis.com/auth/androidpublisher' || claims.iss !== 'play@open-hearts.iam.gserviceaccount.com') {
        return new Response('no', { status: 401 });
      }
      return Response.json({ access_token: 'ya29.test', expires_in: 3599 });
    }
    if (url === 'https://www.googleapis.com/oauth2/v3/certs') return Response.json({ keys: jwks ? [jwks] : [] });
    const got = url.match(/subscriptionsv2\/tokens\/([^/]+)$/);
    if (got) {
      if (init.headers?.authorization !== 'Bearer ya29.test') return new Response('no', { status: 401 });
      const p = purchases[decodeURIComponent(got[1])];
      return p ? Response.json(p) : new Response('{}', { status: 404 });
    }
    if (url.endsWith(':acknowledge')) return new Response('{}');
    return new Response('?', { status: 500 });
  };
  f.calls = calls;
  return f;
}

const playing = (more = {}) => ({
  subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
  acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
  latestOrderId: 'GPA.1234-5678',
  lineItems: [{ productId: PRODUCT, expiryTime: new Date(now + 365 * DAY).toISOString() }],
  ...more,
});

const TOKEN = 'opaque-token-from-play.AO-J1Ox';

test('a Play token is asked of Play with the service account, and acknowledged once', async () => {
  const f = google({ [TOKEN]: playing({ externalAccountIdentifiers: { obfuscatedExternalAccountId: 'abc' } }) });
  const p = await playPurchase(TOKEN, playEnv, f, { now });
  assert.equal(p.paid, true);
  assert.equal(p.gone, false);
  assert.equal(p.account, 'abc');
  assert.match(p.subscription, /^google:[0-9a-f]{64}$/);
  assert.equal(p.subscription.includes(TOKEN), false, 'the token itself is kept by no row');
  assert.equal(f.calls.filter((c) => c.url.endsWith(`/purchases/subscriptions/${PRODUCT}/tokens/${encodeURIComponent(TOKEN)}:acknowledge`)).length, 1);
  // Acknowledged already: not again. And the access token is reused.
  const g = google({ [TOKEN]: playing({ acknowledgementState: 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED' }) });
  await playPurchase(TOKEN, playEnv, g, { now });
  assert.equal(g.calls.some((c) => c.url.endsWith(':acknowledge')), false);
  assert.equal(g.calls.some((c) => c.url.includes('oauth2.googleapis.com/token')), false, 'kept from the first ask');
});

test('a Play token is ours only for this product, and paid only while Play says so', async () => {
  const states = {
    SUBSCRIPTION_STATE_ACTIVE: true,
    SUBSCRIPTION_STATE_IN_GRACE_PERIOD: true,
    SUBSCRIPTION_STATE_CANCELED: true,
    SUBSCRIPTION_STATE_ON_HOLD: false,
    SUBSCRIPTION_STATE_PAUSED: false,
    SUBSCRIPTION_STATE_PENDING: false,
    SUBSCRIPTION_STATE_EXPIRED: false,
  };
  for (const [state, paid] of Object.entries(states)) {
    forgetPlayAccess();
    const p = await playPurchase(TOKEN, playEnv, google({ [TOKEN]: playing({ subscriptionState: state }) }), { now });
    assert.equal(p.paid, paid, state);
  }
  forgetPlayAccess();
  const other = await playPurchase(TOKEN, playEnv, google({ [TOKEN]: playing({ lineItems: [{ productId: 'coins', expiryTime: '2030-01-01T00:00:00Z' }] }) }), { now });
  assert.equal(other.status, 401);
  assert.equal((await playPurchase('never-made-by-play-x', playEnv, google({}), { now })).status, 401);
  assert.equal((await playPurchase(TOKEN, {}, google({}), { now })).status, 503);
  assert.equal((await playPurchase(TOKEN, playEnv, async () => { throw new Error('down'); }, { now })).status, 502);
});

test('a Play purchase brought by its buyer licenses it', async () => {
  const store = memoryStore();
  const { env, send } = serving(store, playEnv);
  const realFetch = globalThis.fetch;
  globalThis.fetch = google({ [TOKEN]: playing({ externalAccountIdentifiers: { obfuscatedExternalAccountId: (await storeAccountOf(ADA.public)).google } }) });
  try {
    const out = await worker.fetch(send('store', await bring(ADA, 'google', TOKEN)), env);
    assert.equal(out.status, 200);
    assert.equal((await out.json()).licence.key, ADA.public);
  } finally {
    globalThis.fetch = realFetch;
  }
});

/// A Google ID token as Pub/Sub's push carries one, signed by [key].
async function pushToken(claims, key = rsa.privateKey) {
  const h = b64url(Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'push-1', typ: 'JWT' })));
  const c = b64url(Buffer.from(JSON.stringify(claims)));
  const s = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${h}.${c}`)));
  return `${h}.${c}.${b64url(s)}`;
}

test('Play\'s notifications, pushed by Pub/Sub: checked, then Play asked what the purchase is now', async () => {
  const store = memoryStore();
  const push = { OH_PLAY_PUSH_AUDIENCE: 'https://dev.open-hearts.pages.dev/api/play', OH_PLAY_PUSH_EMAIL: 'pubsub@open-hearts.iam.gserviceaccount.com' };
  const { env, send } = serving(store, { ...playEnv, ...push });
  const jwk = { ...(await crypto.subtle.exportKey('jwk', rsa.publicKey)), kid: 'push-1', alg: 'RS256', use: 'sig' };
  const claims = { iss: 'https://accounts.google.com', aud: push.OH_PLAY_PUSH_AUDIENCE, email: push.OH_PLAY_PUSH_EMAIL, email_verified: true, exp: Math.floor(now / 1000) + 600 };
  const pushed = (note) => ({ message: { data: Buffer.from(JSON.stringify({ packageName: PACKAGE, eventTimeMillis: String(now), ...note })).toString('base64'), messageId: '1' } });
  const realFetch = globalThis.fetch;
  globalThis.fetch = google({ [TOKEN]: playing({ subscriptionState: 'SUBSCRIPTION_STATE_ON_HOLD' }) }, { jwks: jwk });
  try {
    const note = pushed({ subscriptionNotification: { notificationType: 5, purchaseToken: TOKEN } });
    const auth = (t) => ({ authorization: `Bearer ${t}` });
    assert.equal((await worker.fetch(send('play', note), env)).status, 401, 'no token');
    for (const bad of [{ aud: 'https://elsewhere.example/' }, { email: 'someone@else.example' }, { email_verified: false }, { exp: Math.floor(now / 1000) - 1 }, { iss: 'https://evil.example' }]) {
      assert.equal((await worker.fetch(send('play', note, auth(await pushToken({ ...claims, ...bad }))), env)).status, 401, JSON.stringify(bad));
    }
    const ok = await worker.fetch(send('play', note, auth(await pushToken(claims))), env);
    assert.equal(ok.status, 200);
    const { recorded } = await ok.json();
    assert.equal(recorded.renews_at, new Date(now).toISOString().slice(0, 10), 'on hold is not paid for now');
    // Refunded: voided, and nothing more is asked.
    const voided = pushed({ voidedPurchaseNotification: { purchaseToken: TOKEN, refundType: 1 }, eventTimeMillis: String(now + 1000) });
    assert.equal((await worker.fetch(send('play', voided, auth(await pushToken(claims))), env)).status, 200);
    // Another app's: read and left.
    const theirs = { message: { data: Buffer.from(JSON.stringify({ packageName: 'com.other' })).toString('base64') } };
    assert.deepEqual(await (await worker.fetch(send('play', theirs, auth(await pushToken(claims))), env)).json(), { recorded: null });
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('a token that replaced another is the subscription it replaced', async () => {
  const store = memoryStore();
  const first = await playPurchase(TOKEN, playEnv, google({ [TOKEN]: playing() }), { now, store });
  await store.put(`SUB#${first.subscription}`, 'META', { source: 'google', renews_at: '2027-01-01' });
  forgetPlayAccess();
  const next = await playPurchase('a-later-token-from-play', playEnv, google({ 'a-later-token-from-play': playing({ linkedPurchaseToken: TOKEN }) }), { now, store });
  assert.equal(next.subscription, first.subscription);
});
