// Four real browsers at one table.
//
//   cd app && flutter build web -o build/e2e --base-href / --no-web-resources-cdn
//   node e2e/run.mjs            # from the repo root; needs the global Playwright
//   RELAY_URL=wss://relay.damus.io node e2e/run.mjs   # against a public relay
//
// Starts the local relay and a static server for the built app, opens
// four headless Chromium contexts — four devices, four keys — and
// drives them through the app's accessibility tree: host a table, join
// it, play a hand over real WebRTC, then the departure cells that only
// a real browser can show: one closed mid-hand, one stalled on its
// turn and booted, one that leaves. Exit code is the verdict.

import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const appDir = process.env.APP_DIR ?? join(root, 'app', 'build', 'e2e');
const require = createRequire(import.meta.url);
const { chromium } = require(`${execSync('npm root -g').toString().trim()}/playwright`);

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- the relay and the app ----------------------------------------------

async function startRelay() {
  const proc = spawn('dart', ['run', 'bin/service.dart', '--port', '0', '--quiet'], { cwd: join(root, 'service') });
  const url = await new Promise((resolveUrl, reject) => {
    let out = '';
    proc.stdout.on('data', (d) => {
      out += d.toString();
      const m = out.match(/relay (ws:\/\/\S+)/);
      if (m) resolveUrl(m[1]);
    });
    proc.stderr.on('data', (d) => process.stderr.write(d));
    proc.on('exit', (code) => reject(new Error(`relay exited ${code}\n${out}`)));
    setTimeout(() => reject(new Error('relay did not start')), 60000);
  });
  return { url, stop: () => proc.kill() };
}

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
  '.json': 'application/json', '.png': 'image/png', '.otf': 'font/otf', '.ttf': 'font/ttf', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.frag': 'application/octet-stream', '.symbols': 'text/plain',
};

