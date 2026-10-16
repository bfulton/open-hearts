// The worker's remote config (docs/explanation/service.md), in node's own
// test runner: node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import worker from './worker.mjs';
import { CONFIG_DEFAULTS, TABLE_TIMING_BOUNDS, WAITS_BOUNDS, configOf } from './config.mjs';

/// Cloudflare KV as the worker reads it: a JSON value by key.
const kvWith = (rows) => ({
  async get(key, type) {
    if (!(key in rows)) return null;
    return type === 'json' ? JSON.parse(rows[key]) : rows[key];
  },
});

const ask = (env, init) => worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/config', init), env);

test('no row, or no store, is the defaults: everything open, nothing said', async () => {
  for (const env of [{}, { OH_STORE: kvWith({}) }]) {
    const answer = await ask(env);
    assert.equal(answer.status, 200);
    assert.deepEqual(await answer.json(), { ...CONFIG_DEFAULTS, notices: [] });
    assert.equal(answer.headers.get('cache-control'), 'public, max-age=60');
  }
  assert.deepEqual(CONFIG_DEFAULTS, { v: 1, live: true, offer: true, relays: null, banner: null, update: null, feedback: null });
});

test('the row is served, checked', async () => {
  const row = {
    live: false,
    offer: false,
    relays: ['wss://relay.openhearts.game/{tag}', 'wss://two.openhearts.game/'],
    banner: { id: 'maint-1', level: 'warn', text: { en: 'Live play is down until noon UTC.', de: 'Live-Spiel bis 12 Uhr UTC aus.' } },
    update: { before: '2026-10-01', text: { en: 'This version is too old for live play.' } },
    feedback: 'mailto:help@openhearts.example',
  };
  const answer = await ask({ OH_STORE: kvWith({ 'config|app': JSON.stringify(row) }) });
  assert.deepEqual(await answer.json(), {
    v: 1,
    live: false,
    offer: false,
    relays: ['wss://relay.openhearts.game/{tag}', 'wss://two.openhearts.game/'],
    banner: row.banner,
    update: row.update,
    feedback: 'mailto:help@openhearts.example',
    notices: [],
  });
});

test('a field that does not check out is left at its default, and the rest still served', () => {
  assert.deepEqual(configOf(null), CONFIG_DEFAULTS);
  assert.deepEqual(configOf('live: false'), CONFIG_DEFAULTS);
  assert.deepEqual(configOf([1, 2]), CONFIG_DEFAULTS);
  assert.equal(configOf({ live: 'no' }).live, true, 'a kill switch is a boolean or nothing');
  assert.equal(configOf({ live: false, offer: 0 }).offer, true);
  // Relays: wss, a few, every one of them good — a list with one bad
  // entry is not quietly shortened into a different list.
  assert.equal(configOf({ relays: ['ws://plain.openhearts.game'] }).relays, null, 'not in the open');
  assert.equal(configOf({ relays: ['wss://ok.openhearts.game', 'https://not-a-relay.example'] }).relays, null);
  assert.equal(configOf({ relays: ['wss://user:pw@ok.openhearts.game'] }).relays, null);
  assert.equal(configOf({ relays: [] }).relays, null);
  // Ours only (docs/explanation/relay.md): the setting moves the tables
  // between our relays, never to anyone else's.
  for (const theirs of ['wss://relay.damus.io', 'wss://openhearts.game.evil.example', 'wss://evilopenhearts.game']) {
    assert.equal(configOf({ relays: [theirs] }).relays, null, theirs);
  }
  assert.equal(configOf({ relays: Array.from({ length: 9 }, (_, i) => `wss://r${i}.openhearts.game`) }).relays, null);
  assert.equal(configOf({ relays: 'wss://ok.openhearts.game' }).relays, null);
  // A banner needs an id and English, and keeps only what it can say.
  assert.equal(configOf({ banner: { id: 'x', text: { de: 'nur Deutsch' } } }).banner, null);
  assert.equal(configOf({ banner: { text: { en: 'no id' } } }).banner, null);
  assert.equal(configOf({ banner: { id: 'has space', text: { en: 'hi' } } }).banner, null);
  assert.deepEqual(configOf({ banner: { id: 'b', level: 'loud', text: { en: ' hi ', fr: 42, 'en-GB': 'no', es: 'x'.repeat(281) } } }).banner, {
    id: 'b',
    level: 'info',
    text: { en: 'hi' },
  });
  // Please update: a day, nothing else.
  assert.equal(configOf({ update: { before: 'yesterday' } }).update, null);
  assert.equal(configOf({ update: { before: '2026-10-01T00:00:00Z' } }).update, null);
  assert.deepEqual(configOf({ update: { before: '2026-10-01' } }).update, { before: '2026-10-01', text: null });
  // Feedback: a page over https, or mail; nothing that runs.
  assert.equal(configOf({ feedback: 'https://forms.example/hearts' }).feedback, 'https://forms.example/hearts');
  assert.equal(configOf({ feedback: 'javascript:alert(1)' }).feedback, null);
  assert.equal(configOf({ feedback: 'http://plain.example' }).feedback, null);
  assert.equal(configOf({ feedback: 'mailto:not-an-address' }).feedback, null);
  assert.equal(configOf({ feedback: 42 }).feedback, null);
  // Not the price, nor where the terms are: the site publishes them, and
  // they change only with it (site/ledger.mjs).
  for (const name of ['price', 'terms', 'privacy']) assert.ok(!(name in configOf({ [name]: 'https://legal.example/t' })), name);
});

