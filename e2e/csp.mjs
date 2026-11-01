// The app under the Content-Security-Policy production serves it with.
//
//   node e2e/csp.mjs                    # from the repo root
//   node e2e/csp.mjs --app-dir <path>   # another build, made with Apple's Services ID
//
// The rig serves the app with the headers site/public/_headers gives it
// (drive.mjs, serveApp; site/headers.mjs), so this loads the real build
// under the real policy and holds that nothing it does is refused: not
// a script, not a worker, not WebAssembly, not the part of New Relic's
// agent its loader fetches, not Apple's sign-in script. A refusal is a
// `securitypolicyviolation` event in the page, or the browser's console
// line for one. A refusal inside a worker is told to neither, so a
// worker is held by what it does: the deal's is started by a hand
// dealt, and the review's is started here and asked for a verdict.
//
// And the other way: a policy that was never in force, or that let
// everything by, would hold nothing, so the last flow makes the page
// try what it is there to refuse, and sees each one refused.
//
// The build is the suites' own with one flag more, Apple's Services ID
// (config/openhearts.json, apple.servicesId), so that a sign-in button
// is on the Subscription page and the page fetches Apple's script. It
// is made here, in app/build/e2e-signin, when it is not there already
// (build.sh --out); the suites' own is not touched.
//
// Nothing leaves this machine: a request for a host that is not the
// rig's is answered here or refused. Apple's script is answered with a
// line that says it ran, and New Relic's part with a refusal once it has
// been asked for, so what either does after it is loaded is not seen
// here: only that the page is let ask, and let run what it is given.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { headersFor, parseHeaders } from '../site/headers.mjs';
import { chromium } from './browser.mjs';

const here = resolve(fileURLToPath(new URL('.', import.meta.url)));
const root = resolve(here, '..');
const config = JSON.parse(readFileSync(join(root, 'config', 'openhearts.json'), 'utf8'));
const servicesId = config.apple?.servicesId;
if (!servicesId) throw new Error('config/openhearts.json names no apple.servicesId: there would be no sign-in button to hold the policy to');

// The build this drives, made if it is not there. The rig takes the
// directory from the arguments as it loads (drive.mjs, appDir), so
// they are settled before it is.
if (!process.argv.some((a) => a === '--app-dir' || a.startsWith('--app-dir='))) {
  execFileSync(join(here, 'build.sh'), ['--out', 'build/e2e-signin', `--dart-define=OH_APPLE_SERVICE_ID=${servicesId}`], { stdio: 'inherit' });
  process.argv.push('--app-dir', join(root, 'app', 'build', 'e2e-signin'));
}
const { agreedToTerms, click, licensed, log, serveApp, sleep, waitFor } = await import('./drive.mjs');

/// What production sends with the app's front page, and so with every
/// file of the app: _headers as it is committed.
const policy = headersFor(parseHeaders(readFileSync(join(root, 'site', 'public', '_headers'), 'utf8')), '/play/')['content-security-policy'];
// The flows below hold the app to this, and would hold it to nothing if
// it said nothing about scripts.
for (const directive of ['script-src', 'worker-src']) {
  if (!policy?.includes(`${directive} `)) throw new Error(`site/public/_headers gives the app no ${directive} (it gives it ${policy ?? 'no Content-Security-Policy'})`);
}

const phone = { width: 390, height: 844 };

/// Whether a console line is the browser telling of a refusal.
const refusal = /content security policy|refused to (load|execute|create|connect|apply|evaluate)|violates the following/i;

const expect = (ok, what) => {
  if (!ok) throw new Error(what);
};

async function until(what, check, { timeout = 30000 } = {}) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(200);
  }
}

/// Every `refused` below, for a flow that failed to say what it was
/// refused when it did: a page that is refused something it needs does
/// not come up, and what it waits for is then all a flow can say.
const watched = [];

