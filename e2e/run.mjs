// Four real browsers at one table.
//
//   cd app && flutter build web -o build/e2e --base-href / --no-web-resources-cdn
//   node e2e/run.mjs            # from the repo root; needs the global Playwright
//
// Against a public relay instead: build the app with
// `--dart-define=DEV_RELAY=wss://relay.damus.io` and run with
// `RELAY_URL=wss://relay.damus.io`, so the suite starts no relay of its
// own. The app's relays are the build's, never typed in (app/lib/net/
// relays.dart); served from localhost it looks for the local relay at
// its usual port, which is where the suite starts one.
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
import { createWriteStream } from 'node:fs';
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
  // The relay; and beside it, its own process, the juror of last
  // resort: the four browsers are all at one table, so a jury can only
  // come from the service. Its own process, because a relay verifies
  // every event it carries and must never wait on a juror's work.
  // RELAY_LOG=path keeps the relay's whole log for a debugging run.
  const relayLog = process.env.RELAY_LOG ? createWriteStream(process.env.RELAY_LOG) : null;
  const args = ['run', 'bin/service.dart', '--port', '7447', ...(relayLog ? [] : ['--quiet'])];
  const proc = spawn('dart', args, { cwd: join(root, 'service') });
  let juror = null;
  const url = await new Promise((resolveUrl, reject) => {
    let out = '';
    proc.stdout.on('data', (d) => {
      out += d.toString();
      const m = out.match(/relay (ws:\/\/\S+)/);
      if (m) resolveUrl(m[1]);
      // The juror of last resort's own lines, once the relay is up.
      if (relayLog) relayLog.write(d);
      if (m && !juror) {
        juror = spawn('dart', ['run', 'bin/juror.dart', '--relay', m[1]], { cwd: join(root, 'service') });
        // Its whole log goes with the relay's, for a debugging run.
        juror.stdout.on('data', (d) => { if (relayLog) relayLog.write(d); for (const line of d.toString().split('\n')) if (/juror|summoned|called|verdict|done with/.test(line)) log(`juror: ${line.trim()}`); });
        juror.stderr.on('data', (d) => process.stderr.write(d));
      }
    });
    proc.stderr.on('data', (d) => process.stderr.write(d));
    proc.on('exit', (code) => reject(new Error(`relay exited ${code}\n${out}`)));
    setTimeout(() => reject(new Error('relay did not start')), 60000);
  });
  return { url, stop: () => { juror?.kill(); proc.kill(); } };
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

