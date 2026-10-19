// The app's move from openhearts.game/play/ to play.openhearts.game
// (docs/explanation/service.md, "Where the app is"), in a browser.
//
//   ./e2e/build.sh
//   node e2e/move.mjs                   # from the repo root
//   node e2e/move.mjs --only "carried"
//
// The rig serves the site and the app as production does, behind the
// site's own worker, on stand-ins for production's hosts that a browser
// takes to be this machine and one site, as production's two are
// (drive.mjs, serveApp): openhearts.localhost for openhearts.game, and
// play.openhearts.localhost for play.openhearts.game. 127.0.0.1 is a
// preview.
//
// What is held: the old address serves nothing of the app any more,
// and the site's host no service; a device made at the old address is
// the same device at the new one — its key, its licence, its name — because the frame of the
// old origin it is asked through reads that origin's own storage, not a
// partitioned copy; a key already at the new address is never replaced;
// a device with nothing to bring is not held up; a carry that never
// answers holds the app up for a moment and no longer; and a preview
// still serves the app at /play/ and sends nobody to production.
import { request } from 'node:http';

import { chromium } from './browser.mjs';
import { argOf, log, serveApp, sleep, startRelay, waitFor } from './drive.mjs';

const phone = { width: 390, height: 844 };
const ready = /^Play solo$/;

/// One request to [origin]'s host, by its name, without following a
/// redirect: Node does not take a .localhost name to be this machine,
/// as a browser does, so it is asked at 127.0.0.1 under that name.
function head(origin, path) {
  const { host, port } = new URL(origin);
  return new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port, path, method: 'GET', headers: { host } }, (res) => {
      res.resume();
      resolve({ status: res.statusCode, location: res.headers.location });
    });
    req.on('error', reject);
    req.end();
  });
}

const stored = (page, key) => page.evaluate((k) => localStorage.getItem(k), key);
const carried = (page) => page.evaluate(() => window.ohCarried);

async function until(what, check, { timeout = 30000 } = {}) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(200);
  }
}

function expect(ok, what) {
  if (!ok) throw new Error(what);
}

