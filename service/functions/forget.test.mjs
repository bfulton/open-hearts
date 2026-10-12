// An account's data deleted on request is an account forgotten
// (docs/how-to/delete-an-accounts-data.md): found by the name it played
// under or the address it paid with, and its name taken off the games
// it played, which stay the other players'. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { gunzipSync } from 'node:zlib';

import { accountsNamed, accountsPaidBy, forgetAccount, memoryStore } from './worker.mjs';
import { anonymizeGames, withoutNames } from './records.mjs';
import { restBucket } from '../tool/r2.mjs';

const ADA = 'a'.repeat(32);
const BAO = 'b'.repeat(32);
const CY = 'c'.repeat(32);

/// The keys of [store] under a prefix, as the operator's tool lists them.
const keysOf = (store) => async (prefix) => [...store.rows.keys()].filter((k) => k.startsWith(prefix));

const licence = (account, key) => ({ key, account, until: '2026-11-01', plan: 'annual', sig: '00'.repeat(64) });

/// A kept game's record as records.mjs keeps it, with a seat for each of
/// [accounts] (null for a seat without a licence) and a bot.
const game = (id, accounts, names) => ({
  v: 1,
  spec: {
    id,
    seats: [
      ...accounts.map((a, i) => (a ? { key: `${i}`.repeat(64), licence: licence(a, `${i}`.repeat(64)) } : { key: `${i}`.repeat(64) })),
      { bot: 'Romeo' },
    ],
  },
  record: [{ id: 'e1', pubkey: '0'.repeat(64), sig: 'f'.repeat(128) }],
  juries: [],
  releases: [],
  names,
});

test('an account is found by the name it plays under, case and edges aside, and by nobody else\'s', async () => {
  const store = memoryStore();
  await store.put(`ACCOUNT#${ADA}`, 'PROFILE', { name: 'Ada', icon: null, color: null, picture: null, version: 1 });
  await store.put(`ACCOUNT#${BAO}`, 'PROFILE', { name: 'Ada Lovelace', icon: null, color: null, picture: null, version: 1 });
  await store.put(`ACCOUNT#${CY}`, 'PROFILE', { name: ' ada ', icon: null, color: null, picture: null, version: 2 });
  await store.put(`ACCOUNT#${BAO}`, 'META', { subscription: 'sub_1' });
  assert.deepEqual(await accountsNamed(store, keysOf(store), 'ADA'), [ADA, CY]);
  assert.deepEqual(await accountsNamed(store, keysOf(store), 'Grace'), []);
  assert.deepEqual(await accountsNamed(store, keysOf(store), '  '), [], 'no name finds nobody');
});

test('an account is found by the address its web subscription was paid with, case aside', async () => {
  const store = memoryStore();
  await store.put('SUB#sub_1', 'ACCOUNT', { account: ADA });
  await store.put('SUB#sub_2', 'ACCOUNT', { account: ADA });
  await store.put('SUB#sub_3', 'ACCOUNT', { account: BAO });
  await store.put('SUB#sub_4', 'ACCOUNT', { account: CY });
  // Stripe as its API answers, a page at a time: a search by words,
  // whatever their case; a list after its last item.
  const customers = [
    { id: 'cus_1', email: 'Ada@Example.com' },
    { id: 'cus_2', email: 'ada@example.com' },
    { id: 'cus_3', email: 'bao.ada@example.com' },
    { id: 'cus_4', email: null },
  ];
  const subscriptions = { cus_1: ['sub_1', 'sub_9'], cus_2: ['sub_2'], cus_3: ['sub_3'] };
  const asked = [];
  const stripe = async (path) => {
    asked.push(path);
    const url = new URL(path, 'https://stripe.test');
    assert.equal(url.searchParams.get('limit'), '100', 'the most a page holds');
    const page = (all, at) => ({ data: all.slice(at, at + 1), has_more: at + 1 < all.length });
    if (url.pathname === '/customers/search') {
      const words = /^email:"(.*)"$/.exec(url.searchParams.get('query'))[1].toLowerCase().split(/[@.]/);
      const hits = customers.filter((c) => c.email && words.every((w) => c.email.toLowerCase().split(/[@.]/).includes(w)));
      const at = Number(url.searchParams.get('page') ?? 0);
      return { ...page(hits, at), next_page: at + 1 < hits.length ? String(at + 1) : null };
    }
    if (url.pathname === '/subscriptions') {
      assert.equal(url.searchParams.get('status'), 'all', 'ended subscriptions too');
      const all = (subscriptions[url.searchParams.get('customer')] ?? []).map((id) => ({ id }));
      const after = url.searchParams.get('starting_after');
      return page(all, after ? all.findIndex((s) => s.id === after) + 1 : 0);
    }
    throw new Error(`not a path the lookup takes: ${path}`);
  };
  // Two customers, one in capitals; three subscriptions, one Stripe
  // knows that no account stands behind; another address that has the
  // same words, which is not this one.
  assert.deepEqual(await accountsPaidBy(store, stripe, ' ADA@example.COM '), [ADA]);
  assert.ok(!asked.some((p) => p.includes('cus_3')), 'another address is not asked after');
  assert.ok(asked.some((p) => p.includes('starting_after=sub_1')), 'a second page of subscriptions');
  assert.ok(asked.some((p) => p.includes('page=1')), 'a second page of customers');
  assert.deepEqual(await accountsPaidBy(store, stripe, 'nobody@example.com'), []);
  assert.deepEqual(await accountsPaidBy(store, stripe, 'not an address'), []);
  // A quote in an address stays inside the query's.
  asked.length = 0;
  await accountsPaidBy(store, stripe, 'a"b@example.com');
  assert.equal(new URL(asked[0], 'https://stripe.test').searchParams.get('query'), 'email:"a\\"b@example.com"');
});

