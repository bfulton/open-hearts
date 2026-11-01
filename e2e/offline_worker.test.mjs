// The service worker that keeps the app for a load with no network
// (app/web/offline_worker.js), in node's own test runner:
// node --test e2e/offline_worker.test.mjs
//
// Run in a context of its own with what a service worker has and node
// does not put in — `self`, its registration, `caches` — and a network
// this test decides the answers of. What is held here is the rule: the
// network first, always; the copy only when the network fails; and
// never a copy of what has to be fresh or nothing. offline.mjs holds a
// real browser to the same thing, from a cold start in airplane mode.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = fileURLToPath(new URL('.', import.meta.url));
const source = readFileSync(`${here}../app/web/offline_worker.js`, 'utf8');
const scope = 'https://open-hearts.pages.dev/play/';

/// The worker, loaded, with a network that answers from [files] while
/// [online] says so and fails otherwise.
function start(files = {}) {
  const handlers = {};
  const stored = new Map();
  const net = { online: true, asked: [] };
  const cache = {
    put: async (key, response) => void stored.set(typeof key === 'string' ? key : key.url, await response.text()),
  };
  const fetch = async (request) => {
    const url = new URL(typeof request === 'string' ? request : request.url, scope).href;
    net.asked.push(url);
    if (!net.online) throw new TypeError('Failed to fetch');
    const body = files[new URL(url).pathname];
    // Same-origin, as the browser marks it: a worker keeps nothing else.
    return body === undefined ? new Response('', { status: 404 }) : Object.defineProperty(new Response(body), 'type', { value: 'basic' });
  };
  const self = {
    location: new URL(`${scope}offline_worker.js`),
    registration: { scope },
    clients: { claim: async () => {} },
    skipWaiting: () => {},
    addEventListener: (type, f) => (handlers[type] = f),
  };
  const context = vm.createContext({
    self,
    caches: {
      open: async () => cache,
      match: async (key) => (stored.has(key) ? new Response(stored.get(key)) : undefined),
    },
    fetch,
    URL,
    Response,
    Set,
    Promise,
    Array,
    TypeError,
  });
  vm.runInContext(source, context);
  /// What the page would get for [request]: the worker's answer, or the
  /// browser's own fetch when the worker leaves it alone (null).
  const ask = async (request) => {
    let answered = null;
    const waits = [];
    handlers.fetch({ request, respondWith: (p) => (answered = p), waitUntil: (p) => waits.push(p) });
    if (answered === null) return null;
    const response = await answered;
    await Promise.all(waits);
    return response;
  };
  const tell = async (data) => {
    const waits = [];
    handlers.message({ data, waitUntil: (p) => waits.push(p) });
    await Promise.all(waits);
  };
  const install = async () => {
    const waits = [];
    handlers.install({ waitUntil: (p) => waits.push(p) });
    await Promise.all(waits);
  };
  return { ask, tell, install, stored, net };
}

const get = (path, mode = 'cors') => ({ url: new URL(path, scope).href, method: 'GET', mode });

test('online, the network answers, and what it says is kept', async () => {
  const w = start({ '/play/main.dart.js': 'v2' });
  const answer = await w.ask(get('main.dart.js'));
  assert.equal(await answer.text(), 'v2');
  assert.equal(w.stored.get(`${scope}main.dart.js`), 'v2');
});

test('online, a newer build is what loads, kept copy or not', async () => {
  const files = { '/play/main.dart.js': 'v1' };
  const w = start(files);
  await w.ask(get('main.dart.js'));
  files['/play/main.dart.js'] = 'v2';
  assert.equal(await (await w.ask(get('main.dart.js'))).text(), 'v2', 'the network first, always');
  assert.equal(w.stored.get(`${scope}main.dart.js`), 'v2');
});

test('offline, the kept copy answers — and every page in the scope is the one app', async () => {
  const w = start({ '/play/': '<html>', '/play/main.dart.js': 'v1' });
  await w.ask(get('./?e2e=1', 'navigate'));
  await w.ask(get('main.dart.js'));
  w.net.online = false;
  assert.equal(await (await w.ask(get('main.dart.js'))).text(), 'v1');
  // The same page, whatever its query.
  assert.equal(await (await w.ask(get('./?lang=fr', 'navigate'))).text(), '<html>');
  // And a page of it, by its own address (app/lib/router.dart).
  assert.equal(await (await w.ask(get('./room/KP4T9MXR', 'navigate'))).text(), '<html>');
  assert.equal(await (await w.ask(get('./subscription', 'navigate'))).text(), '<html>');
});

test('a file opened as a page is left to the network, and the app stays the page kept', async () => {
  const w = start({ '/play/': '<html>', '/play/robots.txt': 'User-Agent: *', '/play/nothing.here': '<html>the site</html>' });
  await w.ask(get('./', 'navigate'));
  assert.equal(await w.ask(get('./robots.txt', 'navigate')), null, 'the browser fetches it itself');
  assert.equal(await w.ask(get('./nothing.here', 'navigate')), null, 'and a missing file, which the site answers with its front page');
  w.net.online = false;
  assert.equal(await (await w.ask(get('./', 'navigate'))).text(), '<html>', 'offline, still the app');
});

test('offline, what was never kept fails as the network did', async () => {
  const w = start({});
  w.net.online = false;
  await assert.rejects(w.ask(get('assets/fonts/fallback/x.ttf')), TypeError);
});

test('what has to be fresh or nothing is never answered from here', async () => {
  const w = start({ '/play/build-info.json': '{"build":"abc1234"}' });
  assert.equal(await w.ask(get('build-info.json?t=1')), null, 'the build check goes to the network itself');
  assert.equal(await w.ask({ ...get('/api/licence'), method: 'POST' }), null, 'and so do the handlers');
  assert.equal(await w.ask(get('/api/devices')), null);
  assert.equal(await w.ask(get('https://relay.example/x')), null, 'and anything not this site\'s');
  assert.equal(w.stored.size, 0);
});

test('installed, it keeps the shell; told what the page loaded, it keeps that too', async () => {
  const w = start({
    '/play/': '<html>',
    '/play/main.dart.js': 'js',
    '/play/flutter_bootstrap.js': 'boot',
    '/play/deal.wasm': 'deal',
    '/play/canvaskit/chromium/canvaskit.wasm': 'ck',
    '/play/build-info.json': '{}',
  });
  await w.install();
  assert.equal(w.stored.get(scope), '<html>', 'the page, under the scope');
  assert.equal(w.stored.get(`${scope}deal.wasm`), 'deal');
  const before = w.net.asked.length;
  await w.tell({
    loaded: [
      `${scope}canvaskit/chromium/canvaskit.wasm`,
      `${scope}main.dart.js`, // the shell's, kept already
      `${scope}build-info.json?t=5`,
      'https://fonts.example/roboto.ttf',
    ],
  });
  assert.equal(w.stored.get(`${scope}canvaskit/chromium/canvaskit.wasm`), 'ck');
  assert.deepEqual(w.net.asked.slice(before), [`${scope}canvaskit/chromium/canvaskit.wasm`], 'nothing twice, nothing stale, nobody else\'s');
});
