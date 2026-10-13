// Backup codes: five to an account, each good once, shown on its
// devices, replaced all at once, and emailed to the payer when made and
// when replaced; a code brings a device into the same account.
// node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BACKUP_CODES, backupCodeOf, backupsFor, backupsMade, devicesOn, entitlementOf, redeemBackup } from './accounts.mjs';
import { backupMailHtml, backupMailText, mailerOf, moneyOf } from './household.mjs';
import { memoryStore } from './rows.mjs';
import { payerEmail, payerLookup, record } from './stripe.mjs';

const KEY = 'ab'.repeat(32);
const now = Date.UTC(2026, 9, 2);
const device = (i) => String(i).repeat(64).slice(0, 64);

async function household() {
  const store = memoryStore();
  await record({ type: 'checkout.session.completed', data: { object: { payment_status: 'paid', subscription: 'sub_9', customer: 'cus_1', metadata: { key: KEY } } } }, store, { now });
  await record({ type: 'customer.subscription.created', data: { object: { id: 'sub_9', current_period_end: Math.floor(Date.UTC(2027, 9, 2) / 1000) } } }, store, { now });
  return store;
}

const accountOf = async (store) => (await store.get(`KEY#${KEY}`, 'ENTITLEMENT')).account;

const mailbox = () => {
  const sent = [];
  const mail = async (to, codes, purchase = null) => sent.push({ to, codes, purchase });
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
  const charge = { amount: 599, currency: 'usd' };
  const first = await backupsMade(await accountOf(store), 'payer@example.com', store, mail, { now, charge, subscription: 'sub_9' });
  assert.deepEqual(first.body.emailed, true);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, 'payer@example.com');
  assert.deepEqual(sent[0].purchase, { charge }, 'the email that answers the payment says what was bought');
  assert.equal(sent[0].codes.length, BACKUP_CODES);
  for (const c of sent[0].codes) assert.match(c, /^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/);
  assert.equal(new Set(sent[0].codes).size, BACKUP_CODES);
  // A webhook delivered again makes nothing new and sends nothing.
  await backupsMade(await accountOf(store), 'payer@example.com', store, mail, { now, charge, subscription: 'sub_9' });
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
  assert.equal((await backupsMade(await accountOf(store), 'payer@example.com', store, mail, { now })).body.emailed, false);
  fail = false;
  assert.equal((await backupsMade(await accountOf(store), 'payer@example.com', store, mail, { now })).body.emailed, true);
  assert.equal(sent.length, 1);
});

test('each purchase is told of once: an account bought again hears of the new subscription', async () => {
  const store = await household();
  const account = await accountOf(store);
  const { sent, mail } = mailbox();
  const charge = { amount: 599, currency: 'usd' };
  await backupsMade(account, 'payer@example.com', store, mail, { now, charge, subscription: 'sub_9' });
  const later = now + 400 * 86_400_000;
  await backupsMade(account, 'other@example.com', store, mail, { now: later, charge, subscription: 'sub_10' });
  assert.equal(sent.length, 2);
  assert.equal(sent[1].to, 'other@example.com', 'to whoever paid this time');
  assert.deepEqual(sent[1].purchase, { charge });
  assert.deepEqual(sent[1].codes, sent[0].codes, 'the codes still good, not new ones');
  await backupsMade(account, 'other@example.com', store, mail, { now: later, charge, subscription: 'sub_10' });
  assert.equal(sent.length, 2, 'and once only');
  assert.equal((await store.get(`ACCOUNT#${account}`, 'BACKUP')).acknowledged, 'sub_10');
});

