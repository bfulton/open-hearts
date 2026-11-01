// The account's profile (docs/explanation/service.md): kept with the account,
// read by any of its devices, written only by its device in use and
// only in the shape the app makes, each write the next version, held to
// an allowance of its own an hour — and gone with the account's data
// when that is deleted. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import worker from './worker.mjs';
import { claimWith, ticketFor } from './accounts.mjs';
import { forgetAccount } from './deletion.mjs';
import { activeInStore, forgetHouseholds, householdOp } from './household.mjs';
import { signerOn } from './licence.mjs';
import { NAME_REFUSED, PROFILE_COLOURS, PROFILE_ICONS, PROFILE_NAME_MOST, PROFILE_PICTURE_MOST, profileOf } from './profile.mjs';
import { PICTURES_ROW, pictureDigest, withheldOf } from './pictures.mjs';
import { memoryStore } from './rows.mjs';
import { SERVICE_DEFAULTS } from './settings.mjs';
import { record } from './stripe.mjs';
import { carryOut, orderOf, orderRow } from './suspension.mjs';
import { keys } from '../do/sign.mjs';

const wasm = await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url));
const signer = await signerOn(wasm);
const SERVICE_SECRET = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const SERVICE_KEY = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const [ADA, , BAO, CY] = keys;

const sha = async (text) =>
  [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))].map((b) => b.toString(16).padStart(2, '0')).join('');

/// A request as the app makes one (app/lib/net/licence.dart).
const asking = async (pair, handler, { what = '', at = Math.floor(Date.now() / 1000), ...more } = {}) => ({
  key: pair.public,
  at,
  sig: signer.sign(pair.secret, await sha(`oh-request/1\n${handler}\n${pair.public}\n${at}\n${what}`)),
  ...more,
});

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

/// Ada subscribed, paid up a year, and Bao brought into her account by
/// a code: one account, two devices. Cy is nobody's.
async function twoDevices() {
  const now = Date.now();
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', metadata: { key: ADA.public } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor((now + 365 * 86400000) / 1000) } } }, store, { now });
  await claimWith(BAO.public, (await ticketFor(ADA.public, store, { now })).body.ticket, store, { now });
  const account = (await store.get(`KEY#${ADA.public}`, 'ENTITLEMENT')).account;
  forgetHouseholds();
  const env = { ASSETS: assets, OH_SERVICE_SECRET: SERVICE_SECRET, OH_SERVICE_KEY: SERVICE_KEY, OH_STORE: kvOf(store) };
  const ask = async (pair, handler, more = {}) => {
    const res = await worker.fetch(
      new Request(`https://play.openhearts.game/api/${handler}`, { method: 'POST', body: JSON.stringify(await asking(pair, handler, more)) }),
      env,
    );
    return { status: res.status, body: await res.json() };
  };
  /// [pair] writing [profile] as the app does: its own text, signed.
  const write = (pair, profile) => {
    const text = typeof profile === 'string' ? profile : JSON.stringify(profile);
    return ask(pair, 'profile', { what: text, profile: text });
  };
  const read = (pair) => ask(pair, 'profile');
  const open = (pair) => ask(pair, 'activate', { what: 'open ', want: 'open' });
  return { store, account, env, ask, write, read, open };
}

/// A JPEG's first bytes and then [n] bytes in all, base64.
const jpeg = (n) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(n - 4, 7)]).toString('base64');

test("the device in use is told the profile's version with each activation, so the operator's change reaches it at its next renewal", async () => {
  const { store, account, ask, write, open } = await twoDevices();
  assert.equal((await open(ADA)).body.profile, 0, 'none yet');
  await write(ADA, { name: 'Ada', icon: 'rocket', color: 3 });
  const renew = () => ask(ADA, 'activate', { what: 'renew ', want: 'renew' });
  assert.equal((await renew()).body.profile, 1, 'its own write');
  // The operator takes the name off, in the account's turn.
  const order = 'a'.repeat(32);
  await store.put(...orderRow(order), orderOf(account, 'remove', { name: true }));
  assert.equal((await carryOut({ op: 'order', account, order }, store, activeInStore(store))).status, 200);
  const renewed = await renew();
  assert.equal(renewed.status, 200);
  assert.equal(renewed.body.profile, 2, 'a version this device has not got');
});

