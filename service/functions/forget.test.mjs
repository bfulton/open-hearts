// An account's data deleted on request is an account forgotten
// (docs/how-to/delete-an-accounts-data.md): found by the name it played
// under or the address it paid with, and its name taken off the games
// it played, which stay the other players'. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { readFile } from 'node:fs/promises';
import { gunzipSync } from 'node:zlib';

import { accountFor } from './accounts.mjs';
import { accountsNamed, accountsPaidBy, forgetAccount } from './deletion.mjs';
import { signerOn } from './licence.mjs';
import { memoryStore } from './rows.mjs';
import { anonymizeGames, forgottenKey, keepRecord, withoutNames } from './records.mjs';
import { keys } from '../do/sign.mjs';
import { forget } from '../tool/forget.mjs';
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
  // A name the operator took off is held, and found as it was.
  await store.put(`ACCOUNT#${BAO}`, 'HELD', { name: 'Grace', at: 'x' });
  await store.put(`ACCOUNT#${CY}`, 'HELD', { name: 'Ada', at: 'x' });
  assert.deepEqual(await accountsNamed(store, keysOf(store), 'grace'), [BAO]);
  assert.deepEqual(await accountsNamed(store, keysOf(store), 'ada'), [ADA, CY], 'each account once');
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

test('a game that is the whole of one stays the game when the operator\'s tool takes a name off it, though its API carries no custom metadata: no copy replaces it, and it is marked again', async (t) => {
  // R2 as the worker reaches it (head, get, put with a condition on the
  // etag) and as the tool does through Cloudflare's API, over the same
  // objects. The API's write is the one Wrangler sends: the bytes, a type
  // and an encoding, and no custom metadata (service/tool/r2.mjs).
  const objects = new Map();
  let etags = 0;
  const binding = {
    async head(key) {
      const o = objects.get(key);
      return o ? { key, etag: o.etag, customMetadata: o.custom } : null;
    },
    async get(key) {
      const o = objects.get(key);
      return o ? { body: new Blob([o.body]).stream(), etag: o.etag, customMetadata: o.custom } : null;
    },
    async put(key, body, options = {}) {
      const { etagMatches, etagDoesNotMatch } = options.onlyIf ?? {};
      if (etagMatches !== undefined && objects.get(key)?.etag !== etagMatches) return null;
      if (etagDoesNotMatch !== undefined && objects.has(key)) return null;
      objects.set(key, { body: Buffer.from(typeof body === 'string' ? body : new Uint8Array(body)), custom: options.customMetadata, etag: `etag-${++etags}` });
      return { key };
    },
  };
  const written = [];
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    const u = new URL(url);
    if (!u.pathname.includes('/objects/')) {
      const keys = [...objects.keys()].filter((k) => k.startsWith(u.searchParams.get('prefix')));
      return Response.json({ success: true, result: keys.map((key) => ({ key })), result_info: { is_truncated: false } });
    }
    const key = decodeURIComponent(u.pathname.split('/objects/')[1]);
    if (init.method === 'PUT') {
      written.push(init.headers);
      objects.set(key, { body: Buffer.from(init.body), custom: undefined, etag: `etag-${++etags}` });
      return new Response(null, { status: 200 });
    }
    return objects.has(key) ? new Response(gunzipSync(objects.get(key).body)) : new Response(null, { status: 404 });
  });

  const text = gunzipSync(await readFile(new URL('../../packages/table/test/fixtures/refereed_four.json.gz', import.meta.url))).toString().trim();
  const real = JSON.parse(text);
  const verify = (await signerOn(await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url)))).verify;
  const send = (seat, copy = text) => keepRecord(binding, real.spec.seats[seat].key, real.spec.id, copy, { verify, service: keys[1].public, house: real.spec.house });
  const at = `tables/${real.spec.id}.json`;
  const names = () => JSON.parse(gunzipSync(objects.get(at).body).toString()).names;
  const logLength = () => JSON.parse(gunzipSync(objects.get(at).body).toString()).log.length;
  const accounts = real.spec.seats.map((seat) => seat.licence.account);

  // The game is kept and marked, each player's device putting its own name
  // beside it.
  for (const seat of [0, 1, 2]) await send(seat);
  assert.equal(objects.get(at).custom.vouched, '1');
  assert.deepEqual(names(), { 0: 'Ada', 1: 'Bao', 2: 'Cy' });

  // Bao's account is forgotten, through the tool: the mark first, then the
  // name off the game, written through the API.
  const store = memoryStore();
  const said = [];
  await forget({ ...store, list: keysOf(store) }, restBucket({ token: 't', account: 'a', bucket: 'b' }), accounts[1], { apply: true, now: Date.parse('2026-11-01T12:00:00Z'), log: (line) => said.push(line) });
  assert.ok(said.some((line) => line.startsWith('took the name off') && line.includes(at)), said.join('\n'));
  assert.deepEqual(names(), { 0: 'Ada', 2: 'Cy' });
  assert.equal(logLength(), real.log.length);
  assert.ok(objects.has(forgottenKey(accounts[1])));
  assert.ok(written.every((h) => Object.keys(h).sort().join() === 'authorization,content-encoding,content-type'), 'the tool\'s writes carry a type and an encoding');
  assert.equal(objects.get(at).custom, undefined, 'and so the mark is gone from the game');

  // A later copy of the game cut short does not replace it...
  const resultAt = real.log.findIndex((entry) => entry.e?.kind === 'result');
  const stub = JSON.stringify({ ...real, log: real.log.slice(0, resultAt - 40) });
  assert.deepEqual(await send(2, stub), { status: 200, body: { kept: true, already: true } });
  assert.equal(logLength(), real.log.length);
  // ...and the game is marked again, with the accounts at its seats.
  assert.deepEqual(objects.get(at).custom, { accounts: accounts.join(','), vouched: '1' });
  // Nor does a late copy of the whole game, which would take the names
  // the others put beside it: it adds its own sender's, and Bao's, whose
  // account is forgotten, is put back by no one.
  objects.get(at).custom = undefined;
  assert.deepEqual(await send(3), { status: 200, body: { kept: true, already: true } });
  assert.deepEqual(names(), { 0: 'Ada', 2: 'Cy', 3: 'Dee' });
  assert.deepEqual(await send(1), { status: 200, body: { kept: true, already: true } });
  assert.deepEqual(names(), { 0: 'Ada', 2: 'Cy', 3: 'Dee' });
  assert.equal(logLength(), real.log.length);
  assert.equal(objects.get(at).custom.vouched, '1');
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
  // Each was told of a change to the terms.
  for (const sub of ['sub_old', 'sub_bao']) await store.put(`NOTICE#terms@2026-10-23`, `SUB#${sub}`, { at: '2026-10-24T00:00:00Z', lang: 'en' });
  const would = await forgetAccount(store, ADA, { dry: true, keys: keysOf(store) });
  for (const row of ['SUB#sub_old|ACCOUNT', 'SUB#sub_old|META', 'SUB#sub_old|CUSTOMER', 'SUB#sub_new|ACCOUNT', 'NOTICE#terms@2026-10-23|SUB#sub_old']) assert.ok(would.includes(row), row);
  assert.equal(would.includes('NOTICE#terms@2026-10-23|SUB#sub_bao'), false);
  assert.equal(new Set(would).size, would.length, 'each row once');
  assert.equal(store.rows.has('SUB#sub_old|ACCOUNT'), true, 'a dry run deletes nothing');
  await forgetAccount(store, ADA, { keys: keysOf(store) });
  assert.deepEqual([...store.rows.keys()].filter((k) => k.startsWith('SUB#')).sort(), ['SUB#sub_bao|ACCOUNT', 'SUB#sub_bao|CUSTOMER', 'SUB#sub_bao|META']);
  assert.deepEqual([...store.rows.keys()].filter((k) => k.startsWith('NOTICE#')), ['NOTICE#terms@2026-10-23|SUB#sub_bao']);
  // The address the old subscription was paid with finds nobody now.
  const stripe = async (path) => (path.startsWith('/customers/search') ? { data: [{ id: 'cus_1', email: 'ada@example.com' }] } : { data: [{ id: 'sub_old' }] });
  assert.deepEqual(await accountsPaidBy(store, stripe, 'ada@example.com'), []);
});