test('a kept game loses the names of the seats an account sat in, and nothing else', () => {
  const kept = game('t1', [ADA, BAO, ADA], { 0: 'Ada', 1: 'Bao', 2: 'Ada again' });
  const without = withoutNames(kept, ADA);
  assert.deepEqual(without.named, [0, 2]);
  assert.deepEqual(without.record.names, { 1: 'Bao' });
  assert.deepEqual({ ...without.record, names: undefined }, { ...kept, names: undefined }, 'the spec, the moves, the juries: as they were');
  assert.deepEqual(kept.names, { 0: 'Ada', 1: 'Bao', 2: 'Ada again' }, 'the record handed in is not changed');
  // Nobody left named: no names at all.
  assert.equal('names' in withoutNames(game('t2', [ADA], { 0: 'Ada' }), ADA).record, false);
  // Sat there with no name kept: nothing to take off.
  assert.deepEqual(withoutNames(game('t3', [ADA, BAO], { 1: 'Bao' }), ADA).named, []);
  // Never sat there, or at a seat without a licence: not its game.
  assert.equal(withoutNames(game('t4', [BAO, null], { 0: 'Bao', 1: 'X' }), ADA), null);
  assert.equal(withoutNames(game('t4', [BAO, null], { 0: 'Bao', 1: 'X' }), undefined), null, 'no account: no seat, not even a bot\'s');
  assert.equal(withoutNames(null, ADA), null);
});

test('every game an account played has its name taken off, and a dry run changes none', async () => {
  const kept = new Map([
    ['tables/t1.json', game('t1', [ADA, BAO], { 0: 'Ada', 1: 'Bao' })],
    ['tables/t2.json', game('t2', [BAO, CY], { 0: 'Bao', 1: 'Cy' })],
    ['tables/t3.json', game('t3', [CY, ADA], { 0: 'Cy', 1: 'Ada' })],
    ['tables/t4.json', game('t4', [ADA], {})],
    ['tables/t5.json', game('t5', [CY, null], { 0: 'Cy', 1: 'Ada' })],
  ]);
  const written = [];
  const bucket = {
    list: async (prefix) => [...kept.keys()].filter((k) => k.startsWith(prefix)),
    get: async (key) => structuredClone(kept.get(key) ?? null),
    put: async (key, record) => {
      written.push(key);
      kept.set(key, record);
    },
  };
  const would = await anonymizeGames(bucket, ADA, { dry: true });
  assert.deepEqual(would, [{ key: 'tables/t1.json', named: [0] }, { key: 'tables/t3.json', named: [1] }]);
  assert.deepEqual(written, [], 'a dry run writes nothing');
  assert.deepEqual(await anonymizeGames(bucket, ADA), would);
  assert.deepEqual(written, ['tables/t1.json', 'tables/t3.json']);
  assert.deepEqual(kept.get('tables/t1.json').names, { 1: 'Bao' });
  assert.deepEqual(kept.get('tables/t3.json').names, { 0: 'Cy' });
  assert.deepEqual(kept.get('tables/t2.json').names, { 0: 'Bao', 1: 'Cy' }, 'a game it never sat in: untouched');
  assert.deepEqual(kept.get('tables/t5.json').names, { 0: 'Cy', 1: 'Ada' }, 'a seat without a licence: no account\'s, whatever name it gave');
  // Run again, there is nothing left to do.
  assert.deepEqual(await anonymizeGames(bucket, ADA), []);
});

