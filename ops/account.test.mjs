// oh account's acts in Stripe: a suspension stops the renewal and a
// lift starts only that one again; a termination or a refund ends the
// subscription now and refunds the unused part of the year, once
// (ops/account.mjs, ops/billing.mjs).
//
//   node --test ops/*.test.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { proRata, refundFor } from './billing.mjs';
import { main } from './oh.mjs';
import { pictureDigest } from '../service/functions/pictures.mjs';
import { memoryStore } from '../service/functions/rows.mjs';

const account = '0123456789abcdef0123456789abcdef';
const day = 86400000;
const now = Date.parse('2026-10-16T12:00:00Z');
const start = now - 100 * day;
const end = start + 365 * day;

/// A fake of the parts of Stripe's API the acts use: one subscription,
/// its paid invoice and the refunds made against it. [calls] is what was
/// asked of it, writes only.
function fakeStripe({ status = 'active', cancelAtPeriodEnd = false, stopped = '', refunds = [] } = {}) {
  const calls = [];
  const sub = { status, cancel_at_period_end: cancelAtPeriodEnd, metadata: stopped ? { oh_stopped: stopped } : {} };
  return {
    calls,
    sub,
    refunds,
    async get(path) {
      if (path.startsWith('/subscriptions/sub_9')) {
        return { ...sub, latest_invoice: 'in_1', items: { data: [{ current_period_start: start / 1000, current_period_end: end / 1000 }] } };
      }
      if (path.startsWith('/invoice_payments?invoice=in_1')) return { data: [{ amount_paid: 599, currency: 'usd', payment: { type: 'payment_intent', payment_intent: 'pi_1' } }] };
      if (path.startsWith('/refunds?payment_intent=pi_1')) return { data: refunds.map((r) => ({ status: 'succeeded', amount: r.amount, metadata: { oh_act: r.act } })) };
      throw new Error(`not faked: GET ${path}`);
    },
    async post(path, fields) {
      calls.push(['POST', path, fields]);
      if (path === '/refunds') refunds.push({ amount: Number(fields.amount), act: fields['metadata[oh_act]'] });
      if (path === '/subscriptions/sub_9') {
        sub.cancel_at_period_end = fields.cancel_at_period_end === 'true';
        sub.metadata = { oh_stopped: fields['metadata[oh_stopped]'] };
      }
      return {};
    },
    async del(path, fields) {
      calls.push(['DELETE', path, fields]);
      sub.status = 'canceled';
      return {};
    },
  };
}

async function webSubscriber(source = 'stripe', id = 'sub_9') {
  const store = memoryStore();
  await store.put(`ACCOUNT#${account}`, 'META', { subscription: id });
  await store.put(`ACCOUNT#${account}`, 'DEVICE#aa', {});
  await store.put(`SUB#${id}`, 'META', { source });
  return store;
}

/// A context over [store] and [stripe] whose service answers every
/// order with what the act reports.
function context(store, stripe) {
  const said = [];
  const orders = [];
  return {
    said,
    orders,
    env: {},
    log: (line) => said.push(line),
    warn: (line) => said.push(`oh: ${line}`),
    store: async () => Object.assign(store, { list: async (prefix) => [...store.rows.keys()].filter((k) => k.startsWith(prefix)) }),
    bucket: () => ({ list: async () => [], get: async () => null, put: async () => {} }),
    pictures: async () => objects(),
    stripe: () => stripe,
    config: async () => ({ appOrigin: 'https://play.example' }),
    fetch: async (url, init) => {
      const id = JSON.parse(init.body).order;
      const order = await store.get(`ORDER#${id}`, 'META');
      orders.push(order.act);
      if (order.act === 'terminate') await store.put(`ACCOUNT#${account}`, 'SUSPENDED', { since: '2026-10-16', terminated: '2026-10-16' });
      return new Response(JSON.stringify({ act: order.act }), { status: 200 });
    },
    carryOptions: { tries: 1, wait: 0 },
    now: () => now,
  };
}

/// A bucket's objects, as restObjects reaches them (service/tool/r2.mjs),
/// from {key: bytes}: [kept] is what it holds, and [asked] the keys
/// read, in order.
function objects(kept = {}) {
  const asked = [];
  return {
    kept,
    asked,
    list: async (prefix) => Object.keys(kept).filter((k) => k.startsWith(prefix)).sort(),
    read: async (key) => {
      asked.push(key);
      return kept[key] ?? null;
    },
    write: async (key, bytes, type) => {
      kept[key] = { bytes, type };
    },
    remove: async (key) => {
      delete kept[key];
    },
  };
}

const other = 'fedcba9876543210fedcba9876543210';
const jpeg = (n) => Uint8Array.from([0xff, 0xd8, n]);
const base64 = (bytes) => Buffer.from(bytes).toString('base64');

