// Sign in with Apple's server-to-server notifications (docs/06-service.md):
// a person who stops using Sign in with Apple with the app, or deletes
// their Apple Account, has the sign-in unlinked from their account, and
// nothing else of it is touched; the notices about email forwarding are
// read and change nothing; anything that is not Apple's is a 400.
// node --test service/functions
import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import { readFile } from 'node:fs/promises';
import worker, {
  appleIdNotice,
  claimWith,
  dropDevice,
  forgetHouseholds,
  forgetProviderKeys,
  forgetSettings,
  householdOp,
  inHousehold,
  loginRow,
  memoryStore,
  record,
  signerOn,
  storeOf,
  ticketFor,
  unlinkSignIn,
  useSettings,
} from './worker.mjs';
import { ALERTS_OBJECT } from './alerts.mjs';
import { configEnv } from './deployment.mjs';
import { keys } from '../do/sign.mjs';

const wasm = await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url));
const signer = await signerOn(wasm);
const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const [ADA, , BAO, CY] = keys;

/// Our audiences as the deployment has them, from the committed
/// configuration: the Services ID (the web) and the bundle id (the
/// phone, and the primary App ID that Apple's notices name).
const { OH_APPLE_AUDIENCE } = configEnv(JSON.parse(await readFile(new URL('../../config/openhearts.json', import.meta.url), 'utf8')));
const BUNDLE = 'game.openhearts';
const ISS = 'https://appleid.apple.com';

/// The person's subject at Apple, as Apple's own page shows one.
const SUB = '820417.faa325acbc78e1be1668ba852d492d8a.0219';

const sha = async (text) =>
  [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))].map((b) => b.toString(16).padStart(2, '0')).join('');

const b64 = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const part = (o) => b64(new TextEncoder().encode(JSON.stringify(o)));

/// An Apple of this test's own: a key pair, the key set it publishes at
/// Apple's address, and tokens it signs. Nothing here is Apple's but the
/// shapes.
async function issuer(kid = 'apple-test') {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const jwk = { ...(await crypto.subtle.exportKey('jwk', pair.publicKey)), kid, alg: 'RS256', use: 'sig' };
  delete jwk.key_ops;
  delete jwk.ext;
  return {
    jwk,
    async sign(claims) {
      const head = part({ alg: 'RS256', kid });
      const body = part(claims);
      const sig = new Uint8Array(await crypto.subtle.sign({ name: 'RSASSA-PKCS1-v1_5' }, pair.privateKey, new TextEncoder().encode(`${head}.${body}`)));
      return `${head}.${body}.${b64(sig)}`;
    },
  };
}

const apple = await issuer();

/// What answers at Apple's key set: [published], and nothing else is
/// asked of anybody.
const publishing = (published) => async (url) =>
  String(url) === 'https://appleid.apple.com/auth/keys' ? Response.json({ keys: published }) : new Response('not here', { status: 404 });

/// A sign-in's ID token, minted for the device with [key], as Apple
/// hands one to the app on an iPhone.
const idToken = async (key, sub = SUB) => {
  const at = Math.floor(Date.now() / 1000);
  return apple.sign({ iss: ISS, aud: BUNDLE, iat: at, exp: at + 600, sub, nonce: await sha(`oh-signin/1\n${key}`) });
};

/// A notification as Apple sends one: the events claim a JSON string,
/// or, with [asObject], the object Apple's page shows; [claims] laid
/// over the rest (undefined leaves one out).
async function notice(type, { sub = SUB, asObject = false, by = apple, ...claims } = {}) {
  const at = Math.floor(Date.now() / 1000);
  const events = {
    type,
    sub,
    event_time: Date.now(),
    ...(type.startsWith('email-') ? { email: 'ep9ks2tnph@privaterelay.appleid.com', is_private_email: 'true' } : {}),
  };
  return by.sign({ iss: ISS, aud: BUNDLE, iat: at, exp: at + 86400, jti: crypto.randomUUID(), events: asObject ? events : JSON.stringify(events), ...claims });
}

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

const assets = {
  fetch: async (url) => (String(url).endsWith('/play/schnorr.wasm') ? new Response(wasm, { status: 200 }) : new Response('asset', { status: 200 })),
};

const realFetch = globalThis.fetch;
beforeEach(() => {
  forgetProviderKeys();
  forgetHouseholds();
  globalThis.fetch = publishing([apple.jwk]);
});
afterEach(() => {
  globalThis.fetch = realFetch;
  forgetProviderKeys();
  forgetSettings();
});

