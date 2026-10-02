// Backup codes: five to a subscription, each good once, shown on the
// devices bound to it, replaced all at once, and emailed to the payer
// when made and when replaced. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BACKUP_CODES,
  backupCodeOf,
  backupMailText,
  backupsFor,
  backupsMade,
  devicesOn,
  entitlementOf,
  mailerOf,
  memoryStore,
  payerEmail,
  record,
  redeemBackup,
} from './worker.mjs';

const KEY = 'ab'.repeat(32);
const now = Date.UTC(2026, 9, 2);
const device = (i) => String(i).repeat(64).slice(0, 64);

async function household() {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', customer: 'cus_1', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor(Date.UTC(2027, 9, 2) / 1000) } } }, store, { now });
  return store;
}

const mailbox = () => {
  const sent = [];
  const mail = async (to, codes) => sent.push({ to, codes });
  return { sent, mail };
};

test('a backup code is read the way a person types it', () => {
  assert.equal(backupCodeOf('abcd-efgh-jkmn-pqrs'), 'ABCD-EFGH-JKMN-PQRS');
  assert.equal(backupCodeOf(' abcd efgh jkmn pqrs '), 'ABCD-EFGH-JKMN-PQRS');
  assert.equal(backupCodeOf('ABCDEFGHJKMNPQRS'), 'ABCD-EFGH-JKMN-PQRS');
  assert.equal(backupCodeOf('OIL0-0000-0000-0000'), '0110-0000-0000-0000', 'O, I and L are the digits they look like');
  for (const bad of ['', 'ABCD-EFGH-JKMN-PQR', 'ABCD-EFGH-JKMN-PQRSX', 'ABCD-EFGH-JKMN-PQRU', 'ab'.repeat(16), null, 7]) {
    assert.equal(backupCodeOf(bad), null, String(bad));
  }
});

test('made once when the subscription is paid for, and emailed once', async () => {
  const store = await household();
  const { sent, mail } = mailbox();
  const first = await backupsMade('sub_9', 'payer@example.com', store, mail, { now });
  assert.deepEqual(first.body.emailed, true);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, 'payer@example.com');
  assert.equal(sent[0].codes.length, BACKUP_CODES);
  for (const c of sent[0].codes) assert.match(c, /^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/);
  assert.equal(new Set(sent[0].codes).size, BACKUP_CODES);
  // A webhook delivered again makes nothing new and sends nothing.
  await backupsMade('sub_9', 'payer@example.com', store, mail, { now });
  assert.equal(sent.length, 1);
  const shown = await backupsFor(KEY, store, mail, { now });
  assert.deepEqual(shown.body.codes.map((c) => c.code), sent[0].codes, 'the device shows the codes that were sent');
  // The codes are not in any row's key: a listing of the store lists none.
  for (const k of store.rows.keys()) for (const c of sent[0].codes) assert.equal(k.includes(c), false);
});

test('a send that failed is tried again by the next delivery', async () => {
  const store = await household();
  let fail = true;
  const sent = [];
  const mail = async (to, codes) => {
    if (fail) throw Object.assign(new Error('nope'), { code: 'E_RATE_LIMIT_EXCEEDED' });
    sent.push({ to, codes });
  };
  assert.equal((await backupsMade('sub_9', 'payer@example.com', store, mail, { now })).body.emailed, false);
  fail = false;
  assert.equal((await backupsMade('sub_9', 'payer@example.com', store, mail, { now })).body.emailed, true);
  assert.equal(sent.length, 1);
});

test('a code brings one device in, once', async () => {
  const store = await household();
  const { codes } = (await backupsFor(KEY, store, null, { now })).body;
  const code = codes[0].code;
  const joined = await redeemBackup(device(1), code, store, { now });
  assert.equal(joined.status, 200);
  assert.equal((await entitlementOf(store, device(1), { now })).licensed_until, '2027-10-02');
  assert.equal((await redeemBackup(device(2), code, store, { now })).status, 409, 'spent');
  const after = (await backupsFor(KEY, store, null, { now })).body.codes;
  assert.deepEqual(after.map((c) => c.used), [true, false, false, false, false]);
  assert.equal((await redeemBackup(device(2), 'ZZZZ-ZZZZ-ZZZZ-ZZZZ', store, { now })).status, 404);
});