/// A page of the app in a fresh context of [browser], watched: for a
/// refusal by the policy (`refused`, which grows) and for what the app
/// is served with (`files`). A request for a host that is not [origin]
/// or this machine is answered by the first of [stubs] whose pattern
/// (by URL) it matches, as a function of the route, and otherwise
/// refused.
async function open(browser, { origin, stubs = {} }) {
  const context = await browser.newContext({ viewport: phone, locale: 'en-US', hasTouch: true, isMobile: true });
  await agreedToTerms(context);
  const refused = [];
  watched.push(refused);
  await context.exposeBinding('ohRefused', (_source, what) => void refused.push(`event: ${what}`));
  await context.addInitScript(() => {
    addEventListener('securitypolicyviolation', (e) => window.ohRefused(`${e.violatedDirective}: ${e.blockedURI || 'inline'}`), true);
  });
  await context.route(
    (url) => url.origin !== origin && !/^(localhost|127\.0\.0\.1|.*\.localhost)$/.test(url.hostname),
    (route) => {
      const url = route.request().url();
      const stub = Object.entries(stubs).find(([pattern]) => new RegExp(pattern).test(url));
      return stub ? stub[1](route, url) : route.abort();
    },
  );
  const page = await context.newPage();
  page.on('console', (message) => {
    if (refusal.test(message.text())) refused.push(`console: ${message.text().slice(0, 240)}`);
  });
  page.on('pageerror', (e) => log(`page error: ${e.message}`));
  const files = [];
  page.on('response', (r) => {
    const url = new URL(r.url());
    if (url.origin === origin && !url.pathname.startsWith('/api/')) files.push({ path: url.pathname, policy: r.headers()['content-security-policy'] });
  });
  return { context, page, refused, files };
}

/// That the app was served with the policy production sends, every file
/// of it, and that [needed] files were among them: a check that saw
/// nothing would hold nothing.
function servedWithPolicy(files, needed) {
  const bare = files.filter((f) => f.policy !== policy);
  expect(bare.length === 0, `served without the policy production sends:\n  ${bare.map((f) => `${f.path} (${f.policy ?? 'none'})`).join('\n  ')}`);
  for (const path of needed) expect(files.some((f) => f.path === path), `${path} was not served, so not seen to carry the policy (saw ${files.map((f) => f.path).join(' ')})`);
}

const noRefusals = (refused) => expect(refused.length === 0, `refused by the policy:\n  ${refused.join('\n  ')}`);

