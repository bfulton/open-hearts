// Where the app is (worker.mjs, serveStatic; docs/06-service.md): one
// deployment, routed by host. play.openhearts.game is the app at its
// root, from the build's /play/; openhearts.game is the site, and sends
// /play/… on to the app's host; a preview serves the app at /play/.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import worker, { appHostFor, appPage, isAppHost } from './worker.mjs';

/// Static assets that answer each path with itself, and say which paths
/// were asked for: an address with no extension, or .html, as a page
/// with the production build's base and a link to the app.
function assets() {
  const asked = [];
  const html = (path) => !/\.\w+$/.test(path) || path.endsWith('.html');
  const body = (path) =>
    html(path)
      ? `<html><head><base href="/"></head><body><a href="https://play.openhearts.game/?lang=de">play</a>${path}</body></html>`
      : `file ${path}`;
  return {
    asked,
    env: {
      ASSETS: {
        fetch: async (r) => {
          const path = new URL(r.url ?? r).pathname;
          asked.push(path);
          return new Response(body(path), {
            status: 200,
            headers: {
              'content-type': html(path) ? 'text/html; charset=utf-8' : 'text/javascript',
              'content-security-policy': "frame-ancestors 'none'",
              'x-frame-options': 'DENY',
              'content-length': String(body(path).length),
            },
          });
        },
      },
    },
  };
}

const get = (url, env) => worker.fetch(new Request(url, { redirect: 'manual' }), env);

test('a page of the app is an address with no extension', () => {
  for (const p of ['/', '/subscription', '/room/KP4T9MXR', '/profile/', '/table/0a1b2c3d4e5f60718293a4b5c6d7e8f9']) assert.equal(appPage(p), true, p);
  for (const p of ['/main.dart.js', '/assets/fonts/x.otf', '/build-info.json', '/canvaskit/canvaskit.wasm']) assert.equal(appPage(p), false, p);
});

test('which host is the app, and which the site whose app it is', () => {
  assert.equal(appHostFor('openhearts.game'), 'play.openhearts.game');
  assert.equal(appHostFor('openhearts.localhost'), 'play.openhearts.localhost');
  for (const h of ['www.openhearts.game', 'play.openhearts.game', 'dev.open-hearts.pages.dev', 'open-hearts.pages.dev', '127.0.0.1', 'localhost']) {
    assert.equal(appHostFor(h), null, h);
  }
  assert.equal(isAppHost('play.openhearts.game'), true);
  assert.equal(isAppHost('play.openhearts.localhost'), true);
  for (const h of ['openhearts.game', 'play.dev.open-hearts.pages.dev', 'play.openhearts.game.evil.example']) assert.equal(isAppHost(h), false, h);
});