const flows = [
  {
    name: 'the old address serves nothing of the app, and the site no service',
    async run({ app }) {
      for (const from of ['/play', '/play/', '/play/room/ABCD2345?x=1&lang=de', '/play/main.dart.js', '/api/health']) {
        const res = await head(app.site, from);
        expect(res.status === 404, `${from}: ${res.status}, not 404`);
        expect(res.location === undefined, `${from} was sent to ${res.location}`);
      }
      // The handler answers there: 200, or 503 for the Stripe the rig has
      // not got (health.mjs, healthOf) — not the site's 404.
      const health = await head(app.url, '/api/health');
      expect(health.status === 200 || health.status === 503, `the app's host's health: ${health.status}`);
    },
  },
  {
    name: 'a device made at the old address, its offline worker installed, is carried to the new one',
    async run({ app, newContext }) {
      const context = await newContext();
      const page = await context.newPage();
      // Where the app used to be: the site's host, at /play/.
      app.legacy(true);
      try {
        await page.goto(app.at(`${app.site}/play/?e2e=1`));
        await waitFor(page, ready, { what: 'the app at the old address', timeout: 60000 });
        const key = await until('a key at the old address', () => stored(page, 'flutter.identity_secret'));
        // The open house licenses every device that asks (drive.mjs).
        const licence = await until('a licence at the old address', () => stored(page, 'flutter.licence'));
        await page.evaluate(() => localStorage.setItem('flutter.identity_name', JSON.stringify('Ada')));
        // And agreed to the terms, as a device that played live there had
        // (app/lib/home_page.dart, `_agreed`): carried with the rest, so
        // the room at the new address goes straight in.
        await page.evaluate(() => localStorage.setItem('flutter.identity_agreed_terms', JSON.stringify('2026-01-01')));
        // The offline worker the old address installed, in charge of it.
        await until('the old offline worker', () => page.evaluate(() => navigator.serviceWorker.controller?.scriptURL ?? null));
        app.legacy(false);
        // The licence as it was carried, not one the new host's service
        // hands over afresh: the service is not asked here.
        await context.route(`${app.url}/api/licence`, (route) => route.abort());

        // A room at the new host.
        const link = app.at('/room/ABCD2345?e2e=1&x=1');
        await page.goto(link);
        const at = new URL(page.url());
        expect(at.pathname === '/room/ABCD2345' && at.search === new URL(link).search, `the link landed at ${page.url()}`);
        await waitFor(page, ready, { what: 'the app at the new address', timeout: 60000 });
        expect((await carried(page)) === 'carried', `the carry said ${await carried(page)}`);
        expect((await stored(page, 'flutter.identity_secret')) === key, 'the key is not the same');
        expect((await stored(page, 'flutter.licence')) === licence, 'the licence is not the same');
        expect((await stored(page, 'flutter.identity_name')) === '"Ada"', 'the name is not the same');
        expect(JSON.parse(await stored(page, 'oh.carried')).entries >= 3, 'the carry is not marked done');
        // The device is the same one to the app, not only in its storage:
        // a reload reads the same key, and nothing makes another.
        await page.reload();
        await waitFor(page, ready, { what: 'the app, reloaded', timeout: 60000 });
        expect((await carried(page)) === 'kept', 'a second load carried again');
        expect((await stored(page, 'flutter.identity_secret')) === key, 'the key changed on a reload');

        // The old origin keeps its copy, for a rollback.
        const old = await context.newPage();
        await old.goto(`${app.site}/`);
        expect((await stored(old, 'flutter.identity_secret')) === key, 'the old address lost its copy');
      } finally {
        app.legacy(false);
      }
    },
  },
  {
    name: 'a key already at the new address is never replaced',
    async run({ app, newContext }) {
      const context = await newContext();
      const page = await context.newPage();
      await page.goto(app.at('/?e2e=1'));
      await waitFor(page, ready, { what: 'the app', timeout: 60000 });
      const key = await until('a key', () => stored(page, 'flutter.identity_secret'));
      // Then the old origin comes to hold a different device's…
      const old = await context.newPage();
      await old.goto(`${app.site}/`);
      await old.evaluate(() => {
        localStorage.setItem('flutter.identity_secret', JSON.stringify('ab'.repeat(32)));
        localStorage.setItem('flutter.identity_name', JSON.stringify('Mallory'));
      });
      // …and the new one forgets it ever asked.
      await page.evaluate(() => localStorage.removeItem('oh.carried'));
      await page.reload();
      await waitFor(page, ready, { what: 'the app, reloaded', timeout: 60000 });
      expect((await carried(page)) === 'kept', `the carry said ${await carried(page)}`);
      expect((await stored(page, 'flutter.identity_secret')) === key, 'the key was replaced');
      expect((await stored(page, 'flutter.identity_name')) !== '"Mallory"', 'the name was replaced');
    },
  },
  {
    name: 'nothing at the old address: nothing carried, and no wait for it',
    async run({ app, newContext }) {
      const context = await newContext();
      const page = await context.newPage();
      const began = Date.now();
      await page.goto(app.at('/?e2e=1'));
      expect((await carried(page)) === 'nothing', `the carry said ${await carried(page)}`);
      const took = Date.now() - began;
      log(`      asked and answered: ${took} ms`);
      expect(took < 1500, `the answer took ${took} ms, as long as giving up`);
      expect(JSON.parse(await stored(page, 'oh.carried')).entries === 0, 'the carry is not marked done');
      await waitFor(page, ready, { what: 'the app', timeout: 60000 });
      await until('a key of its own', () => stored(page, 'flutter.identity_secret'));
    },
  },
  {
    name: 'an old address that never answers holds the app up for a moment only',
    async run({ app, newContext }) {
      const context = await newContext();
      // The carry page answers nothing at all.
      await context.route('**/carry', (route) => route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>silent</title>' }));
      const page = await context.newPage();
      const began = Date.now();
      await page.goto(app.at('/?e2e=1'));
      expect((await carried(page)) === 'timed out', `the carry said ${await carried(page)}`);
      const took = Date.now() - began;
      log(`      gave up after: ${took} ms`);
      expect(took < 4000, `the app was held up ${took} ms`);
      expect((await stored(page, 'oh.carried')) === null, 'a carry that never happened is marked done');
      await waitFor(page, ready, { what: 'the app', timeout: 60000 });
    },
  },
  {
    name: 'a preview serves the app at /play/ and sends nobody to production',
    async run({ app, newContext }) {
      const context = await newContext();
      const page = await context.newPage();
      await page.goto(app.at(`${app.preview}/play/room/ABCD2345?e2e=1`));
      await waitFor(page, ready, { what: 'the app on a preview', timeout: 60000 });
      const at = new URL(page.url());
      expect(at.origin === app.preview && at.pathname === '/play/room/ABCD2345', `the preview went to ${page.url()}`);
      expect((await page.evaluate(() => document.baseURI)) === `${app.preview}/play/`, 'the base is not /play/');
      expect((await carried(page)) === 'not here', `the carry said ${await carried(page)}`);
      // The site's Play now is this preview's own app, in its language.
      const site = await context.newPage();
      await site.goto(`${app.preview}/`);
      const play = await site.getAttribute('a.cta.play', 'href');
      expect(play === `${app.preview}/play/?lang=en`, `Play now is ${play}`);
    },
  },
  {
    name: "the site's Play now opens the app at its own host, in the site's language",
    async run({ app, newContext }) {
      const context = await newContext({ locale: 'de-DE' });
      const page = await context.newPage();
      await page.goto(`${app.site}/de/`);
      await page.click('a.cta.play');
      await until('the app', async () => new URL(page.url()).host === new URL(app.url).host);
      expect(new URL(page.url()).searchParams.get('lang') === 'de', `the app was opened at ${page.url()}`);
    },
  },
];

async function main() {
  const only = argOf('only');
  const relay = await startRelay();
  const app = await serveApp({ relayPort: relay.port });
  const browser = await chromium.launch();
  let failed = 0;
  for (const { name, run } of flows) {
    if (only && !name.includes(only)) continue;
    const contexts = [];
    const newContext = async (options = {}) => {
      const ctx = await browser.newContext({ viewport: phone, locale: 'en-US', hasTouch: true, isMobile: true, ...options });
      contexts.push(ctx);
      return ctx;
    };
    const began = Date.now();
    try {
      await run({ app, newContext });
      log(`ok    ${name} (${((Date.now() - began) / 1000).toFixed(0)}s)`);
    } catch (e) {
      failed++;
      log(`FAIL  ${name}: ${e.message}`);
    }
    for (const ctx of contexts) await ctx.close();
  }
  await browser.close();
  app.stop();
  relay.stop();
  log(failed ? `FAIL: ${failed} flow${failed === 1 ? '' : 's'}` : 'PASS');
  process.exit(failed ? 1 : 0);
}

main();