test('a purchase is told of even when every code has been used', async () => {
  const store = await household();
  const account = await accountOf(store);
  await backupsFor(KEY, store, null, { now });
  // Every code spent (a full account cannot spend the fifth, so as if
  // a device had been dropped between).
  const row = await store.get(`ACCOUNT#${account}`, 'BACKUP');
  await store.put(`ACCOUNT#${account}`, 'BACKUP', { ...row, codes: row.codes.map((c) => ({ ...c, used_at: new Date(now).toISOString() })) });
  const { sent, mail } = mailbox();
  const told = await backupsMade(account, 'payer@example.com', store, mail, { now, charge: null, subscription: 'sub_10' });
  assert.equal(told.body.emailed, true);
  assert.deepEqual(sent[0].codes, []);
  assert.deepEqual(sent[0].purchase, { charge: null });
  // Asked for from a device, there is nothing to send.
  assert.equal((await backupsFor(KEY, store, mail, { send: true, email: 'payer@example.com', now })).body.unsent, 'no codes');
  // And the email says so where the codes would be.
  const text = backupMailText([], { charge: null }).replace(/\s+/g, ' ');
  assert.match(text, /^Thank you for subscribing/);
  assert.match(text, /Every backup code of your account has been used\. Any device of the account can make new ones, under Subscription\./);
  assert.doesNotMatch(text, /Your backup codes:|Keep them private/);
  assert.ok(backupMailText([], { charge: null }).split('\n').every((line) => line.length <= 70));
  assert.match(backupMailHtml([], { charge: null }), /<p>Every backup code of your account has been used\./);
});

test('a code brings one device in, once', async () => {
  const store = await household();
  const { codes } = (await backupsFor(KEY, store, null, { now })).body;
  const code = codes[0].code;
  const joined = await redeemBackup(device(1), code, store, { now });
  assert.equal(joined.status, 200);
  assert.equal(joined.body.account, await accountOf(store), 'the same account, not one of its own');
  assert.equal((await entitlementOf(store, device(1), { now })).account, await accountOf(store));
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
  assert.equal((await devicesOn(store, await accountOf(store))).length, 5);
  assert.notEqual((await redeemBackup(device(6), codes[4], store, { now })).status, 200, 'the account has all the devices it can take');
  assert.equal((await backupsFor(KEY, store, null, { now })).body.codes[4].used, false);
});

test('replaced all at once from any device, which spends the old ones, and sends nothing', async () => {
  const store = await household();
  const old = (await backupsFor(KEY, store, null, { now })).body.codes.map((c) => c.code);
  const { sent, mail } = mailbox();
  const fresh = await backupsFor(KEY, store, mail, { rotate: true, email: 'payer@example.com', now });
  assert.equal(fresh.body.emailed, false);
  assert.equal(sent.length, 0, 'replacing is not sending: the Email button is');
  for (const c of old) assert.equal(fresh.body.codes.some((n) => n.code === c), false);
  assert.equal((await redeemBackup(device(1), old[0], store, { now })).status, 404, 'an old code is no such code');
  assert.equal((await redeemBackup(device(1), fresh.body.codes[0].code, store, { now })).status, 200);
});

test('sent when a device asks: the codes still good, to the payer, and why not when they cannot be', async () => {
  const store = await household();
  const { sent, mail } = mailbox();
  const asked = await backupsFor(KEY, store, mail, { send: true, email: 'payer@example.com', now });
  assert.equal(asked.body.emailed, true);
  assert.equal(asked.body.unsent, undefined);
  assert.equal(sent[0].to, 'payer@example.com');
  assert.deepEqual(sent[0].codes, asked.body.codes.map((c) => c.code));
  assert.equal(sent[0].purchase, null, 'asked for again: the codes alone, not a payment answered');
  // A code spent is not sent again.
  await redeemBackup(device(1), asked.body.codes[0].code, store, { now });
  await backupsFor(KEY, store, mail, { send: true, email: 'payer@example.com', now });
  assert.equal(sent[1].codes.length, 4);
  // No address (a store subscription), no mail bound, a send that fails.
  assert.equal((await backupsFor(KEY, store, mail, { send: true, now })).body.unsent, 'no address');
  assert.equal((await backupsFor(KEY, store, null, { send: true, email: 'payer@example.com', now })).body.unsent, 'no mail');
  const broken = async () => {
    throw new Error('refused');
  };
  const failed = await backupsFor(KEY, store, broken, { send: true, email: 'payer@example.com', now });
  assert.equal(failed.body.emailed, false);
  assert.equal(failed.body.unsent, 'failed');
  assert.equal(sent.length, 2);
});

