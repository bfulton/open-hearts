// The worker's remote config (doc 06, "Remote config"), in node's own
// test runner: node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker, { CONFIG_DEFAULTS, configOf } from './worker.mjs';

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
    assert.deepEqual(await answer.json(), CONFIG_DEFAULTS);
    assert.equal(answer.headers.get('cache-control'), 'public, max-age=60');
  }
  assert.deepEqual(CONFIG_DEFAULTS, { v: 1, live: true, offer: true, relays: null, banner: null, update: null, feedback: null, privacy: null, terms: null });
});

test('the row is served, checked', async () => {
  const row = {
    live: false,
    offer: false,
    relays: ['wss://relay.one.example', 'wss://relay.two.example/'],
    banner: { id: 'maint-1', level: 'warn', text: { en: 'Live play is down until noon UTC.', de: 'Live-Spiel bis 12 Uhr UTC aus.' } },
    update: { before: '2026-10-01', text: { en: 'This version is too old for live play.' } },
    feedback: 'mailto:help@openhearts.example',
  };
  const answer = await ask({ OH_STORE: kvWith({ 'config|app': JSON.stringify(row) }) });
  assert.deepEqual(await answer.json(), {
    v: 1,
    live: false,
    offer: false,
    relays: ['wss://relay.one.example/', 'wss://relay.two.example/'],
    banner: row.banner,
    update: row.update,
    feedback: 'mailto:help@openhearts.example',
    privacy: null,
    terms: null,
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
  assert.equal(configOf({ relays: ['ws://plain.example'] }).relays, null, 'not in the open');
  assert.equal(configOf({ relays: ['wss://ok.example', 'https://not-a-relay.example'] }).relays, null);
  assert.equal(configOf({ relays: ['wss://user:pw@ok.example'] }).relays, null);
  assert.equal(configOf({ relays: [] }).relays, null);
  assert.equal(configOf({ relays: Array.from({ length: 9 }, (_, i) => `wss://r${i}.example`) }).relays, null);
  assert.equal(configOf({ relays: 'wss://ok.example' }).relays, null);
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
  assert.equal(configOf({ terms: 'https://legal.example/terms' }).terms, 'https://legal.example/terms');
  assert.equal(configOf({ privacy: 'javascript:alert(1)' }).privacy, null);
});

test('a store that throws is a store with nothing in it', async () => {
  const answer = await ask({ OH_STORE: { get: async () => { throw new Error('KV down'); } } });
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), CONFIG_DEFAULTS);
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