const flows = [
  {
    name: 'the front door and a hand dealt: nothing is refused, and every file carries the policy',
    async run({ app, browser }) {
      const { context, page, refused, files } = await open(browser, { origin: app.url });
      await page.goto(app.at('/?e2e=1'));
      await licensed(page);
      // The offline worker, which the page registers once its first
      // frame is up (app/web/flutter_bootstrap.js): the app's own file.
      const worker = await until('the offline worker', () => page.evaluate(() => navigator.serviceWorker.ready.then((r) => r.active?.scriptURL ?? null)), { timeout: 60000 });
      expect(worker.endsWith('/offline_worker.js'), `the service worker is ${worker}`);
      // A hand dealt: the deal's worker, started from a blob
      // (packages/deal/lib/src/worker_web.dart), is in that, and
      // WebAssembly with it.
      await click(page, /^Play solo$/);
      await waitFor(page, /^Choose 3 more to pass$/, { what: 'a hand dealt' });
      const blobs = page.workers().filter((w) => w.url().startsWith('blob:'));
      expect(blobs.length > 0, `no worker was started from a blob (saw ${page.workers().map((w) => w.url()).join(' ') || 'none'})`);

      // The files a worker is made from carry the policy as well: the
      // header is what a worker started from one runs under. These two
      // are not fetched by this page in a hand dealt, so they are asked for.
      await page.evaluate(() => Promise.all(['/offline_worker.js', '/review_worker.js'].map((path) => fetch(path))));
      // And the review's worker, a file of the app's own with
      // WebAssembly of its own to compile (app/worker/review_worker.dart),
      // run as the app runs it, with nothing to check: it answers that
      // the game does not hold, when it has loaded its wasm, and with
      // an error when it has not. A refusal inside a worker is not
      // something the page is told of, so it is read from what the
      // worker does.
      const reviewed = await page.evaluate(
        () =>
          new Promise((resolve) => {
            const w = new Worker('review_worker.js');
            w.onmessage = (e) => resolve(String(e.data));
            w.onerror = (e) => resolve(`did not run: ${e.message}`);
            w.postMessage({ record: '', service: '', house: '' });
          }),
      );
      expect(/^\{"done":/.test(reviewed), `the review's worker said ${reviewed.slice(0, 300)}`);
      // And the reader of QR codes a browser without its own is given,
      // which the scanner inserts as a script of its own when a camera
      // is first asked for (app/lib/ui/scan_setup_web.dart).
      await page.evaluate(
        () =>
          new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = 'zxing/zxing-library-0.23.0.min.js';
            script.onload = resolve;
            script.onerror = () => reject(new Error('the QR reader did not load'));
            document.head.append(script);
          }),
      );
      expect((await page.evaluate('typeof ZXing')) !== 'undefined', 'the QR reader loaded and defined nothing');

      servedWithPolicy(files, [
        '/',
        '/main.dart.js',
        '/flutter_bootstrap.js',
        '/observability.js',
        '/deal_worker.js',
        '/deal.wasm',
        '/schnorr.wasm',
        '/offline_worker.js',
        '/review_worker.js',
      ]);
      noRefusals(refused);
      await context.close();
    },
  },
  {
    name: "a sign-in button on the screen, and Apple's script fetched for it: nothing is refused",
    async run({ app, browser }) {
      const apple = [];
      const { context, page, refused } = await open(browser, {
        origin: app.url,
        stubs: {
          // One line that says it ran.
          '^https://appleid\\.cdn-apple\\.com/': (route, url) => {
            apple.push(url);
            return route.fulfill({ status: 200, contentType: 'text/javascript', body: 'window.ohAppleScriptRan = true;' });
          },
        },
      });
      await page.goto(app.at('/?e2e=1'));
      await licensed(page);
      expect(apple.length === 0, `Apple's script was fetched at the front door: ${apple.join(' ')}`);
      await click(page, /^Menu$/);
      await waitFor(page, /^Subscription$/, { what: 'the menu' });
      await click(page, /^Subscription$/);
      await waitFor(page, /^Sign in with Apple$/, { what: "Apple's sign-in button" });
      await until("Apple's script to run", () => page.evaluate('window.ohAppleScriptRan === true'));
      expect(apple.length === 1 && /\/appleid\.auth\.js$/.test(apple[0]), `Apple's script was fetched as ${apple.join(' ') || 'nothing'}`);
      noRefusals(refused);
      await context.close();
    },
  },
  {
    name: "New Relic's agent, as it loads on play.openhearts.game: its part is asked for, and nothing is refused",
    // The loader (app/web/observability.js) does nothing on any other host,
    // so this is the app served under production's own name: the browser
    // is told that name is this machine, and every other name is nowhere.
    async run({ app, launch }) {
      const origin = `http://play.openhearts.game:${new URL(app.url).port}`;
      const browser = await launch(['--host-resolver-rules=MAP play.openhearts.game 127.0.0.1, MAP * ~NOTFOUND , EXCLUDE 127.0.0.1']);
      try {
        const asked = [];
        const { page, refused, files } = await open(browser, {
          origin,
          stubs: {
            // Asked for, and then refused: the agent's own code is New
            // Relic's, and is not run here.
            '^https://js-agent\\.newrelic\\.com/': (route, url) => {
              asked.push(url);
              return route.abort();
            },
          },
        });
        await page.goto(`${origin}/`);
        expect((await page.evaluate('location.hostname')) === 'play.openhearts.game', "the page is not at production's name");
        const part = await until("the agent's part to be asked for", () => asked[0]);
        expect(/^https:\/\/js-agent\.newrelic\.com\/nr-full-[\d.]+\.min\.js$/.test(part), `the agent asked for ${part}`);
        // And the app is up under it, at the front door. It is not a
        // driven build there (app/lib/net/address.dart, driven), so the
        // tree of what is on the screen is asked for.
        await until('the app to start', () => page.evaluate('!!document.querySelector("flt-semantics-placeholder")'), { timeout: 60000 });
        await page.evaluate('document.querySelector("flt-semantics-placeholder").click()');
        await waitFor(page, /^Play solo$/, { what: 'the front door', timeout: 60000 });
        servedWithPolicy(files, ['/', '/main.dart.js', '/observability.js']);
        noRefusals(refused);
      } finally {
        await browser.close();
      }
    },
  },
  {
    name: 'what the policy is there to refuse, it refuses',
    async run({ app, browser }) {
      const { context, page, refused } = await open(browser, { origin: app.url });
      // A script of the app's own origin that does what the address asks
      // of it (?run=). The page's own scripts are allowed, and are what
      // eval is looked for from: code the tool that drives the browser
      // hands it is exempt from the policy, and would show nothing.
      await context.route(`${app.url}/csp-probe.js*`, (route) =>
        route.fulfill({ status: 200, contentType: 'text/javascript', body: new URL(route.request().url()).searchParams.get('run') }));
      const probe = (run) =>
        `const s = document.createElement('script'); s.src = '/csp-probe.js?run=' + encodeURIComponent(${JSON.stringify(run)}); document.head.append(s)`;
      await page.goto(app.at('/?e2e=1'));
      await licensed(page);
      noRefusals(refused);
      // Each is something a script that got into the page might do. The
      // refusal is looked for by what it names, so that one seen for
      // another try does not stand in for it.
      const tries = [
        ['a script from another origin', "const s = document.createElement('script'); s.src = 'https://evil.example/x.js'; document.head.append(s)", /script-src-elem: https:\/\/evil\.example/],
        ["a script from Google's sign-in, which this build does not offer", "const s = document.createElement('script'); s.src = 'https://accounts.google.com/gsi/client'; document.head.append(s)", /script-src-elem: https:\/\/accounts\.google\.com/],
        ['an inline script', "const s = document.createElement('script'); s.textContent = 'window.ranInline = true'; document.head.append(s)", /script-src-elem: inline/],
        ['a script from a blob', "const s = document.createElement('script'); s.src = URL.createObjectURL(new Blob(['window.ranBlob = true'])); document.head.append(s)", /script-src-elem: blob/],
        ['eval', probe("try { eval('1') } catch {}"), /script-src: eval/],
        ['new Function', probe("try { new Function('return 1') } catch {}"), /script-src: eval/],
        ['a timer given a string', probe("setTimeout('window.ranTimer = true', 0)"), /script-src: eval/],
        ['a worker from a data URL', "new Worker('data:text/javascript,1')", /worker-src: data/],
      ];
      for (const [what, code, expected] of tries) {
        refused.length = 0;
        await page.evaluate(code);
        await until(`${what} to be refused`, () => refused.some((r) => r.startsWith('event: ') && expected.test(r)), { timeout: 5000 }).catch(() => {
          throw new Error(`${what} was not refused (saw ${refused.join(' ; ') || 'nothing'})`);
        });
      }
      await sleep(300);
      const ran = await page.evaluate('[window.ranInline, window.ranBlob, window.ranTimer].filter(Boolean).length');
      expect(ran === 0, 'a script the policy refused ran');
      await context.close();
    },
  },
];

async function main() {
  const app = await serveApp();
  const launch = (args = []) => chromium.launch({ args });
  const browser = await launch();
  let failed = 0;
  for (const { name, run } of flows) {
    const began = Date.now();
    watched.length = 0;
    try {
      await run({ app, browser, launch });
      log(`ok    ${name} (${((Date.now() - began) / 1000).toFixed(0)}s)`);
    } catch (e) {
      failed++;
      const refused = watched.flat();
      log(`FAIL  ${name}: ${e.message}${refused.length && !e.message.includes('refused by the policy') ? `\n  refused by the policy meanwhile:\n  ${refused.join('\n  ')}` : ''}`);
    }
  }
  await browser.close();
  app.stop();
  log(failed ? `FAIL: ${failed} flow${failed === 1 ? '' : 's'}` : 'PASS');
  process.exit(failed ? 1 : 0);
}

main();