test('a profile is written by the device in use and read by every device of the account, each write the next version', async () => {
  const { read, write, open } = await twoDevices();
  // None yet: an account from before profiles were kept.
  assert.deepEqual(await read(ADA), { status: 200, body: { profile: null, version: 0 } });

  await open(ADA);
  const first = await write(ADA, { name: 'Ada', icon: 'rocket', color: 3 });
  assert.equal(first.status, 200);
  assert.deepEqual(first.body.profile, { name: 'Ada', icon: 'rocket', color: 3 });
  assert.equal(first.body.version, 1);
  assert.match(first.body.updated_at, /^\d{4}-\d{2}-\d{2}T/);

  // The other device of the account reads it.
  const seen = await read(BAO);
  assert.deepEqual([seen.status, seen.body.profile, seen.body.version], [200, { name: 'Ada', icon: 'rocket', color: 3 }, 1]);

  // Bao takes the account up and writes: the last write is the profile,
  // whatever version its device last saw.
  await open(BAO);
  const picture = jpeg(500);
  const second = await write(BAO, { name: 'Ada L.', picture });
  assert.deepEqual([second.status, second.body.version], [200, 2]);
  assert.deepEqual((await read(ADA)).body.profile, { name: 'Ada L.', picture }, 'nothing of the one before is left: an icon unchosen is unchosen');
});

test('only the device in use writes; a device of no account, or a request not signed for what it writes, writes nothing', async () => {
  const { read, write, open, ask } = await twoDevices();
  await open(ADA);
  // Bao is a device of the account but has stepped back.
  const stepped = await write(BAO, { name: 'Bao' });
  assert.equal(stepped.status, 409);
  // Cy is nobody's: not read to, not written for.
  assert.equal((await read(CY)).status, 402);
  assert.equal((await write(CY, { name: 'Cy' })).status, 402);
  // What is written is what was signed: Ada's signature over one name
  // does not carry another, nor over a read a write.
  const signedFor = JSON.stringify({ name: 'Ada' });
  assert.equal((await ask(ADA, 'profile', { what: signedFor, profile: JSON.stringify({ name: 'Mallory' }) })).status, 401);
  assert.equal((await ask(ADA, 'profile', { profile: signedFor })).status, 401);
  // A profile that is not text is not a profile.
  assert.equal((await ask(ADA, 'profile', { what: '', profile: { name: 'Ada' } })).status, 400);
  assert.deepEqual((await read(ADA)).body, { profile: null, version: 0 }, 'nothing was written');
});

test('the shape is the app\'s and nothing else: a name, one of the icons, one of the colours, a small JPEG', async () => {
  const name = 'x'.repeat(PROFILE_NAME_MOST);
  assert.deepEqual(profileOf(JSON.stringify({ name })).profile, { name, icon: null, color: null, picture: null });
  assert.deepEqual(profileOf(JSON.stringify({ name: '' })).profile.name, '', 'no name yet is a profile');
  assert.equal(profileOf(JSON.stringify({ name: '😀'.repeat(PROFILE_NAME_MOST) })).error, undefined, 'characters, not code units');
  const big = jpeg(PROFILE_PICTURE_MOST);
  assert.equal(profileOf(JSON.stringify({ name: 'A', icon: PROFILE_ICONS[0], color: PROFILE_COLOURS - 1, picture: big })).error, undefined);
  for (const [why, text] of [
    ['not JSON', 'nope'],
    ['not an object', '[]'],
    ['no name', '{}'],
    ['a name too long', JSON.stringify({ name: 'x'.repeat(PROFILE_NAME_MOST + 1) })],
    ['a name untrimmed', JSON.stringify({ name: ' Ada' })],
    ['a name with a control in it', JSON.stringify({ name: 'A\nda' })],
    ['a name that is not text', JSON.stringify({ name: 7 })],
    ['a name the others may not see', JSON.stringify({ name: 'f u c k' })],
    ['an icon the app has not got', JSON.stringify({ name: 'A', icon: 'skull' })],
    ['a colour past the palette', JSON.stringify({ name: 'A', color: PROFILE_COLOURS })],
    ['a colour that is not whole', JSON.stringify({ name: 'A', color: 1.5 })],
    ['a picture too big', JSON.stringify({ name: 'A', picture: jpeg(PROFILE_PICTURE_MOST + 1) })],
    ['a picture that is not a JPEG', JSON.stringify({ name: 'A', picture: Buffer.from('<svg onload=x>').toString('base64') })],
    ['a picture that is not base64', JSON.stringify({ name: 'A', picture: '////----' })],
    ['anything else beside it', JSON.stringify({ name: 'A', admin: true })],
    ['too long to be one', JSON.stringify({ name: 'A', picture: 'A'.repeat(40000) })],
  ]) {
    assert.ok(profileOf(text).error, why);
  }
  // And through the route: refused with a reason, nothing written.
  const { read, write, open } = await twoDevices();
  await open(ADA);
  const refused = await write(ADA, { name: 'A', icon: 'skull' });
  assert.deepEqual([refused.status, refused.body.error], [400, 'not one of the icons']);
  assert.equal((await read(ADA)).body.version, 0);
  // A name the filter refuses (names.mjs) is not kept either.
  const named = await write(ADA, { name: 'Sh1t Head', icon: 'rocket' });
  assert.deepEqual([named.status, named.body.error], [400, NAME_REFUSED]);
  assert.equal((await read(ADA)).body.version, 0);
  // The biggest picture the app makes goes through the route whole.
  const whole = await write(ADA, { name: 'A', picture: big });
  assert.equal(whole.status, 200);
  assert.equal((await read(BAO)).body.profile.picture, big);
});