test('only a device of the account sees its codes', async () => {
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
  // And why not, for the log.
  const refused = async () => Response.json({ error: { code: 'secret_key_required' } }, { status: 403 });
  assert.equal((await payerLookup(store, 'sub_9', { OH_STRIPE_SECRET: 'rk_x' }, refused)).why, 'Stripe said 403 (secret_key_required)');
  assert.equal((await payerLookup(store, 'sub_9', {}, fetchImpl)).why, 'no Stripe key');
  assert.equal((await payerLookup(store, 'sub_none', { OH_STRIPE_SECRET: 'rk_x' }, fetchImpl)).why, 'no customer on record');
});

test('the mailer: Cloudflare Email Sending from the address configured, or none', async () => {
  assert.equal(mailerOf({}), null);
  assert.equal(mailerOf({ EMAIL: { send() {} } }), null, 'no sender address');
  const got = [];
  const mail = mailerOf({ EMAIL: { send: async (m) => got.push(m) }, OH_MAIL_FROM: 'noreply@openhearts.game' });
  await mail('payer@example.com', ['AAAA-BBBB-CCCC-DDDD']);
  assert.equal(got[0].to, 'payer@example.com');
  assert.deepEqual(got[0].from, { email: 'noreply@openhearts.game', name: 'Open Hearts' });
  assert.match(got[0].text, /AAAA-BBBB-CCCC-DDDD/);
  assert.match(backupMailText(['X']), /Activate subscription/);
  assert.equal(got[0].replyTo, undefined, 'no reply address: a reply would quote the codes');
  assert.match(got[0].html, /AAAA-BBBB-CCCC-DDDD/);
  assert.match(backupMailHtml(['<b>']), /&#60;b&#62;/, 'escaped');
  assert.match(backupMailText(['X']), /openhearts\.game\/support/);
  // Asked for again from a device: the codes alone.
  assert.equal(got[0].subject, 'Your Open Hearts backup codes');
  assert.doesNotMatch(got[0].text, /renews/);
});

test('the email that answers a payment: what was bought, the renewal, how to cancel, then the codes', async () => {
  const got = [];
  const mail = mailerOf({ EMAIL: { send: async (m) => got.push(m) }, OH_MAIL_FROM: 'noreply@openhearts.game' });
  await mail('payer@example.com', ['AAAA-BBBB-CCCC-DDDD'], { charge: { amount: 599, currency: 'usd' } });
  const [m] = got;
  assert.equal(m.subject, 'Your Open Hearts subscription');
  const text = m.text.replace(/\s+/g, ' ');
  assert.match(text, /^Thank you for subscribing to Open Hearts live play\. You paid \$5\.99 USD for a year of it\./);
  assert.match(text, /renews automatically every year, on the date you subscribed, at the price then in force, until you cancel/);
  assert.match(text, /Stripe emails you a reminder before each renewal/);
  assert.match(text, /https:\/\/openhearts\.game\/support#cancel/);
  assert.match(text, /The terms you agreed to: https:\/\/openhearts\.game\/terms/);
  assert.ok(text.indexOf('until you cancel') < text.indexOf('AAAA-BBBB-CCCC-DDDD'), 'the terms first, then the codes');
  assert.ok(m.text.split('\n').every((line) => line.length <= 70), 'lines a plain mail reader shows whole');
  assert.match(m.html, /<a href="https:\/\/openhearts\.game\/support#cancel">/);
  // No amount to say: the rest still is.
  await mail('payer@example.com', ['X'], { charge: null });
  assert.match(got[1].text, /^Thank you for subscribing/);
  assert.doesNotMatch(got[1].text, /You paid/);
});

test('money, as Stripe gives it', () => {
  assert.equal(moneyOf({ amount: 599, currency: 'usd' }), '$5.99 USD');
  assert.equal(moneyOf({ amount: 500, currency: 'jpy' }), '¥500 JPY', 'a currency with no cents');
  assert.equal(moneyOf({ amount: 599, currency: 'dollars' }), null, 'not a currency code');
  assert.equal(moneyOf({ amount: 5.99, currency: 'usd' }), null);
  assert.equal(moneyOf({ amount: -1, currency: 'usd' }), null);
  assert.equal(moneyOf(null), null);
});