test('the unused part of a year, to the cent, and never more than is left of the payment', () => {
  assert.equal(proRata(599, start, end, now), Math.floor((599 * 265) / 365));
  assert.equal(proRata(599, start, end, start), 599, 'nothing used yet');
  assert.equal(proRata(599, start, end, end + day), 0, 'all used');
  assert.equal(proRata(0, start, end, now), 0);
  const stands = { payment: { paid: 599, intent: 'pi_1' }, start, end, refunds: [{ amount: 500, act: 'goodwill' }] };
  assert.equal(refundFor(stands, 'terminate', { now }), 99, 'what is left of the payment caps it');
  assert.equal(refundFor({ ...stands, refunds: [{ amount: 10, act: 'terminate' }] }, 'terminate', { now }), 0, 'once per act');
  assert.equal(refundFor({ ...stands, refunds: [] }, 'refund', { full: true, now }), 599);
});

test('terminated: says first, then ends the subscription and refunds the unused part, once', async () => {
  const store = await webSubscriber();
  const stripe = fakeStripe();
  const ctx = context(store, stripe);
  assert.equal(await main(['account', 'terminate', account], ctx), 0);
  assert.equal(stripe.calls.length, 0, 'a dry run writes nothing to Stripe');
  assert.equal(ctx.orders.length, 0, 'nor asks the service');
  const owed = Math.floor((599 * 265) / 365);
  assert.match(ctx.said.join('\n'), new RegExp(`would refund ${(owed / 100).toFixed(2)} USD, the unused part of the year`));

  assert.equal(await main(['account', 'terminate', account, '--apply'], ctx), 0);
  assert.deepEqual(ctx.orders, ['terminate']);
  assert.deepEqual(
    stripe.calls.map(([method, path]) => `${method} ${path}`),
    ['DELETE /subscriptions/sub_9', 'POST /refunds'],
    'ended, then refunded',
  );
  assert.deepEqual(stripe.calls[1][2], { payment_intent: 'pi_1', amount: String(owed), 'metadata[oh_act]': 'terminate', 'metadata[oh_account]': account });

  // Run again: the order again, which changes nothing, and nothing more
  // from Stripe.
  await main(['account', 'terminate', account, '--apply'], ctx);
  assert.equal(stripe.calls.length, 2, 'not ended twice, not refunded twice');
});

test('terminated for a serious breach: ended, and nothing refunded', async () => {
  const store = await webSubscriber();
  const stripe = fakeStripe();
  const ctx = context(store, stripe);
  assert.equal(await main(['account', 'terminate', account, '--serious', '--apply'], ctx), 0);
  assert.deepEqual(stripe.calls.map(([method, path]) => `${method} ${path}`), ['DELETE /subscriptions/sub_9']);
  assert.match(ctx.said.join('\n'), /would refund nothing: a serious breach/);
});

test('refunded: ended now, and all of what is left with --full, not suspended', async () => {
  const store = await webSubscriber();
  const stripe = fakeStripe({ refunds: [{ amount: 100, act: 'goodwill' }] });
  const ctx = context(store, stripe);
  assert.equal(await main(['account', 'refund', account, '--full', '--apply'], ctx), 0);
  assert.deepEqual(ctx.orders, [], 'the account is not suspended');
  assert.deepEqual(stripe.calls.map(([method, path, fields]) => `${method} ${path}${fields?.amount ? ` ${fields.amount}` : ''}`), ['DELETE /subscriptions/sub_9', 'POST /refunds 499']);
});

test('suspended: the renewal stopped and marked; lifted: only that renewal started again', async () => {
  const store = await webSubscriber();
  const stripe = fakeStripe();
  const ctx = context(store, stripe);
  assert.equal(await main(['account', 'suspend', account, '--apply'], ctx), 0);
  assert.deepEqual(stripe.calls, [['POST', '/subscriptions/sub_9', { cancel_at_period_end: 'true', 'metadata[oh_stopped]': 'suspended' }]]);
  await store.put(`ACCOUNT#${account}`, 'SUSPENDED', { since: '2026-10-16' });
  assert.equal(await main(['account', 'lift', account, '--apply'], ctx), 0);
  assert.deepEqual(stripe.calls[1], ['POST', '/subscriptions/sub_9', { cancel_at_period_end: 'false', 'metadata[oh_stopped]': '' }]);

  // One the subscriber cancelled is theirs: a suspension leaves it, and
  // a lift does not start it again.
  const theirs = fakeStripe({ cancelAtPeriodEnd: true });
  const other = context(await webSubscriber(), theirs);
  await main(['account', 'suspend', account, '--apply'], other);
  await main(['account', 'lift', account, '--apply'], other);
  assert.deepEqual(theirs.calls, []);
});

