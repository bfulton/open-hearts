// The app with no network: a service worker that keeps the last copy
// of every file the app was served, and hands it back when the network
// cannot.
//
// Solo play needs nothing but the device — the bots, the deal, the
// records are all here — but without this a page opened on a train, or
// from the home screen in airplane mode, is the browser's own "no
// internet" page: Flutter's service worker is a stub that unregisters
// itself, and the entry points are no-store (site/_headers) so that a
// deploy reaches a phone at once.
//
// So it is the network first, always, and this copy only when the
// network fails. Online nothing changes: every file is asked for as it
// was, a new deploy is what loads, and a cached bootstrap cannot lie
// about which build is running (docs/01-dev-loop.md). Offline the last
// build that loaded is the one that opens. What is never kept is what
// has to be fresh or nothing: the build check (build-info.json, which
// says nothing rather than something stale) and the service's handlers
// (/api/, which are not GETs anyway).
//
// The page registers this once it has drawn its first frame
// (flutter_bootstrap.js) and tells it what it loaded to get there,
// because a service worker sees nothing of the load that registered
// it: those files are fetched again here and kept. Every load after
// that goes through the fetch handler below and keeps itself.
'use strict';

const KEPT = 'open-hearts';

// The app's own shell, kept whatever the page says it loaded: a worker
// script fetched by `new Worker` is not always among the page's own
// resource timings, and a page closed before it could say anything
// still leaves this much behind.
const SHELL = ['./', 'flutter_bootstrap.js', 'main.dart.js', 'deal.wasm', 'deal_worker.js', 'schnorr.wasm', 'manifest.json'];

// Asked of the network every time, and better unanswered than
// answered from here.
function neverKept(url) {
  return url.pathname.endsWith('/build-info.json') || url.pathname.includes('/api/');
}

// Every page in this scope is the one app, whatever its query — a
// room, a code, `?e2e` — so a page is kept once, under the scope.
function keyOf(request) {
  return request.mode === 'navigate' ? self.registration.scope : request.url;
}

async function keep(urls) {
  const cache = await caches.open(KEPT);
  await Promise.all(
    urls.map(async (url) => {
      try {
        const response = await fetch(url, { cache: 'no-cache' });
        if (response.ok) await cache.put(url === './' ? self.registration.scope : new URL(url, self.registration.scope).href, response);
      } catch (_) {
        // Offline already, or gone: kept next time it loads.
      }
    }),
  );
}

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(keep(SHELL));
});

// The page that registered this is served by it from here on, so the
// files it loads later — a font the first trick needed — are kept too.
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('message', (event) => {
  const loaded = event.data?.loaded;
  if (!Array.isArray(loaded)) return;
  const here = self.location.origin;
  const shell = new Set(SHELL.map((url) => new URL(url, self.registration.scope).href));
  const urls = loaded.filter(
    (url) => typeof url === 'string' && url.startsWith(`${here}/`) && !shell.has(url) && !neverKept(new URL(url)),
  );
  event.waitUntil(keep([...new Set(urls)]));
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || neverKept(url)) return;
  const key = keyOf(request);
  event.respondWith(
    fetch(request).then(
      (response) => {
        if (response.ok && response.type === 'basic') {
          const copy = response.clone();
          event.waitUntil(caches.open(KEPT).then((cache) => cache.put(key, copy)).catch(() => {}));
        }
        return response;
      },
      async (failed) => {
        const kept = await caches.match(key);
        if (kept) return kept;
        throw failed;
      },
    ),
  );
});