/// Ada subscribed, paid up a year, Bao brought in by a code, and Ada's
/// Apple sign-in linked to the account through `attest`, as the app
/// does it. Cy is nobody's.
async function linked() {
  const now = Date.now();
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: ADA.public } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((now + 365 * 86400000) / 1000) } } }, store, { now });
  await claimWith(BAO.public, (await ticketFor(ADA.public, store, { now })).body.ticket, store, { now });
  const account = (await store.get(`KEY#${ADA.public}`, 'ENTITLEMENT')).account;
  const env = {
    ASSETS: assets,
    OH_SERVICE_SECRET: SERVICE_SECRET,
    OH_SERVICE_KEY: SERVICE_KEY,
    OH_STORE: kvOf(store),
    OH_ID_HMAC: 'pepper',
    OH_APPLE_AUDIENCE,
  };
  const ask = async (pair, handler, more = {}) => {
    const at = Math.floor(Date.now() / 1000);
    const sig = signer.sign(pair.secret, await sha(`oh-request/1\n${handler}\n${pair.public}\n${at}\n`));
    const res = await worker.fetch(
      new Request(`https://play.openhearts.game/api/${handler}`, { method: 'POST', body: JSON.stringify({ key: pair.public, at, sig, ...more }) }),
      env,
    );
    return { status: res.status, body: await res.json() };
  };
  const signIn = async (pair, handler, sub = SUB) => ask(pair, handler, { provider: 'apple', token: await idToken(pair.public, sub) });
  const attested = await signIn(ADA, 'attest');
  assert.equal(attested.status, 200, 'linked, as the app links it');
  const login = await loginRow({ provider: 'apple', sub: SUB }, env);
  return { store, env, account, ask, signIn, login };
}

/// [payload] posted to the handler, as Apple posts it; [body] in its
/// place sends that text instead.
async function tell(env, payload, { host = 'play.openhearts.game', body = JSON.stringify({ payload }), method = 'POST' } = {}) {
  const res = await worker.fetch(
    new Request(`https://${host}/api/apple-id`, { method, headers: { 'content-type': 'application/json' }, ...(method === 'GET' ? {} : { body }) }),
    env,
  );
  return { status: res.status, body: await res.json() };
}

test('the audiences are the committed ones: the primary App ID among them', () => {
  assert.deepEqual(OH_APPLE_AUDIENCE.split(','), ['game.openhearts.play', BUNDLE]);
});

for (const type of ['account-deleted', 'account-delete', 'consent-revoked']) {
  test(`${type}: the Apple sign-in is unlinked, and brings no device in after`, async () => {
    const { store, env, account, signIn, login } = await linked();
    assert.equal((await signIn(CY, 'supersede')).status, 200, 'before: the sign-in brings a device in');
    await dropDevice(ADA.public, CY.public, store);

    assert.deepEqual(await tell(env, await notice(type)), { status: 200, body: { unlinked: true } });
    assert.equal(await store.get(login, 'IDENTITY'), null);
    assert.equal(await store.get(`ACCOUNT#${account}`, 'LOGIN'), null);

    const after = await signIn(CY, 'supersede');
    assert.deepEqual([after.status, after.body.error], [404, 'that sign-in is not linked to an account']);
    assert.equal(await store.get(`KEY#${CY.public}`, 'ENTITLEMENT'), null, 'Cy is still nobody\'s');
  });
}

test('nothing else of the account is touched: its devices, its subscription, its licences', async () => {
  const { store, env, account, ask } = await linked();
  const before = [...store.rows.entries()].filter(([k]) => !k.includes('LOGIN')).map(([k, v]) => [k, JSON.stringify(v)]);
  await tell(env, await notice('account-deleted'));
  const after = [...store.rows.entries()].map(([k, v]) => [k, JSON.stringify(v)]);
  assert.deepEqual(after, before, 'only the sign-in\'s two rows are gone');
  assert.ok(await store.get(`ACCOUNT#${account}`, `DEVICE#${BAO.public}`));
  assert.ok(await store.get('SUB#sub_9', 'META'));
  for (const pair of [ADA, BAO]) {
    const licensed = await ask(pair, 'licence');
    assert.equal(licensed.status, 200, 'a device of the account is licensed as before');
    assert.equal(licensed.body.licence.account, account);
  }
});