test('the operator\'s tool rewrites only a record it would write back as it was sent', async (t) => {
  const kept = new Map([
    ['tables/same.json', JSON.stringify(game('same', [ADA], { 0: 'Ada' }))],
    // 2.0 as Dart writes a double; JSON.stringify would write 2, which
    // Dart reads as another value, and the event's id with it.
    ['tables/other.json', '{"v":1,"spec":{"id":"other","seats":[]},"record":[{"event":{"body":{"at":2.0}}}]}'],
  ]);
  const sent = [];
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    const key = decodeURIComponent(new URL(url).pathname.split('/objects/')[1]);
    if (init.method === 'PUT') {
      sent.push({ key, headers: init.headers, body: JSON.parse(gunzipSync(init.body)) });
      return new Response(null, { status: 200 });
    }
    return kept.has(key) ? new Response(kept.get(key)) : new Response(null, { status: 404 });
  });
  const bucket = restBucket({ token: 't', account: 'a', bucket: 'b' });
  assert.deepEqual(await bucket.get('tables/same.json'), JSON.parse(kept.get('tables/same.json')));
  assert.equal(await bucket.get('tables/none.json'), null);
  await assert.rejects(bucket.get('tables/other.json'), /would not be written back as it was sent/);
  await bucket.put('tables/same.json', { v: 1 });
  assert.deepEqual(sent, [{
    key: 'tables/same.json',
    headers: { authorization: 'Bearer t', 'content-type': 'application/json', 'content-encoding': 'gzip' },
    body: { v: 1 },
  }]);
});

test('the operator\'s tool lists every page of kept games, cursor by cursor', async (t) => {
  const asked = [];
  t.mock.method(globalThis, 'fetch', async (url) => {
    const u = new URL(url);
    asked.push(u.search);
    const cursor = u.searchParams.get('cursor');
    const page = cursor === 'c1'
      ? { success: true, result: [{ key: 'tables/b.json' }], result_info: { is_truncated: false } }
      : { success: true, result: [{ key: 'tables/a.json' }], result_info: { is_truncated: true, cursor: 'c1' } };
    return Response.json(page);
  });
  const bucket = restBucket({ token: 't', account: 'a', bucket: 'b' });
  assert.deepEqual(await bucket.list('tables/'), ['tables/a.json', 'tables/b.json']);
  assert.equal(asked.length, 2);
  assert.ok(asked.every((q) => new URLSearchParams(q).get('prefix') === 'tables/'), 'each page asks for the prefix');
});

test('every subscription an account has had goes with it, and nobody else\'s', async () => {
  const store = memoryStore();
  // Ada's first subscription lapsed, and a second took the account on.
  await store.put(`ACCOUNT#${ADA}`, 'META', { subscription: 'sub_new' });
  for (const [sub, account] of [['sub_old', ADA], ['sub_new', ADA], ['sub_bao', BAO]]) {
    await store.put(`SUB#${sub}`, 'ACCOUNT', { account });
    await store.put(`SUB#${sub}`, 'META', { source: 'stripe', renews_at: '2026-01-01', cancelled_at: null });
    await store.put(`SUB#${sub}`, 'CUSTOMER', { customer: `cus_${sub}` });
  }
  const would = await forgetAccount(store, ADA, { dry: true, keys: keysOf(store) });
  for (const row of ['SUB#sub_old|ACCOUNT', 'SUB#sub_old|META', 'SUB#sub_old|CUSTOMER', 'SUB#sub_new|ACCOUNT']) assert.ok(would.includes(row), row);
  assert.equal(new Set(would).size, would.length, 'each row once');
  assert.equal(store.rows.has('SUB#sub_old|ACCOUNT'), true, 'a dry run deletes nothing');
  await forgetAccount(store, ADA, { keys: keysOf(store) });
  assert.deepEqual([...store.rows.keys()].filter((k) => k.startsWith('SUB#')).sort(), ['SUB#sub_bao|ACCOUNT', 'SUB#sub_bao|CUSTOMER', 'SUB#sub_bao|META']);
  // The address the old subscription was paid with finds nobody now.
  const stripe = async (path) => (path.startsWith('/customers/search') ? { data: [{ id: 'cus_1', email: 'ada@example.com' }] } : { data: [{ id: 'sub_old' }] });
  assert.deepEqual(await accountsPaidBy(store, stripe, 'ada@example.com'), []);
});