test('a terminated account is not lifted, and a store subscription is left to the store, said so', async () => {
  const store = await webSubscriber();
  await store.put(`ACCOUNT#${account}`, 'SUSPENDED', { since: '2026-10-01', terminated: '2026-10-02' });
  const ctx = context(store, fakeStripe());
  assert.equal(await main(['account', 'lift', account, '--apply'], ctx), 1);
  assert.deepEqual(ctx.orders, []);

  const apple = context(await webSubscriber('apple', 'apple:1000'), fakeStripe());
  assert.equal(await main(['account', 'terminate', account, '--apply'], apple), 0);
  assert.match(apple.said.join('\n'), /bought in the App Store: we cannot cancel or refund it/);
  assert.deepEqual(apple.orders, ['terminate'], 'the account is still ended');
});

test('a legal hold: placed with its report, shown, and not released before its year; deletion and restore refused meanwhile', async () => {
  const store = await webSubscriber();
  await store.put(`ACCOUNT#${account}`, 'META', { subscription: 'sub_9' });
  const ctx = context(store, fakeStripe());
  // The pictures the relay copied: two the account put out, one of
  // whose copies is gone, and one only another account put out.
  const [a, b, c] = await Promise.all([1, 2, 3].map((n) => pictureDigest(base64(jpeg(n)))));
  const pictures = objects({
    [`seen/${account}/${a}`]: '',
    [`seen/${account}/${b}`]: '',
    [`seen/${other}/${c}`]: '',
    [`review/${a}.jpg`]: jpeg(1),
    [`review/${c}.jpg`]: jpeg(3),
  });
  const records = objects({ 'tables/t1.json': '{}' });
  ctx.pictures = async () => pictures;
  ctx.bucket = () => records;
  assert.equal(await main(['account', 'hold', account], ctx), 0);
  assert.equal(await store.get(`ACCOUNT#${account}`, 'HOLD'), null, 'a dry run holds nothing');
  assert.deepEqual(Object.keys(records.kept), ['tables/t1.json'], 'nor keeps a picture');
  assert.match(ctx.said.join('\n'), /would hold its data until at least 2027-10-16/);
  assert.match(ctx.said.join('\n'), new RegExp(`would keep a copy of each picture it put out in the last 30 days, 2 now, at held/${account}/`));
  assert.equal(await main(['account', 'hold', account, '--ref', 'not a ref'], ctx), 2);
  assert.equal(await main(['account', 'hold', account, '--ref', '123456789', '--apply'], ctx), 0);
  assert.deepEqual(await store.get(`ACCOUNT#${account}`, 'HOLD'), { since: '2026-10-16', until: '2027-10-16', ref: '123456789', deleteAsked: null });
  // Its pictures kept where only the operator reaches them, byte for
  // byte; one whose copy is gone said so; another account's left.
  assert.deepEqual(records.kept[`held/${account}/${a}.jpg`], { bytes: jpeg(1), type: 'image/jpeg' });
  assert.deepEqual(Object.keys(records.kept).sort(), [`held/${account}/${a}.jpg`, 'tables/t1.json']);
  assert.match(ctx.said.join('\n'), new RegExp(`oh: no copy left of picture ${b}`));
  assert.deepEqual(ctx.said.slice(-2), [`kept held/${account}/${a}.jpg`, `kept 1 picture(s) at held/${account}/`]);
  assert.ok(pictures.kept[`review/${a}.jpg`], 'the copy at the relay is left as it was');

  const shown = context(store, fakeStripe());
  await main(['account', 'show', account], shown);
  assert.match(shown.said.join('\n'), /under a legal hold: held since 2026-10-16, until at least 2027-10-16, for report 123456789/);

  // Nothing deletes it, or puts back what was taken off it.
  const del = context(store, fakeStripe());
  del.bucket = ctx.bucket;
  assert.equal(await main(['account', 'delete', account, '--apply'], del), 1);
  assert.ok(await store.get(`ACCOUNT#${account}`, 'META'), 'not deleted');
  const back = context(store, fakeStripe());
  assert.equal(await main(['account', 'restore', account, '--apply'], back), 1);
  assert.deepEqual(back.orders, [], 'no order written');

  // Its year out, it is released, and says what its owner asked for.
  assert.equal(await main(['account', 'release', account, '--apply'], ctx), 1, 'not before its year');
  assert.ok(await store.get(`ACCOUNT#${account}`, 'HOLD'));
  await store.put(`ACCOUNT#${account}`, 'HOLD', { ...(await store.get(`ACCOUNT#${account}`, 'HOLD')), deleteAsked: '2026-12-01' });
  const later = context(store, fakeStripe());
  later.bucket = () => records;
  later.now = () => Date.parse('2027-10-16T00:00:00Z');
  assert.equal(await main(['account', 'release', account], later), 0);
  assert.ok(await store.get(`ACCOUNT#${account}`, 'HOLD'), 'a dry run releases nothing');
  assert.ok(records.kept[`held/${account}/${a}.jpg`], 'nor deletes what it kept');
  assert.match(later.said.join('\n'), /would release the hold of 2026-10-16, and delete the 1 picture\(s\) it kept/);
  assert.equal(await main(['account', 'release', account, '--apply'], later), 0);
  assert.equal(await store.get(`ACCOUNT#${account}`, 'HOLD'), null);
  assert.deepEqual(Object.keys(records.kept), ['tables/t1.json'], 'the pictures it kept deleted, and nothing else');
  assert.match(later.said.join('\n'), /its owner asked on 2026-12-01 for its data to be deleted: \.\/oh account delete/);
});

