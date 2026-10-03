// An address under /play is a page of the app, answered with the app
// (worker.mjs, appPage; app/lib/router.dart); everything else is a file.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import worker, { appPage } from './worker.mjs';

const at = (path) => new URL(path, 'https://openhearts.game');

test('a page of the app is an address under /play with no extension', () => {
  for (const p of ['/play/subscription', '/play/room/KP4T9MXR', '/play/profile/', '/play/about?lang=fr']) assert.equal(appPage(at(p)), true, p);
  for (const p of ['/play/', '/play', '/play/main.dart.js', '/play/assets/fonts/x.otf', '/privacy', '/', '/api/config', '/playground'])
    assert.equal(appPage(at(p)), false, p);
});

test('the worker answers a page with the app, and a file with itself', async () => {
  const asked = [];
  const env = { ASSETS: { fetch: async (r) => (asked.push(new URL(r.url ?? r).pathname), new Response('ok')) } };
  await worker.fetch(new Request(at('/play/subscription?lang=fr')), env);
  await worker.fetch(new Request(at('/play/main.dart.js')), env);
  await worker.fetch(new Request(at('/terms')), env);
  assert.deepEqual(asked, ['/play/', '/play/main.dart.js', '/terms']);
});