test('the operator\'s tool ends a web subscription still running before it deletes, and keeps only a store subscription\'s notes', async () => {
  const now = Date.parse('2026-11-01T12:00:00Z');
  const puts = [];
  const bucket = { list: async () => [], get: async () => null, put: async (...args) => puts.push(args) };
  /// Ada's account with sub_1, whose META is [meta], told of a change to the terms.
  const subscribed = async (meta) => {
    const store = memoryStore();
    await store.put(`ACCOUNT#${ADA}`, 'META', { subscription: 'sub_1' });
    await store.put('SUB#sub_1', 'ACCOUNT', { account: ADA });
    await store.put('SUB#sub_1', 'META', { source: 'stripe', ...meta });
    await store.put('NOTICE#terms@2026-10-23', 'SUB#sub_1', { at: '2026-10-24T00:00:00Z', lang: 'en' });
    return { ...store, list: keysOf(store) };
  };
  const ended = [];
  const endWeb = async (id) => ended.push(id);
  const run = (store, options = {}) => forget(store, bucket, ADA, { apply: true, now, ...options });

  // Running to 2027-03-01, not cancelled: a dry run says it would end it and ends nothing; the real
  // run ends it, then deletes everything, its note with the rest.
  const paid = await subscribed({ renews_at: '2027-03-01', cancelled_at: null });
  const said = [];
  await run(paid, { apply: false, endWeb, log: (line) => said.push(line) });
  assert.deepEqual(ended, []);
  assert.ok(said.includes('would end sub_1 in Stripe now: no renewal, and nothing refunded'));
  assert.ok(paid.rows.has(`ACCOUNT#${ADA}|META`), 'a dry run deletes nothing');
  await run(paid, { endWeb });
  assert.deepEqual(ended, ['sub_1']);
  assert.deepEqual([...paid.rows.keys()], []);

  // Cancelled, and running to 2027-03-01: Stripe still lists it, so it is ended too, and its note goes.
  const running = await subscribed({ renews_at: '2027-03-01', cancelled_at: '2026-10-30' });
  await run(running, { endWeb });
  assert.deepEqual(ended, ['sub_1', 'sub_1']);
  assert.deepEqual([...running.rows.keys()], []);

  // Already ended in Stripe: nothing to end, and its note goes with the rest.
  const over = await subscribed({ renews_at: '2026-11-01', cancelled_at: '2026-11-01', final: true });
  await run(over, { endWeb });
  assert.equal(ended.length, 2);
  assert.deepEqual([...over.rows.keys()], []);

  // Stripe not answering: nothing deleted, nothing marked, and the run is run again.
  const stuck = await subscribed({ renews_at: '2027-03-01', cancelled_at: null });
  const marked = puts.length;
  await assert.rejects(run(stuck, { endWeb: async () => { throw new Error('Stripe said 500'); } }), /Stripe said 500/);
  assert.ok(stuck.rows.has(`ACCOUNT#${ADA}|META`));
  assert.equal(puts.length, marked, 'not marked');

  // Without a way to end it, or for a subscription bought in a store, one not cancelled is refused.
  await assert.rejects(run(await subscribed({ renews_at: '2027-03-01', cancelled_at: null })), /sub_1 is still paid up to 2027-03-01; cancel it first/);
  const store = await subscribed({ source: 'apple', renews_at: '2027-03-01', cancelled_at: null });
  await assert.rejects(run(store, { endWeb }), /sub_1 is still paid up to 2027-03-01; cancel it first/);
  assert.equal(ended.length, 2, 'a store\'s is not Stripe\'s to end');
  assert.ok(store.rows.has(`ACCOUNT#${ADA}|META`));
  // One that is cancelled and runs on keeps its notes: it is still a subscriber's, and is not written to again about a change it was told of.
  const kept = await subscribed({ source: 'apple', renews_at: '2027-03-01', cancelled_at: '2026-10-30' });
  await run(kept, { endWeb });
  assert.deepEqual([...kept.rows.keys()], ['NOTICE#terms@2026-10-23|SUB#sub_1']);

  // Under a legal hold nothing is ended, marked, changed or deleted.
  const held = await subscribed({ renews_at: '2027-03-01', cancelled_at: null });
  await held.put(`ACCOUNT#${ADA}`, 'HOLD', { since: '2026-10-16', until: '2027-10-16', ref: null, deleteAsked: null });
  const before = [...held.rows.keys()].sort();
  const markedBefore = puts.length;
  await assert.rejects(run(held, { endWeb }), /held since 2026-10-16, until at least 2027-10-16/);
  assert.equal(ended.length, 2);
  assert.equal(puts.length, markedBefore, 'not marked');
  assert.deepEqual([...held.rows.keys()].sort(), before);
});