test('a store that throws is a store with nothing in it', async () => {
  const answer = await ask({ OH_STORE: { get: async () => { throw new Error('KV down'); } } });
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), { ...CONFIG_DEFAULTS, notices: [] });
});

test('read with GET, from the site and a dev machine', async () => {
  const env = { OH_STORE: kvWith({}) };
  const post = await ask(env, { method: 'POST', body: '{}' });
  assert.equal(post.status, 405);
  assert.equal(post.headers.get('allow'), 'GET, OPTIONS');
  const pre = await ask(env, { method: 'OPTIONS', headers: { origin: 'https://dev.open-hearts.pages.dev' } });
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get('access-control-allow-origin'), 'https://dev.open-hearts.pages.dev');
  assert.equal(pre.headers.get('access-control-allow-methods'), 'GET, OPTIONS');
  const elsewhere = await ask(env, { headers: { origin: 'https://evil.example' } });
  assert.equal(elsewhere.headers.get('access-control-allow-origin'), null);
});

test('a table timing is served whole where every field checks out, and left out where any does not', () => {
  const table = { graceMs: 10000, bankMs: 90000, botActsMs: 20000 };
  assert.deepEqual(configOf({ table }).table, table);
  assert.deepEqual(configOf({ table: { ...table, later: 'a later build' } }).table, table, 'names it does not know are dropped');
  for (const bad of [
    { graceMs: 1000 },
    { graceMs: 61000 },
    { bankMs: '45000' },
    { fixedMs: 40000.5 },
    { graceMs: 10000, silenceMs: null },
  ]) {
    assert.equal('table' in configOf({ table: bad }), false, JSON.stringify(bad));
  }
  for (const nothing of [null, 'fast', [6000], {}]) {
    assert.equal('table' in configOf({ table: nothing }), false);
  }
  assert.equal('table' in configOf({}), false, 'absent is the standard table, and says nothing');
  // The edges are in.
  const least = Object.fromEntries(Object.entries(TABLE_TIMING_BOUNDS).map(([k, [lo]]) => [k, lo]));
  const most = Object.fromEntries(Object.entries(TABLE_TIMING_BOUNDS).map(([k, [, hi]]) => [k, hi]));
  assert.deepEqual(configOf({ table: least }).table, least);
  assert.deepEqual(configOf({ table: most }).table, most);
  // And the rest of the row is served regardless.
  assert.equal(configOf({ live: false, table: { graceMs: 1 } }).live, false);
});

test('the waits are served field by field, each within its bounds, the relay pair and the record three in order', () => {
  assert.equal(configOf({}).waits, undefined, 'none set: the app keeps its own');
  assert.deepEqual(configOf({ waits: { licenceMs: 9000, buyMs: 1, configEveryMin: 30, junk: 5 } }).waits, { licenceMs: 9000, configEveryMin: 30 });
  assert.equal(configOf({ waits: { licenceMs: 9000.5 } }).waits, undefined, 'whole numbers only');
  assert.deepEqual(configOf({ waits: { relaySlowMs: 10000, relayGiveUpMs: 60000 } }).waits, { relaySlowMs: 10000, relayGiveUpMs: 60000 });
  assert.equal(configOf({ waits: { relaySlowMs: 30000, relayGiveUpMs: 20000 } }).waits, undefined, 'slow after giving up: neither');
  assert.deepEqual(configOf({ waits: { recordAgainMs: 5000, recordForMs: 20000, recordSoonMs: 5000 } }).waits, { recordAgainMs: 5000, recordForMs: 20000, recordSoonMs: 5000 });
  assert.equal(configOf({ waits: { recordAgainMs: 30000, recordSoonMs: 2000 } }).waits, undefined, 'asked again past the short span: none');
  assert.equal(configOf({ waits: { recordAgainMs: 20000 } }).waits, undefined, 'past the build\'s short span of nine seconds: none');
  assert.equal(configOf({ waits: [1, 2] }).waits, undefined);
});

test('the table clocks\' bounds are the table\'s own', () => {
  // Every seat parses the start event by TableTiming.bounds, so a clock
  // the worker serves outside them makes the standard table everywhere.
  const dart = readFileSync(new URL('../../packages/table/lib/src/timing.dart', import.meta.url), 'utf8');
  const bounds = dart.slice(dart.indexOf('static const bounds = {'), dart.indexOf('};', dart.indexOf('static const bounds = {')));
  const table = Object.fromEntries([...bounds.matchAll(/'(\w+)': \((\d+), (\d+)\)/g)].map((m) => [m[1], [Number(m[2]), Number(m[3])]]));
  assert.deepEqual(table, { ...TABLE_TIMING_BOUNDS });
});

test('the waits\' bounds are the app\'s own', () => {
  const dart = readFileSync(new URL('../../app/lib/net/remote_config.dart', import.meta.url), 'utf8');
  const app = Object.fromEntries([...dart.matchAll(/'(\w+)': \((\d+), (\d+)\)/g)].map((m) => [m[1], [Number(m[2]), Number(m[3])]]));
  assert.deepEqual(app, { ...WAITS_BOUNDS });
});