/// Clicks the first semantics node whose label or text matches, if
/// there is one: for a thing that goes on its own — the score sheet,
/// a few seconds after a hand — and may be gone by the time it is
/// reached.
async function dismiss(page, re) {
  try {
    await click(page, re);
  } catch (e) {
    if (!String(e.message).startsWith('nothing to click')) throw e;
  }
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
    // As many cards as the note still asks for, among those not yet
    // selected; then the button, on a later poll, once the selection
    // shows and it is enabled. A tap on a freshly built node can be
    // dropped, and a second tap on a chosen card would unchoose it.
    const asked = seen.map((t) => /^Choose (\d) more to pass$/.exec(t)).find(Boolean);
    const want = asked ? Number(asked[1]) : 0;
    if (want > 0) {
      const picked = await page.evaluate(`((src, want) => {
        const labelOf = ${labelOf};
        const re = new RegExp(src);
        let n = 0;
        for (const e of document.querySelectorAll('flt-semantics')) {
          if (e.getAttribute('role') !== 'button') continue; // the passed-you chips carry card names too
          if (e.getAttribute('aria-selected') === 'true') continue;
          if (re.test(labelOf(e)) && e.getAttribute('aria-disabled') !== 'true' && n < want) {
            e.click();
            n++;
          }
        }
        return n;
      })(${JSON.stringify(cardName.source)}, ${want})`);
      return picked ? `picked ${picked}` : null;
    }
    const pressed = await page.evaluate(`(() => {
      const labelOf = ${labelOf};
      for (const e of document.querySelectorAll('flt-semantics')) {
        if (labelOf(e) === 'Pass' && e.getAttribute('aria-disabled') !== 'true') {
          e.click();
          return true;
        }
      }
      return false;
    })()`);
    return pressed ? 'passed' : null;
  }
  if (seen.some((t) => /^Your (turn|lead)$/.test(t))) {
    const played = await page.evaluate(`((src) => {
      const labelOf = ${labelOf};
      const re = new RegExp(src);
      for (const e of document.querySelectorAll('flt-semantics')) {
        if (e.getAttribute('role') !== 'button') continue;
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
/// A page counts as done from the first poll that finds it so: the
/// pages pace their own tables, so a state that comes and goes — the
/// hand's score sheet — need not show on every screen at once.
async function playUntil(pages, done, { timeout = 120000, idle = [] } = {}) {
  const until = Date.now() + timeout;
  const finished = new Set();
  while (Date.now() < until) {
    let all = true;
    for (const [i, page] of pages.entries()) {
      if (page.isClosed()) continue;
      if (!idle.includes(i)) await act(page);
      if (!finished.has(i) && (await done(page, i))) finished.add(i);
      if (!finished.has(i)) all = false;
    }
    if (all) return;
    await sleep(300);
  }
  throw new Error(`timed out: ${await Promise.all(pages.filter((p) => !p.isClosed()).map(async (p) => (await texts(p)).join(' | ')))}`);
}

// ---- the scenarios -------------------------------------------------------

const names = ['Ada', 'Bao', 'Cara', 'Dee'];
/// A seat badge that is not one of the four people: a bot took a seat.
const roster = /^(?!Ada:|Bao:|Cara:|Dee:)[A-Z][\w ]+: \d+ in the game, \d+ this hand/;

async function main() {
  // RELAY_URL=wss://… runs the suite against a relay that already
  // exists — a public one the app was built for, say — instead of
  // starting the local one.
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
      page.on('console', (m) => {
        const t = m.text();
        // Errors, and the table's and the duty's own traces about the jury.
        const verbose = process.env.RELAY_LOG ? /^(mesh|relay): / : /$^/;
        if (m.type() === 'error' || verbose.test(t) || /^duty: (?!.*emit )/.test(t) || /^table: .*(jury|juror|verdict|appeal|nobody online|summon)/.test(t)) log(`page ${names[i]}: ${t}`);
      });
      await page.goto(`${app.url}/?e2e=1`);
      contexts.push(ctx);
      pages.push(page);
    }
    // Everyone to the lobby, from the front door.
    for (const [i, page] of pages.entries()) {
      await waitFor(page, /^Play live$/, { what: 'the home screen' });
      await click(page, /^Play live$/);
      await waitFor(page, /^Play with friends$/);
      await type(page, 'Your name', names[i]);
    }
    // Every device is online from the lobby, and each one sees the
    // other three: presence over the relay, before anyone sits down.
    for (const page of pages) await waitFor(page, /^4 online$/, { what: 'everyone online in the lobby', timeout: 40000 });
    log('four online in the lobby');

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
    // Back to the lobby for the rest: leave by the menu, then Play live
    // again from the home screen. The score sheet goes on its own after
    // a few seconds, so it may be gone by the time a page is reached.
    for (const page of pages) {
      await dismiss(page, /^On with it$/);
      await click(page, /^Menu$/);
      await waitFor(page, /^Leave the table$/, { what: 'the menu' });
      await click(page, /^Leave the table$/);
      await waitFor(page, /^Play live$/, { what: 'the home screen again' });
      await click(page, /^Play live$/);
      await waitFor(page, /^Play with friends$/);
    }

    // Ada picks an avatar first: the picker opens from her icon by the
    // name, an icon is chosen, and Done keeps it.
    await click(pages[0], /^Your avatar$/);
    await waitFor(pages[0], /^Rocket$/, { what: 'the avatar picker' });
    await click(pages[0], /^Rocket$/);
    await click(pages[0], /^Done$/);
    await waitFor(pages[0], /^Play with friends$/);
    // Ada goes in with no code, so a new one is drawn: the only
    // four-capital-letter text on her screen. Nobody hosts; whoever
    // is at a code is the table.
    await click(pages[0], /^Play with friends$/);
    await waitFor(pages[0], /^Read the code out/, { what: 'the room' });
    const code = (await texts(pages[0])).find((t) => /^[A-Z]{4}$/.test(t));
    if (!code) throw new Error('no room code shown');
    log(`room ${code}`);
    // Bao arrives by the shared link — the app's own address with the
    // code — and, with a name already, lands straight in the room.
    await pages[1].goto(`${app.url}/?e2e=1&room=${code}`);
    await waitFor(pages[1], new RegExp(`^Table ${code}$`), { what: 'the room, by its link', timeout: 60000 });
    for (let i = 2; i < 4; i++) {
      await type(pages[i], 'Room code', code);
      await click(pages[i], /^Play with friends$/);
    }
    // Four in: whoever leads starts on its own.
    for (const page of pages) await waitFor(page, /^4 of 4 here  ·  unrated$/, { what: 'the live table', timeout: 40000 });
    log('all four at the table');

    // Cell 1: a whole hand over WebRTC.
    await playUntil(pages, (p) => has(p, /^On with it$/), { timeout: 180000 });
    log('hand 1 played on every screen');
    // The sheet goes on its own after a few seconds, and the screens
    // reach the end of a hand a few seconds apart, so one may be gone
    // by the time all four have shown it.
    for (const page of pages) {
      await dismiss(page, /^On with it$/);
    }
    for (const page of pages) await waitFor(page, /^Hand 2/, { what: 'hand 2' });

    // Cell 2: Dee's browser goes, mid-hand. The others see three, and a
    // bot in her seat once her turn comes and the silence is answered —
    // two minutes of it.
    await contexts[3].close();
    log('Dee closed her browser');
    const others = pages.slice(0, 3);
    await playUntil(others, (p) => has(p, /^3 of 4 here/), { timeout: 150000 });
    await playUntil(others, async (p) => (await texts(p)).some((t) => roster.test(t)), { timeout: 150000 });
    log('a bot took Dee\'s seat');

    // Cell 3: Cara stops acting. On her turn the clock runs; at fifteen
    // seconds the others get the Boot button, and one press does it.
    await playUntil(others, (p, i) => i === 2 || has(p, /^Boot Cara$/), { timeout: 120000, idle: [2] });
    await click(pages[0], /^Boot Cara$/);
    log('Ada pressed Boot');
    await playUntil([pages[0], pages[1]], (p) => has(p, /^2 of 4 here/), { timeout: 60000 });
    await waitFor(pages[2], /^A bot took your seat$/, { what: "Cara's replacement notice", timeout: 30000 });
    log('Cara booted, and told');

    // Cell 5: two people left, and Bao's browser goes off his turn. Ada
    // alone is no majority of two and claims nothing; her next play
    // waits on a vote that will never come, and the table asks the
    // jury — the service's juror of last resort, called for when this
    // table found nobody else online. It rules once Bao has been
    // silent two minutes: Ada's play stands, and at Bao's own turn his
    // seat goes to a bot. Ada finishes the hand with three bots.
    await contexts[1].close();
    log("Bao's browser closed off his turn");
    await playUntil([pages[0]], (p) => has(p, /^Asking the jury$/), { timeout: 150000 });
    log('Ada is asking the jury');
    await playUntil([pages[0]], (p) => has(p, /^1 of 4 here/), { timeout: 300000 });
    log('the jury ruled; Ada alone with three bots');
    // The hand ends when the header moves on to the next one — a sheet
    // that comes and goes is not the thing to wait for — or the game
    // ends, which a game to fifty can do here.
    const before = (await texts(pages[0])).find((t) => /^Hand \d/.test(t));
    const next = `Hand ${Number(before.match(/^Hand (\d+)/)[1]) + 1}`;
    await playUntil([pages[0]], async (p) => (await has(p, new RegExp(`^${next} `))) || (await has(p, /^Home$/)), { timeout: 180000 });
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