test('the app and the service agree on the icons, the colours, the picture\'s size and a refused name', async () => {
  const avatar = await readFile(new URL('../../app/lib/avatar.dart', import.meta.url), 'utf8');
  const icons = [...avatar.slice(avatar.indexOf('static const all')).matchAll(/^\s+'([a-z]+)': Icons\./gm)].map((m) => m[1]);
  assert.deepEqual(icons, [...PROFILE_ICONS]);
  assert.equal(Number(/static const paletteSize = (\d+);/.exec(avatar)[1]), PROFILE_COLOURS);
  assert.equal(Number(/static const maxPictureBytes = (\d+);/.exec(avatar)[1]), PROFILE_PICTURE_MOST);
  const names = await readFile(new URL('../../packages/table/lib/src/names.dart', import.meta.url), 'utf8');
  assert.equal(Number(/^const longestName = (\d+);/m.exec(names)[1]), PROFILE_NAME_MOST);
  // A refused name is one the app does not send again.
  const profile = await readFile(new URL('../../app/lib/net/account_profile.dart', import.meta.url), 'utf8');
  assert.ok(/static const _malformed = \{[^}]*'not an allowed name'/.test(profile) && NAME_REFUSED === 'not an allowed name');
});

test('an account\'s profile writes are held to their own allowance an hour, and leave the account\'s changes alone', async () => {
  const { account, write, open, ask } = await twoDevices();
  await open(ADA);
  const said = [];
  for (let i = 0; i < SERVICE_DEFAULTS.profileWritesPerHour + 2; i++) said.push((await write(ADA, { name: `Ada ${i}` })).status);
  assert.equal(said.filter((s) => s === 200).length, SERVICE_DEFAULTS.profileWritesPerHour);
  assert.equal(said.at(-1), 429);
  // A code is still to be had, and the profile still to be read.
  assert.equal((await ask(ADA, 'ticket')).status, 200);
  assert.equal((await ask(BAO, 'profile')).body.profile.name, `Ada ${SERVICE_DEFAULTS.profileWritesPerHour - 1}`);
  assert.match(account, /^[0-9a-f]{32}$/);
});

test('in the account\'s turn: a device dropped from the account reads and writes nothing of it', async () => {
  const { store, account } = await twoDevices();
  const active = activeInStore(store);
  const now = Date.now();
  await householdOp({ op: 'activate', key: BAO.public, account, want: 'open' }, store, { now, active });
  assert.equal((await householdOp({ op: 'profile', key: BAO.public, profile: '{"name":"Bao"}' }, store, { now, active })).status, 200);
  await householdOp({ op: 'drop', key: ADA.public, device: BAO.public }, store, { now, active });
  assert.equal((await householdOp({ op: 'profile', key: BAO.public }, store, { now, active })).status, 402);
  assert.equal((await householdOp({ op: 'profile', key: BAO.public, profile: '{"name":"Bao"}' }, store, { now, active })).status, 402);
  assert.equal((await householdOp({ op: 'profile', key: ADA.public }, store, { now, active })).body.profile.name, 'Bao', 'what was written stays the account\'s');
});