test('a lapsed subscriber who pays again keeps a note of the subscription before, and both go with the account, found without a listing', async () => {
  const store = memoryStore();
  const device = 'd'.repeat(64);
  await store.put(`KEY#${device}`, 'ENTITLEMENT', { account: ADA, licensed_until: '2026-01-01' });
  await store.put(`ACCOUNT#${ADA}`, 'META', { subscription: 'sub_old', created_at: '2025-01-01' });
  await store.put('SUB#sub_old', 'ACCOUNT', { account: ADA });
  await store.put('SUB#sub_old', 'META', { source: 'stripe', renews_at: '2026-01-01', cancelled_at: '2025-12-01' });
  const now = Date.parse('2026-10-19T12:00:00Z');
  assert.equal(await accountFor(store, 'sub_new', { buyer: device, make: true, now }), ADA, 'the same person, the same account');
  assert.deepEqual(await store.get(`ACCOUNT#${ADA}`, 'META'), { subscription: 'sub_new', created_at: '2025-01-01', before: ['sub_old'] });
  // Asked again for the same subscription: nothing noted twice.
  await accountFor(store, 'sub_new', { buyer: device, make: true, now });
  assert.deepEqual((await store.get(`ACCOUNT#${ADA}`, 'META')).before, ['sub_old']);
  await store.put('SUB#sub_new', 'META', { source: 'stripe', renews_at: '2027-10-19', cancelled_at: null });
  await forgetAccount(store, ADA);
  assert.deepEqual([...store.rows.keys()].filter((k) => k.startsWith('SUB#')), [], 'both, with no listing of the store');
});