test("the account's devices are told which sign-in it is linked to: Apple's, and then none", async () => {
  const { env, ask } = await linked();
  // Bao never signed in itself: it learns of Ada's link from the account.
  const before = await ask(BAO, 'devices');
  assert.deepEqual([before.status, before.body.signIn], [200, 'apple']);
  await tell(env, await notice('consent-revoked'));
  const after = await ask(BAO, 'devices');
  assert.deepEqual([after.status, after.body.signIn], [200, null]);
  assert.equal(after.body.devices.length, 2, 'the devices are as they were');
});

test('the account can be linked again: to the same Apple sign-in, or to another', async () => {
  const { store, env, account, signIn, login } = await linked();
  await tell(env, await notice('consent-revoked'));
  // The person signs in with Apple again, and it links as it did.
  const again = await signIn(BAO, 'attest');
  assert.deepEqual([again.status, again.body.account], [200, account]);
  assert.equal((await store.get(login, 'IDENTITY')).account, account);
  // Linked, another sign-in is turned away as a second one; gone again,
  // it is not.
  const turned = await signIn(BAO, 'attest', '000111.another.0001');
  assert.deepEqual([turned.status, turned.body.error], [409, 'this account is linked to another sign-in']);
  await tell(env, await notice('consent-revoked'));
  const other = await signIn(BAO, 'attest', '000111.another.0001');
  assert.equal(other.status, 200);
});

test('events: the JSON string Apple sends and the object its page shows are read alike', async () => {
  for (const asObject of [false, true]) {
    const { store, env, login } = await linked();
    assert.deepEqual(await tell(env, await notice('account-deleted', { asObject })), { status: 200, body: { unlinked: true } }, `as an object: ${asObject}`);
    assert.equal(await store.get(login, 'IDENTITY'), null);
  }
});

test('email-enabled and email-disabled are taken and change nothing: we hold no email from Apple', async () => {
  const { store, env, login } = await linked();
  const rows = JSON.stringify([...store.rows.entries()]);
  for (const type of ['email-enabled', 'email-disabled', 'something-new']) {
    assert.deepEqual(await tell(env, await notice(type)), { status: 200, body: { unlinked: null } }, type);
  }
  assert.equal(JSON.stringify([...store.rows.entries()]), rows);
  assert.ok(await store.get(login, 'IDENTITY'));
});

test('unlinking twice is nothing the second time, and a notice sent again is the same notice', async () => {
  const { env } = await linked();
  const once = await notice('account-deleted');
  assert.deepEqual(await tell(env, once), { status: 200, body: { unlinked: true } });
  assert.deepEqual(await tell(env, once), { status: 200, body: { unlinked: false } }, 'the very same token, replayed');
  assert.deepEqual(await tell(env, await notice('consent-revoked')), { status: 200, body: { unlinked: false } });
  // And somebody who never linked a sign-in here.
  assert.deepEqual(await tell(env, await notice('account-deleted', { sub: '999999.never.here' })), { status: 200, body: { unlinked: false } });
});

test("anything not Apple's, not for us or not current is a 400, and unlinks nothing", async () => {
  const { store, env, login } = await linked();
  const at = Math.floor(Date.now() / 1000);
  const impostor = await issuer('apple-test');
  const cases = {
    'another issuer': await notice('account-deleted', { iss: 'https://evil.example' }),
    "another app's audience": await notice('account-deleted', { aud: 'com.someone.else' }),
    'run out': await notice('account-deleted', { iat: at - 2 * 86400, exp: at - 60 }),
    'no expiry, and made over a day ago': await notice('account-deleted', { iat: at - 86400 - 60, exp: undefined }),
    'no date at all': await notice('account-deleted', { iat: undefined, exp: undefined }),
    'signed by somebody else with the same key id': await notice('account-deleted', { by: impostor }),
    'a sign-in\'s ID token, which has no events': await idToken(ADA.public),
    'events that do not read': await notice('account-deleted', { events: '{"type":' }),
    'events with no subject': await notice('account-deleted', { events: JSON.stringify({ type: 'account-deleted' }) }),
    'not a token': 'not.a.token',
    'nothing': undefined,
  };
  for (const [why, payload] of Object.entries(cases)) {
    forgetProviderKeys();
    assert.deepEqual(await tell(env, payload), { status: 400, body: { error: 'not signed' } }, why);
  }
  // A token whose signature has been changed by a bit.
  const good = await notice('account-deleted');
  const [h, b, s] = good.split('.');
  const flipped = `${h}.${b}.${s[0] === 'A' ? 'B' : 'A'}${s.slice(1)}`;
  assert.equal((await tell(env, flipped)).status, 400, 'a bad signature');
  // Claims of somebody else's choosing under Apple's signature.
  const forged = `${h}.${part({ iss: ISS, aud: BUNDLE, iat: at, exp: at + 86400, events: JSON.stringify({ type: 'account-deleted', sub: '000000.other.0000' }) })}.${s}`;
  assert.equal((await tell(env, forged)).status, 400, 'claims the signature is not over');
  // Algorithm none.
  assert.equal((await tell(env, `${part({ alg: 'none', kid: 'apple-test' })}.${b}.`)).status, 400, 'alg none');
  // Not JSON, or JSON without a payload.
  assert.equal((await tell(env, null, { body: 'payload=x' })).status, 400);
  assert.equal((await tell(env, null, { body: 'null' })).status, 400);
  assert.ok(await store.get(login, 'IDENTITY'), 'still linked after all of them');
});