test("in the account's turn, every change of its picture goes through what keeps the account's pictures: set from its device, taken off and put back by the operator, and gone with the account", async () => {
  const { store, account } = await twoDevices();
  const active = activeInStore(store);
  const now = Date.now();
  const calls = [];
  const matched = new Set([jpeg(30)]);
  const profiled = [];
  const pictures = {
    set: async (c) => {
      calls.push({ ...c });
      profiled.push((await store.get(`ACCOUNT#${account}`, 'PROFILE')) !== null);
      return matched.has(c.picture) ? null : c.picture;
    },
  };
  const op = (o) => householdOp(o, store, { now, active, pictures });
  const order = async (id, act, more = {}) => {
    await store.put(...orderRow(id), orderOf(account, act, { ...more, now }));
    return op({ op: 'order', account, order: id });
  };
  const write = (picture) => op({ op: 'profile', key: ADA.public, profile: JSON.stringify({ name: 'Ada', picture }) });
  const kept = async () => (await store.get(`ACCOUNT#${account}`, 'PROFILE'))?.picture ?? null;
  const withheld = async () => withheldOf(await store.get(...PICTURES_ROW), now);
  const [one, two] = [jpeg(10), jpeg(20)];
  await op({ op: 'activate', key: ADA.public, account, want: 'open' });

  assert.equal((await write(one)).body.profile.picture, one);
  assert.equal((await write(jpeg(30))).body.profile.picture, undefined, 'a match is not kept');
  assert.equal(await kept(), null);
  await write(two);
  assert.equal((await order('a'.repeat(32), 'remove', { picture: true })).status, 200);
  assert.equal(await kept(), null);
  assert.equal((await order('b'.repeat(32), 'restore')).body.restored.includes('picture'), true);
  assert.equal(await kept(), two);
  assert.ok(!(await withheld()).has(await pictureDigest(two)));
  // Taken off again, and since found to match: not put back, and still
  // withheld.
  await order('c'.repeat(32), 'remove', { picture: true });
  matched.add(two);
  assert.deepEqual((await order('d'.repeat(32), 'restore')).body.restored, []);
  assert.equal(await kept(), null);
  assert.ok((await withheld()).has(await pictureDigest(two)));
  await write(one);
  assert.equal((await op({ op: 'delete', key: ADA.public })).status, 200);

  assert.deepEqual(calls, [
    { account, key: ADA.public, picture: one },
    { account, key: ADA.public, picture: jpeg(30) },
    { account, key: ADA.public, picture: two },
    { account, picture: null },
    { account, picture: two },
    { account, picture: null },
    { account, picture: two },
    { account, key: ADA.public, picture: one },
    { account, picture: null },
  ]);
  assert.equal(profiled.at(-1), true, 'deleted: its pictures no longer its own before its rows go');
});

test('an account\'s data deleted on request takes its profile with it, and nobody else\'s', async () => {
  const { store, account, write, open } = await twoDevices();
  await open(ADA);
  await write(ADA, { name: 'Ada', icon: 'rocket' });
  await householdOp({ op: 'backups', key: ADA.public }, store, { now: Date.now() });
  assert.equal([...store.rows.keys()].filter((k) => k.startsWith('BACKUP#')).length, 5);
  // Somebody else's account, which stays.
  await store.put('ACCOUNT#' + 'f'.repeat(32), 'PROFILE', { name: 'Someone', icon: null, color: null, picture: null, version: 1 });
  const would = await forgetAccount(store, account, { dry: true });
  assert.ok(would.includes(`ACCOUNT#${account}|PROFILE`));
  assert.ok(await store.get(`ACCOUNT#${account}`, 'PROFILE'), 'a dry run deletes nothing');
  const gone = await forgetAccount(store, account);
  assert.deepEqual(gone, would);
  for (const at of [
    `ACCOUNT#${account}|PROFILE`,
    `ACCOUNT#${account}|META`,
    `ACCOUNT#${account}|BACKUP`,
    `ACCOUNT#${account}|DEVICE#${ADA.public}`,
    `KEY#${ADA.public}|ENTITLEMENT`,
    `KEY#${BAO.public}|ENTITLEMENT`,
    'SUB#sub_9|META',
  ]) {
    assert.ok(gone.includes(at), at);
    assert.equal(store.rows.has(at), false, at);
  }
  assert.equal([...store.rows.keys()].filter((k) => k.startsWith('BACKUP#')).length, 0, 'the backup codes\' own rows too');
  assert.equal((await store.get('ACCOUNT#' + 'f'.repeat(32), 'PROFILE')).name, 'Someone');
});