test('a hold is placed before its pictures are copied, so one that fails to copy still holds, and running it again copies them', async () => {
  const store = await webSubscriber();
  const digest = await pictureDigest(base64(jpeg(1)));
  const pictures = objects({ [`seen/${account}/${digest}`]: '', [`review/${digest}.jpg`]: jpeg(1) });
  const records = objects();
  const ctx = context(store, fakeStripe());
  ctx.pictures = async () => ({ ...pictures, read: async () => { throw new Error('reading said 500'); } });
  ctx.bucket = () => records;
  assert.equal(await main(['account', 'hold', account, '--apply'], ctx), 1);
  assert.ok(await store.get(`ACCOUNT#${account}`, 'HOLD'), 'held');
  assert.deepEqual(records.kept, {});
  ctx.pictures = async () => pictures;
  assert.equal(await main(['account', 'hold', account, '--apply'], ctx), 0);
  assert.match(ctx.said.join('\n'), /already held/);
  assert.deepEqual(Object.keys(records.kept), [`held/${account}/${digest}.jpg`]);
});

test('a release that stops part way leaves the hold, so running it again finishes', async () => {
  const store = await webSubscriber();
  await store.put(`ACCOUNT#${account}`, 'HOLD', { since: '2025-10-01', until: '2026-10-01', ref: null, deleteAsked: null });
  const records = objects({ [`held/${account}/${'ab'.repeat(32)}.jpg`]: jpeg(1) });
  const ctx = context(store, fakeStripe());
  ctx.bucket = () => ({ ...records, remove: async () => { throw new Error('deleting said 500'); } });
  assert.equal(await main(['account', 'release', account, '--apply'], ctx), 1);
  assert.match(ctx.said.at(-1), /deleting said 500/);
  assert.ok(await store.get(`ACCOUNT#${account}`, 'HOLD'), 'still held');
  ctx.bucket = () => records;
  assert.equal(await main(['account', 'release', account, '--apply'], ctx), 0);
  assert.equal(await store.get(`ACCOUNT#${account}`, 'HOLD'), null);
  assert.deepEqual(records.kept, {});
});

test('found by a picture: by its SHA-256 or its copy\'s address, each account that put it out, with whether it is its profile picture now', async () => {
  const store = memoryStore();
  const [a, b] = await Promise.all([1, 2].map((n) => pictureDigest(base64(jpeg(n)))));
  await store.put(`ACCOUNT#${account}`, 'PROFILE', { picture: base64(jpeg(1)) });
  await store.put(`ACCOUNT#${other}`, 'PROFILE', { picture: base64(jpeg(2)) });
  // And a note under something that is no account, which the daily
  // email passes over too.
  const pictures = objects({ [`seen/${account}/${a}`]: '', [`seen/${other}/${a}`]: '', [`seen/${other}/${b}`]: '', [`seen/bench/${a}`]: '', [`review/${a}.jpg`]: jpeg(1) });
  const found = async (query) => {
    const ctx = context(store, fakeStripe());
    ctx.pictures = async () => pictures;
    assert.equal(await main(['account', 'find', query], ctx), 0);
    return ctx.said;
  };
  const both = [`${account}: put the picture out; its profile picture now`, `${other}: put the picture out; not its profile picture now`, '2 account(s)'];
  assert.deepEqual(await found(a), both);
  assert.deepEqual(await found(a.toUpperCase()), both);
  assert.deepEqual(await found(`https://pictures.openhearts.game/review/${a}.jpg`), both, 'as the CSAM Scanning Tool gives it');
  assert.deepEqual(await found(`/review/${a}.jpg`), both);
  assert.deepEqual(await found(b), [`${other}: put the picture out; its profile picture now`, '1 account(s)']);
  assert.deepEqual(await found('cd'.repeat(32)), ['0 account(s)'], 'a picture nobody put out');
  // A name is not looked for in the pictures.
  const named = context(store, fakeStripe());
  named.pictures = async () => assert.fail('the pictures read for a name');
  assert.equal(await main(['account', 'find', 'Ada'], named), 0);
});