async function serveApp() {
  const server = createServer(async (req, res) => {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = join(appDir, path === '/' ? 'index.html' : path);
    try {
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}`, stop: () => server.close() };
}

// ---- driving the app through its accessibility tree ----------------------

/// A semantics node's own label: its aria-label, or its own text and
/// that of plain child elements — never the text of nested nodes, or
/// every container would carry its children's names too.
const labelOf = `(e) => e.getAttribute('aria-label') || [...e.childNodes]
  .filter((n) => n.nodeType === 3 || (n.nodeType === 1 && n.tagName.toLowerCase() !== 'flt-semantics'))
  .map((n) => n.textContent).join('').trim()`;

/// Every label in the semantics tree, as the app exposes it.
const texts = (page) => page.evaluate(`[...document.querySelectorAll('flt-semantics')].map(${labelOf}).filter(Boolean)`);

async function has(page, re) {
  return (await texts(page)).some((t) => re.test(t));
}

async function waitFor(page, re, { timeout = 30000, what = String(re) } = {}) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    if (await has(page, re)) return;
    await sleep(250);
  }
  throw new Error(`timed out waiting for ${what}\nsaw: ${(await texts(page)).join(' | ')}`);
}

/// Clicks the first semantics node whose label or text matches.
async function click(page, re) {
  const ok = await page.evaluate(`((src) => {
    const labelOf = ${labelOf};
    const re = new RegExp(src);
    for (const e of document.querySelectorAll('flt-semantics')) {
      if (re.test(labelOf(e)) && e.getAttribute('aria-disabled') !== 'true') {
        e.click();
        return true;
      }
    }
    return false;
  })(${JSON.stringify(re.source)})`);
  if (!ok) throw new Error(`nothing to click for ${re}\nsaw: ${(await texts(page)).join(' | ')}`);
}

/// Types into a field by its label: focus, let the framework attach
/// its editing connection, select everything, and type over it — a
/// plain fill can race the attach and end up appended to the old text.
async function type(page, label, value) {
  const input = page.locator(`flt-semantics[aria-label="${label}"] input, input[aria-label="${label}"]`).first();
  await input.waitFor({ timeout: 15000 });
  await input.click();
  await sleep(300);
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Backspace');
  await page.keyboard.type(value, { delay: 5 });
  await sleep(150);
  const got = await input.inputValue();
  if (got !== value) throw new Error(`typing ${label}: wanted ${JSON.stringify(value)}, field holds ${JSON.stringify(got)}`);
}

const cardName = /^(2|3|4|5|6|7|8|9|10|jack|queen|king|ace) of (clubs|diamonds|spades|hearts)$/;

/// One step of play for a page, if it has something to do. Returns what it did.
async function act(page) {
  const seen = await texts(page);
  if (seen.includes('Pass')) {
    // Three cards, then the button. The first three enabled cards will do.
    const picked = await page.evaluate(`((src) => {
      const labelOf = ${labelOf};
      const re = new RegExp(src);
      let n = 0;
      for (const e of document.querySelectorAll('flt-semantics')) {
        if (re.test(labelOf(e)) && e.getAttribute('aria-disabled') !== 'true' && n < 3) {
          e.click();
          n++;
        }
      }
      return n;
    })(${JSON.stringify(cardName.source)})`);
    if (picked === 3) {
      await sleep(150);
      await click(page, /^Pass$/);
      return 'passed';
    }
    return null;
  }
  if (seen.some((t) => /^Your (turn|lead)$/.test(t))) {
    const played = await page.evaluate(`((src) => {
      const labelOf = ${labelOf};
      const re = new RegExp(src);
      for (const e of document.querySelectorAll('flt-semantics')) {
        const t = labelOf(e);
        if (re.test(t) && e.getAttribute('aria-disabled') !== 'true') {
          e.click();
          return t;
        }
      }
      return null;
    })(${JSON.stringify(cardName.source)})`);
    return played ? `played ${played}` : null;
  }
  return null;
}

/// Plays on every live page until [done] holds on every one of them.
async function playUntil(pages, done, { timeout = 120000, idle = [] } = {}) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    let all = true;
    for (const [i, page] of pages.entries()) {
      if (page.isClosed()) continue;
      if (!idle.includes(i)) await act(page);
      if (!(await done(page, i))) all = false;
    }
    if (all) return;
    await sleep(300);
  }
  throw new Error(`timed out: ${await Promise.all(pages.filter((p) => !p.isClosed()).map(async (p) => (await texts(p)).join(' | ')))}`);
}

// ---- the scenarios -------------------------------------------------------

const names = ['Ada', 'Bao', 'Cara', 'Dee'];
const roster = /^(Westley|Buttercup|Romeo|Juliet|Cyrano|Roxane|Casanova|Don Juan)$/;

async function main() {
  // RELAY_URL=wss://… runs the suite against a relay that already
  // exists — a public one, say — instead of starting the local one.
  const relay = process.env.RELAY_URL ? { url: process.env.RELAY_URL, stop() {} } : await startRelay();
  const app = await serveApp();
  log(`relay ${relay.url}, app ${app.url}`);
  const browser = await chromium.launch();
  const contexts = [];
  const pages = [];
  let failed = false;
  try {
    for (let i = 0; i < 4; i++) {
      const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'en-US' });
      const page = await ctx.newPage();
      page.on('pageerror', (e) => log(`page ${names[i]} error: ${e.message}\n${(e.stack || '').slice(0, 600)}`));
      page.on('console', (m) => { if (m.type() === 'error') log(`page ${names[i]}: ${m.text()}`); });
      await page.goto(`${app.url}/?e2e=1`);
      contexts.push(ctx);
      pages.push(page);
    }
    // Everyone to the lobby.
    for (const [i, page] of pages.entries()) {
      await waitFor(page, /^Play live$/, { what: 'the solo table' });
      await click(page, /^Play live$/);
      await waitFor(page, /^Host a table$/);
      await type(page, 'Relay', relay.url);
      await type(page, 'Your name', names[i]);
    }

    // Cell 0: matchmaking. Three ask for an unrated game and are seated
    // together with a bot at the round after ten seconds; the fourth,
    // alone in the rated pool, gets three bots.
    for (const page of pages.slice(0, 3)) await click(page, /^Unrated$/);
    await click(pages[3], /^Rated$/);
    for (const page of pages) await waitFor(page, /^Finding players$/);
    for (const page of pages.slice(0, 3)) await waitFor(page, /^3 of 3 here  ·  unrated$/, { what: 'the unrated table', timeout: 40000 });
    await waitFor(pages[3], /^1 of 1 here  ·  rated$/, { what: 'the rated table', timeout: 40000 });
    log('matched: three together, one with bots');
    await playUntil(pages, (p) => has(p, /^On with it$/), { timeout: 180000 });
    log('a matched hand played on every screen');
    // Back to the lobby for the rest: Leave, then Play live again. The
    // score sheet goes on its own after a few seconds, so it may be
    // gone by the time a page is reached.
    for (const page of pages) {
      if (await has(page, /^On with it$/)) await click(page, /^On with it$/);
      await click(page, /^Leave$/);
      await waitFor(page, /^Play live$/, { what: 'the solo table again' });
      await click(page, /^Play live$/);
      await waitFor(page, /^Host a table$/);
      await type(page, 'Relay', relay.url);
    }

    // Ada hosts; the code is the only four-capital-letter text on her screen.
    await click(pages[0], /^Host a table$/);
    await waitFor(pages[0], /^Read the code out/, { what: 'the room' });
    const code = (await texts(pages[0])).find((t) => /^[A-Z]{4}$/.test(t));
    if (!code) throw new Error('no room code shown');
    log(`room ${code}`);
    for (let i = 1; i < 4; i++) {
      await type(pages[i], 'Room code', code);
      await click(pages[i], /^Join$/);
    }
    // Four in: the host starts on its own.
    for (const page of pages) await waitFor(page, /^4 of 4 here  ·  unrated$/, { what: 'the live table', timeout: 40000 });
    log('all four at the table');

    // Cell 1: a whole hand over WebRTC.
    await playUntil(pages, (p) => has(p, /^On with it$/), { timeout: 180000 });
    log('hand 1 played on every screen');
    for (const page of pages) await click(page, /^On with it$/);
    for (const page of pages) await waitFor(page, /^Hand 2/, { what: 'hand 2' });

    // Cell 2: Dee's browser goes, mid-hand. The others see three, and a
    // bot in her seat once her turn comes and the silence is answered.
    await contexts[3].close();
    log('Dee closed her browser');
    const others = pages.slice(0, 3);
    await playUntil(others, (p) => has(p, /^3 of 4 here/), { timeout: 90000 });
    await playUntil(others, async (p) => (await texts(p)).some((t) => roster.test(t)), { timeout: 90000 });
    log('a bot took Dee\'s seat');

    // Cell 3: Cara stops acting. On her turn the clock runs; at fifteen
    // seconds the others get the Boot button, and one press does it.
    await playUntil(others, (p, i) => i === 2 || has(p, /^Boot Cara$/), { timeout: 120000, idle: [2] });
    await click(pages[0], /^Boot Cara$/);
    log('Ada pressed Boot');
    await playUntil([pages[0], pages[1]], (p) => has(p, /^2 of 4 here/), { timeout: 60000 });
    await waitFor(pages[2], /^A bot took your seat$/, { what: "Cara's replacement notice", timeout: 30000 });
    log('Cara booted, and told');

    // Cell 4: Bao leaves. Ada plays on with three bots.
    await click(pages[1], /^Leave$/);
    await playUntil([pages[0]], (p) => has(p, /^1 of 4 here/), { timeout: 60000 });
    log('Bao left; Ada alone with three bots');
    const before = (await texts(pages[0])).find((t) => /^Hand \d/.test(t));
    await playUntil([pages[0]], (p) => has(p, /^On with it$/), { timeout: 180000 });
    log(`Ada finished the hand that began as "${before}"`);
    log('PASS');
  } catch (e) {
    failed = true;
    log('FAIL', e.message);
  } finally {
    await browser.close();
    app.stop();
    relay.stop();
  }
  process.exit(failed ? 1 : 0);
}

main();