test('a code turned away by a full household is still good', async () => {
  const store = await household();
  const codes = (await backupsFor(KEY, store, null, { now })).body.codes.map((c) => c.code);
  for (let i = 1; i <= 4; i++) assert.equal((await redeemBackup(device(i), codes[i - 1], store, { now })).status, 200);
  assert.equal((await devicesOn(store, 'sub_9')).length, 5);
  assert.notEqual((await redeemBackup(device(6), codes[4], store, { now })).status, 200, 'five devices already');
  assert.equal((await backupsFor(KEY, store, null, { now })).body.codes[4].used, false);
});

test('replaced all at once from any device, which spends the old ones, and emails the new', async () => {
  const store = await household();
  const old = (await backupsFor(KEY, store, null, { now })).body.codes.map((c) => c.code);
  const { sent, mail } = mailbox();
  const fresh = await backupsFor(KEY, store, mail, { rotate: true, email: 'payer@example.com', now });
  assert.equal(fresh.body.emailed, true);
  assert.deepEqual(sent[0].codes, fresh.body.codes.map((c) => c.code));
  for (const c of old) assert.equal(fresh.body.codes.some((n) => n.code === c), false);
  assert.equal((await redeemBackup(device(1), old[0], store, { now })).status, 404, 'an old code is no such code');
  assert.equal((await redeemBackup(device(1), fresh.body.codes[0].code, store, { now })).status, 200);
  // Without an address (a store subscription), replaced and only shown.
  const quiet = await backupsFor(KEY, store, mail, { rotate: true, now });
  assert.equal(quiet.body.emailed, false);
  assert.equal(sent.length, 1);
});

test('only a device bound to the subscription sees its codes', async () => {
  const store = await household();
  assert.equal((await backupsFor(device(7), store, null, { now })).status, 402);
});

test('the payer\'s address is read from Stripe when it is needed, and only for a web subscription', async () => {
  const store = await household();
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push({ url: String(url), auth: init.headers.authorization });
    return new Response(JSON.stringify({ id: 'cus_1', email: 'payer@example.com' }), { status: 200 });
  };
  assert.equal(await payerEmail(store, 'sub_9', { OH_STRIPE_SECRET: 'rk_x' }, fetchImpl), 'payer@example.com');
  assert.deepEqual(asked, [{ url: 'https://api.stripe.com/v1/customers/cus_1', auth: 'Bearer rk_x' }]);
  assert.equal(await payerEmail(store, 'sub_9', {}, fetchImpl), null, 'no key, no address');
  assert.equal(await payerEmail(store, 'apple_1', { OH_STRIPE_SECRET: 'rk_x' }, fetchImpl), null);
  assert.equal(await payerEmail(store, 'sub_9', { OH_STRIPE_SECRET: 'rk_x' }, async () => new Response('', { status: 500 })), null);
});

test('the mailer: Cloudflare Email Sending from the address configured, or none', async () => {
  assert.equal(mailerOf({}), null);
  assert.equal(mailerOf({ EMAIL: { send() {} } }), null, 'no sender address');
  const got = [];
  const mail = mailerOf({ EMAIL: { send: async (m) => got.push(m) }, OH_MAIL_FROM: 'codes@openhearts.game' });
  await mail('payer@example.com', ['AAAA-BBBB-CCCC-DDDD']);
  assert.equal(got[0].to, 'payer@example.com');
  assert.deepEqual(got[0].from, { email: 'codes@openhearts.game', name: 'Open Hearts' });
  assert.match(got[0].text, /AAAA-BBBB-CCCC-DDDD/);
  assert.match(backupMailText(['X']), /Activate subscription/);
});
