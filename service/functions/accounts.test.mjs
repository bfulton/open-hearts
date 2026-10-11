// Subscriptions from before accounts: each becomes one account, its
// devices and backup codes moved under it, the first time anything
// touches it — or all at once, by service/tool/accounts.mjs — and
// nobody's subscription is lost. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import worker, { accountFor, backupCodeOf, devicesOn, entitlementOf, forgetHouseholds, memoryStore, redeemBackup, signerOn } from './worker.mjs';
import { migrateAll } from '../tool/accounts.mjs';
import { keys } from '../do/sign.mjs';

const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const [ADA, , BAO] = keys;
const now = Date.UTC(2026, 8, 16);
const signer = await signerOn(await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url)));

/// What the service held for a web subscription before accounts: two
/// devices, their rows naming the subscription, its backup codes, and a
/// sign-in linked to the first device.
function legacy() {
  const row = (v) => JSON.stringify(v);
  return memoryStore({
    'SUB#sub_9|META': row({ source: 'stripe', txn_ref: 'in_1', renews_at: '2027-09-16', cancelled_at: null }),
    'SUB#sub_9|CUSTOMER': row({ customer: 'cus_1' }),
    [`SUB#sub_9|DEVICE#${ADA.public}`]: row({ bound_at: '2026-01-01' }),
    [`SUB#sub_9|DEVICE#${BAO.public}`]: row({ bound_at: '2026-02-01' }),
    [`KEY#${ADA.public}|ENTITLEMENT`]: row({ subscription: 'sub_9', licensed_until: '2026-10-01', at: '2026-09-01' }),
    [`KEY#${BAO.public}|ENTITLEMENT`]: row({ subscription: 'sub_9', licensed_until: '2026-10-01', at: '2026-09-01' }),
    'SUB#sub_9|BACKUP': row({ codes: [{ code: 'ABCD-EFGH-JKMN-PQRS', used_at: null }], made_at: '2026-01-01T00:00:00.000Z', emailed_at: null }),
  });
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

const asking = async (pair, handler) => {
  const { requestStatement } = await import('./worker.mjs');
  const at = Math.floor(Date.now() / 1000);
  const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(requestStatement(handler, pair.public, at, ''))))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return { key: pair.public, at, sig: signer.sign(pair.secret, digest) };
};

async function movedUnder(store, account) {
  assert.match(account, /^[0-9a-f]{32}$/);
  assert.deepEqual((await devicesOn(store, account)).map((d) => d.key).sort(), [ADA.public, BAO.public].sort());
  for (const k of [ADA.public, BAO.public]) assert.equal((await store.get(`KEY#${k}`, 'ENTITLEMENT')).account, account);
  assert.equal((await store.get(`ACCOUNT#${account}`, 'META')).subscription, 'sub_9');
  assert.equal(await store.get('SUB#sub_9', `DEVICE#${ADA.public}`), null, 'nothing left where it was');
  assert.equal(await store.get('SUB#sub_9', 'BACKUP'), null);
  assert.equal((await store.get(`ACCOUNT#${account}`, 'BACKUP')).codes.length, 1);
  // And the subscription is still paid up for it.
  assert.equal((await entitlementOf(store, ADA.public, { now })).account, account);
}

test('the first device heard from takes its whole subscription into one account, and is licensed for it', async () => {
  forgetHouseholds();
  const store = legacy();
  const env = { OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kvOf(store), ASSETS: { fetch: async () => new Response('', { status: 404 }) } };
  const send = async (pair, handler) =>
    worker.fetch(new Request(`https://dev.open-hearts.pages.dev/api/${handler}`, { method: 'POST', body: JSON.stringify(await asking(pair, handler)) }), env);
  const { useSchnorrModule } = await import('./worker.mjs');
  useSchnorrModule(await WebAssembly.compile(await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url))));
  const ada = await (await send(ADA, 'licence')).json();
  const account = ada.licence.account;
  await movedUnder(store, account);
  // The other device of it is the same account, not one of its own.
  const bao = await (await send(BAO, 'licence')).json();
  assert.equal(bao.licence.account, account);
  // A backup code from before brings a third device into the same account.
  const third = 'cd'.repeat(32);
  const joined = await redeemBackup(third, backupCodeOf('ABCD-EFGH-JKMN-PQRS'), store, { now });
  assert.deepEqual([joined.status, joined.body.account], [200, account]);
});

test('one account, however many times it is asked for at once', async () => {
  const store = legacy();
  const made = await Promise.all([accountFor(store, 'sub_9', { now }), accountFor(store, 'sub_9', { now })]);
  // In the subscription's own turn these run one after the other; here,
  // one after the other too, to show the second finds the first's.
  const again = await accountFor(store, 'sub_9', { now });
  assert.equal(again, (await store.get('SUB#sub_9', 'ACCOUNT')).account);
  assert.ok(made.includes(again));
});

test('the walk at a deploy moves every subscription, and the worker after it finds them moved', async () => {
  const store = legacy();
  await store.put('SUB#apple:1', 'META', { source: 'apple', renews_at: '2027-01-01' });
  await store.put('SUB#apple:1', `DEVICE#${'ee'.repeat(32)}`, { bound_at: '2026-03-01' });
  await store.put(`KEY#${'ee'.repeat(32)}`, 'ENTITLEMENT', { subscription: 'apple:1', licensed_until: '2026-10-01', at: '2026-09-01' });
  const lines = [];
  const moved = await migrateAll(store, { say: (l) => lines.push(l), now });
  assert.equal(moved, 2);
  await movedUnder(store, (await store.get('SUB#sub_9', 'ACCOUNT')).account);
  assert.equal((await store.get(`KEY#${'ee'.repeat(32)}`, 'ENTITLEMENT')).account, (await store.get('SUB#apple:1', 'ACCOUNT')).account);
  assert.equal(await migrateAll(store, { say: () => {}, now }), 0, 'twice is once');
});