test('a notice with no expiry is good for a day from when it was made', async () => {
  const { store, env, login } = await linked();
  const at = Math.floor(Date.now() / 1000);
  assert.deepEqual(await tell(env, await notice('account-deleted', { iat: at - 3600, exp: undefined })), { status: 200, body: { unlinked: true } });
  assert.equal(await store.get(login, 'IDENTITY'), null);
});

test('appleIdNotice: what a notice says, read with the keys handed in', async () => {
  globalThis.fetch = async () => {
    throw new Error('the keys come from the fetch handed in');
  };
  const env = { OH_APPLE_AUDIENCE };
  const said = await appleIdNotice(await notice('consent-revoked'), env, publishing([apple.jwk]));
  assert.deepEqual(said, { type: 'consent-revoked', sub: SUB });
  // The Services ID is ours too, and any one of an array of audiences.
  forgetProviderKeys();
  assert.deepEqual(await appleIdNotice(await notice('consent-revoked', { aud: ['x', 'game.openhearts.play'] }), env, publishing([apple.jwk])), said);
  // Nothing without our audiences to check it against.
  forgetProviderKeys();
  assert.equal(await appleIdNotice(await notice('consent-revoked'), {}, publishing([apple.jwk])), null);
  // Nor when Apple's keys cannot be had.
  forgetProviderKeys();
  assert.equal(await appleIdNotice(await notice('consent-revoked'), env, async () => new Response('down', { status: 503 })), null);
});

test('the handler is on the app\'s host and a preview\'s, and not the site\'s', async () => {
  const { env } = await linked();
  const there = await tell(env, await notice('email-enabled'));
  assert.equal(there.status, 200);
  const preview = await tell(env, await notice('email-enabled'), { host: 'dev.open-hearts.pages.dev' });
  assert.equal(preview.status, 200);
  const site = await tell(env, await notice('account-deleted'), { host: 'openhearts.game' });
  assert.deepEqual(site, { status: 404, body: { error: 'the service has moved to play.openhearts.game' } });
  assert.equal((await tell(env, null, { method: 'GET' })).status, 405);
});

test('a body past a token\'s size is not read; unconfigured, it says so', async () => {
  const { env } = await linked();
  assert.equal((await tell(env, null, { body: JSON.stringify({ payload: 'x'.repeat(17 * 1024) }) })).status, 413);
  const payload = await notice('account-deleted');
  const { OH_APPLE_AUDIENCE: _, ...noAudience } = env;
  assert.deepEqual(await tell(noAudience, payload), { status: 503, body: { error: 'sign-in is not set up yet' } });
  const { OH_ID_HMAC: __, ...noSecret } = env;
  assert.deepEqual(await tell(noSecret, payload), { status: 503, body: { error: 'service not configured: OH_ID_HMAC' } });
  const { OH_STORE: ___, ...noStore } = env;
  assert.equal((await tell(noStore, payload)).status, 503);
});

/// A HOUSEHOLD binding of the test's own: each object asked of is named
/// in [asked] with what it was asked, and does it as the real one would.
const turnsOf = (env, asked) => ({
  idFromName: (name) => name,
  get: (name) => ({
    fetch: async (_, init) => {
      const op = JSON.parse(init.body);
      asked.push({ name, op });
      return Response.json(await householdOp(op, storeOf(env)));
    },
  }),
});

test("the unlink runs in the account's turn, where linking does", async () => {
  const { env, account, login } = await linked();
  const asked = [];
  assert.deepEqual(await tell({ ...env, HOUSEHOLD: turnsOf(env, asked) }, await notice('account-deleted')), { status: 200, body: { unlinked: true } });
  assert.deepEqual(asked, [{ name: account, op: { op: 'unlink', account, login } }]);
});