test("play.openhearts.game: the app at the root, its files from the build's /play/", async () => {
  const { asked, env } = assets();
  const front = await get('https://play.openhearts.game/', env);
  const room = await get('https://play.openhearts.game/room/KP4T9MXR?lang=fr', env);
  await get('https://play.openhearts.game/subscription?bought=1', env);
  await get('https://play.openhearts.game/main.dart.js', env);
  await get('https://play.openhearts.game/build-info.json', env);
  assert.deepEqual(asked, ['/play/', '/play/', '/play/', '/play/main.dart.js', '/play/build-info.json']);
  assert.equal(front.status, 200);
  // The production build's own base, unchanged: the app is at the root.
  assert.match(await room.text(), /<base href="\/">/);
  assert.match(await front.text(), /https:\/\/play\.openhearts\.game\//, "nothing rewritten on the app's host");
});

test('openhearts.game serves nothing of the app: /play/… is not found there', async () => {
  const { asked, env } = assets();
  for (const from of [
    'https://openhearts.game/play',
    'https://openhearts.game/play/',
    'https://openhearts.game/play/?lang=de',
    'https://openhearts.game/play/room/ABCD2345?x=1&lang=fr',
    'https://openhearts.game/play/main.dart.js',
  ]) {
    const res = await get(from, env);
    assert.equal(res.status, 404, from);
    assert.equal(res.headers.get('location'), null, from);
  }
  assert.deepEqual(asked, [], 'the build under /play/ is never read from the site');
  // Not under /play: the site, as it was.
  const playground = await get('https://openhearts.game/playground', env);
  assert.equal(playground.status, 200);
  const terms = await get('https://openhearts.game/terms', env);
  assert.equal(terms.status, 200);
  assert.match(await terms.text(), /https:\/\/play\.openhearts\.game\/\?lang=de/, "production's links left as they are");
  assert.deepEqual(asked, ['/playground', '/terms']);
});

test("openhearts.game/carry is the one page the app's host may frame", async () => {
  const { env } = assets();
  const carry = await get('https://openhearts.game/carry', env);
  assert.equal(carry.status, 200);
  assert.equal(carry.headers.get('content-security-policy'), 'frame-ancestors https://play.openhearts.game');
  assert.equal(carry.headers.get('x-frame-options'), null);
  assert.equal(carry.headers.get('cache-control'), 'no-store');
  const terms = await get('https://openhearts.game/terms', env);
  assert.equal(terms.headers.get('x-frame-options'), 'DENY');
  // On a preview there is nobody to hand anything to.
  const preview = await get('https://dev.open-hearts.pages.dev/carry', env);
  assert.equal(preview.headers.get('content-security-policy'), "frame-ancestors 'none'");
});

test('a preview keeps the app at /play/, its base moved there, and never sends anyone to production', async () => {
  const { asked, env } = assets();
  const front = await get('https://dev.open-hearts.pages.dev/play/', env);
  const room = await get('https://dev.open-hearts.pages.dev/play/room/ABCD2345?e2e=1', env);
  const file = await get('https://dev.open-hearts.pages.dev/play/main.dart.js', env);
  const index = await get('https://dev.open-hearts.pages.dev/play/index.html', env);
  for (const res of [front, room, file, index]) assert.equal(res.status, 200);
  assert.deepEqual(asked, ['/play/', '/play/', '/play/main.dart.js', '/play/index.html']);
  for (const res of [front, room, index]) {
    assert.equal(res.headers.get('content-length'), null, "the old length is not the page's");
    const page = await res.text();
    assert.match(page, /<base href="\/play\/">/);
    assert.doesNotMatch(page, /<base href="\/">/);
  }
  assert.equal(await file.text(), 'file /play/main.dart.js', 'a file is itself');
  // The site's links to the app are this preview's.
  const site = await (await get('https://dev.open-hearts.pages.dev/', env)).text();
  assert.match(site, /href="https:\/\/dev\.open-hearts\.pages\.dev\/play\/\?lang=de"/);
  assert.doesNotMatch(site, /play\.openhearts\.game/);
});

test("the rig's stand-ins: openhearts.localhost is the site, play.openhearts.localhost the app, port kept", async () => {
  const { env } = assets();
  const res = await get('http://openhearts.localhost:8788/play/room/ABCD2345?x=1', env);
  assert.equal(res.status, 404);
  const site = await (await get('http://openhearts.localhost:8788/', env)).text();
  assert.match(site, /href="http:\/\/play\.openhearts\.localhost:8788\/\?lang=de"/);
  const carry = await get('http://openhearts.localhost:8788/carry', env);
  assert.equal(carry.headers.get('content-security-policy'), 'frame-ancestors http://play.openhearts.localhost:8788');
});

test("/api/ is the handlers on the app's host and a preview's, and not the site's", async () => {
  const { asked, env } = assets();
  for (const host of ['play.openhearts.game', 'dev.open-hearts.pages.dev']) {
    const res = await get(`https://${host}/api/nothing`, env);
    assert.equal(res.status, 404, host);
    assert.deepEqual(await res.json(), { error: 'no such handler' });
  }
  for (const path of ['/api/health', '/api/licence', '/api/stripe']) {
    const res = await get(`https://openhearts.game${path}`, env);
    assert.equal(res.status, 404, path);
    assert.equal(await res.text(), 'not found\n', path);
  }
  assert.deepEqual(asked, []);
});
