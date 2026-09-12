// The Pages worker, in node's own test runner: node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker, { allowedOrigin, mint, serversOf } from './worker.mjs';

const KEY = 'ab'.repeat(32);
const answer = {
  iceServers: [
    { urls: ['stun:stun.cloudflare.com:3478', 'turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:5349?transport=tcp'], username: 'u', credential: 'c' },
  ],
};
const okUpstream = async (url, init) => {
  okUpstream.calls.push({ url, init });
  return new Response(JSON.stringify(answer), { status: 200 });
};
okUpstream.calls = [];
const env = { TURN_KEY_ID: 'kid', TURN_API_TOKEN: 'tok', ASSETS: { fetch: async () => new Response('asset', { status: 200 }) } };
const post = (body, origin) =>
  new Request('https://dev.open-hearts.pages.dev/api/turn', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(origin ? { origin } : {}) },
    body: JSON.stringify(body),
  });

test('origins: the site, its branches and a dev machine; nobody else', () => {
  assert.equal(allowedOrigin('https://dev.open-hearts.pages.dev'), 'https://dev.open-hearts.pages.dev');
  assert.equal(allowedOrigin('https://open-hearts.pages.dev'), 'https://open-hearts.pages.dev');
  assert.equal(allowedOrigin('http://localhost:8788'), 'http://localhost:8788');
  assert.equal(allowedOrigin('http://127.0.0.1:8788'), 'http://127.0.0.1:8788');
  assert.equal(allowedOrigin('https://evil-open-hearts.pages.dev'), null);
  assert.equal(allowedOrigin('https://open-hearts.pages.dev.evil.com'), null);
  assert.equal(allowedOrigin('not a url'), null);
  assert.equal(allowedOrigin(null), null);
});

test('servers: a list or the older single object, urls always a list', () => {
  assert.deepEqual(serversOf(answer), answer.iceServers);
  assert.deepEqual(serversOf({ iceServers: { urls: 'stun:a', username: 'u', credential: 'c' } }), [{ urls: ['stun:a'], username: 'u', credential: 'c' }]);
  assert.deepEqual(serversOf({ iceServers: [{ urls: [] }, { urls: 'stun:b' }] }), [{ urls: ['stun:b'] }]);
  assert.deepEqual(serversOf({}), []);
  assert.deepEqual(serversOf(null), []);
});

test('mint: not configured is said, not guessed', async () => {
  assert.deepEqual(await mint({}, okUpstream), { status: 503, body: { error: 'turn not configured' } });
  assert.deepEqual(await mint({ TURN_KEY_ID: 'kid' }, okUpstream), { status: 503, body: { error: 'turn not configured' } });
});

test('mint: credentials from the upstream, with the key and a ttl of four hours', async () => {
  okUpstream.calls.length = 0;
  const out = await mint(env, okUpstream);
  assert.equal(out.status, 200);
  assert.deepEqual(out.body, { iceServers: answer.iceServers, ttl: 4 * 3600 });
  assert.equal(okUpstream.calls.length, 1);
  const { url, init } = okUpstream.calls[0];
  assert.equal(url, 'https://rtc.live.cloudflare.com/v1/turn/keys/kid/credentials/generate-ice-servers');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers.authorization, 'Bearer tok');
  assert.deepEqual(JSON.parse(init.body), { ttl: 4 * 3600 });
});

test('mint: a ttl from the environment, and an upstream of its own for a test', async () => {
  okUpstream.calls.length = 0;
  const out = await mint({ ...env, TURN_TTL: '600', TURN_UPSTREAM: 'http://127.0.0.1:1/keys' }, okUpstream);
  assert.equal(out.body.ttl, 600);
  assert.equal(okUpstream.calls[0].url, 'http://127.0.0.1:1/keys/kid/credentials/generate-ice-servers');
});

test('mint: an upstream that refuses, is down, or talks nonsense is a bad gateway', async () => {
  assert.deepEqual(await mint(env, async () => new Response('no', { status: 401 })), { status: 502, body: { error: 'turn upstream 401' } });
  assert.deepEqual(await mint(env, async () => { throw new Error('down'); }), { status: 502, body: { error: 'turn upstream unreachable' } });
  assert.deepEqual(await mint(env, async () => new Response('<html>', { status: 200 })), { status: 502, body: { error: 'turn upstream not json' } });
  assert.deepEqual(await mint(env, async () => new Response('{}', { status: 200 })), { status: 502, body: { error: 'turn upstream gave no servers' } });
});

test('the worker: assets pass through, handlers answer, the rest is 404', async () => {
  const asset = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/play/index.html'), env);
  assert.equal(await asset.text(), 'asset');
  const missing = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/nothing'), env);
  assert.equal(missing.status, 404);
  const wrongMethod = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn'), env);
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get('allow'), 'POST, OPTIONS');
});

test('the worker: a preflight from an allowed origin, and none from another', async () => {
  const ok = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'OPTIONS', headers: { origin: 'http://127.0.0.1:8788' } }), env);
  assert.equal(ok.status, 204);
  assert.equal(ok.headers.get('access-control-allow-origin'), 'http://127.0.0.1:8788');
  assert.equal(ok.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
  const no = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'OPTIONS', headers: { origin: 'https://evil.example' } }), env);
  assert.equal(no.status, 204);
  assert.equal(no.headers.get('access-control-allow-origin'), null);
});

test('the worker: a key is required, then credentials come back, no-store', async () => {
  const bad = await worker.fetch(post({ key: 'short' }), env);
  assert.equal(bad.status, 400);
  const none = await worker.fetch(new Request('https://dev.open-hearts.pages.dev/api/turn', { method: 'POST', body: 'not json' }), env);
  assert.equal(none.status, 400);
  const realFetch = globalThis.fetch;
  globalThis.fetch = okUpstream;
  try {
    const res = await worker.fetch(post({ key: KEY }, 'https://dev.open-hearts.pages.dev'), env);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('access-control-allow-origin'), 'https://dev.open-hearts.pages.dev');
    const body = await res.json();
    assert.deepEqual(body.iceServers, answer.iceServers);
    assert.equal(body.ttl, 4 * 3600);
    const unconfigured = await worker.fetch(post({ key: KEY }), { ...env, TURN_API_TOKEN: undefined });
    assert.equal(unconfigured.status, 503);
  } finally {
    globalThis.fetch = realFetch;
  }
});