test('it is counted under its own name, and the operator is not mailed', async () => {
  const { env } = await linked();
  const lines = [];
  const asked = [];
  const watched = {
    ...env,
    HOUSEHOLD: turnsOf(env, asked),
    OH_METRICS: { writeDataPoint: (line) => lines.push(line) },
    OH_ALERTS_TO: 'alerts@openhearts.game',
    OH_ALERT_SUBSCRIBED: 'on',
    OH_ALERT_WAITING: 'on',
  };
  await tell(watched, await notice('account-deleted'));
  await tell(watched, await notice('email-disabled'));
  assert.deepEqual(lines.map((l) => l.blobs), [['apple-id', '200'], ['apple-id', '200']]);
  assert.equal(asked.some((a) => a.name === ALERTS_OBJECT), false);
});

test('an account over its hour of changes is still unlinked: Apple\'s word has an allowance of its own', async () => {
  const { env, account, store, login } = await linked();
  useSettings({ householdChangesPerHour: 5 });
  let refused = null;
  for (let i = 0; i < 10 && !refused; i++) {
    const answer = await inHousehold(env, account, { op: 'ticket', key: ADA.public });
    if (answer.status === 429) refused = answer;
  }
  assert.ok(refused, 'the person\'s own changes are spent');
  assert.deepEqual(await tell(env, await notice('consent-revoked')), { status: 200, body: { unlinked: true } });
  assert.equal(await store.get(login, 'IDENTITY'), null);
});

test('a turn that cannot do it says so, so that a notice sent again finds it done then', async () => {
  const { env, store, login } = await linked();
  // A Household object deployed before it knew the question.
  const old = { idFromName: (n) => n, get: () => ({ fetch: async () => Response.json({ status: 400, body: { error: 'not a household operation' } }) }) };
  assert.deepEqual(await tell({ ...env, HOUSEHOLD: old }, await notice('account-deleted')), { status: 503, body: { error: 'not unlinked yet' } });
  assert.ok(await store.get(login, 'IDENTITY'), 'still linked, to be unlinked when it comes again');
  assert.deepEqual(await tell(env, await notice('account-deleted')), { status: 200, body: { unlinked: true } });
});

test('a link from before accounts, to a device, is unlinked too', async () => {
  const { store, env } = await linked();
  const old = await loginRow({ provider: 'apple', sub: '001234.before.0001' }, env);
  await store.put(old, 'IDENTITY', { key: BAO.public, created_at: '2026-01-01' });
  assert.deepEqual(await tell(env, await notice('consent-revoked', { sub: '001234.before.0001' })), { status: 200, body: { unlinked: true } });
  assert.equal(await store.get(old, 'IDENTITY'), null);
  // And one whose device is in no account any more: there is no turn to
  // run it in, and the row goes all the same.
  await store.put(old, 'IDENTITY', { key: CY.public, created_at: '2026-01-01' });
  assert.deepEqual(await tell(env, await notice('consent-revoked', { sub: '001234.before.0001' })), { status: 200, body: { unlinked: true } });
  assert.equal(await store.get(old, 'IDENTITY'), null);
});

test('unlinkSignIn: the identity\'s row and the account\'s note of it, and only a sign-in\'s rows', async () => {
  const store = memoryStore();
  const account = 'a1'.repeat(16);
  const login = `LOGIN#apple#${'c'.repeat(64)}`;
  await store.put(login, 'IDENTITY', { account, created_at: '2026-10-01' });
  await store.put(`ACCOUNT#${account}`, 'LOGIN', { provider: 'apple', login, at: '2026-10-01' });
  assert.deepEqual(await unlinkSignIn(account, login, store), { status: 200, body: { unlinked: true } });
  assert.deepEqual([...store.rows.keys()], []);
  assert.deepEqual(await unlinkSignIn(account, login, store), { status: 200, body: { unlinked: false } });
  // The account linked to another sign-in keeps that one.
  const other = `LOGIN#google#${'d'.repeat(64)}`;
  await store.put(`ACCOUNT#${account}`, 'LOGIN', { provider: 'google', login: other, at: '2026-10-01' });
  assert.deepEqual(await unlinkSignIn(account, login, store), { status: 200, body: { unlinked: false } });
  assert.equal((await store.get(`ACCOUNT#${account}`, 'LOGIN')).login, other);
  // Nothing that is not a sign-in's row is reached through it.
  for (const bad of [`KEY#${'a'.repeat(64)}`, 'LOGIN#apple#x', null]) {
    assert.equal((await unlinkSignIn(account, bad, store)).status, 400);
  }
  assert.equal((await unlinkSignIn('nope', login, store)).status, 400);
});
