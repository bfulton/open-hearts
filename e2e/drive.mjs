// Driving the built app in a browser: the relay, the static server, and
// the app's own accessibility tree as the way in.
//
// The tree is how every e2e suite here presses things, because it is
// the app's own account of what is on screen and what can be pressed.
// It is not the whole story: a click on a semantics node never touches
// Flutter's hit test, so a suite that only ever clicks them cannot see
// a tap landing in the wrong place. `tapAt` in flows.mjs is the other
// half.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { createWriteStream, mkdirSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
// The e2e tools take arguments, not environment: --app-dir <path>
// points at a built app other than the default.
export const argOf = (name) => {
  const flag = `--${name}`;
  const i = process.argv.indexOf(flag);
  if (i >= 0 && process.argv[i + 1] !== undefined) return process.argv[i + 1];
  const eq = process.argv.find((a) => a.startsWith(`${flag}=`));
  return eq === undefined ? undefined : eq.slice(flag.length + 1);
};
export const appDir = argOf('app-dir') ?? join(root, 'app', 'build', 'e2e');
export const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- the relay and the app ----------------------------------------------

export async function startRelay() {
  // The relay; and beside it, its own process, the juror of last
  // resort: the four browsers are all at one table, so a jury can only
  // come from the service. Its own process, because a relay verifies
  // every event it carries and must never wait on a juror's work.
  // The relay's whole log, always, at a known path for a debugging run.
  const logFile = join(root, 'app', 'build', 'logs', 'relay.log');
  mkdirSync(dirname(logFile), { recursive: true });
  const relayLog = createWriteStream(logFile);
  const args = ['run', 'bin/service.dart', '--port', '7447'];
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

/// The service's handlers in local mode (docs/06-service.md): the same
/// worker the site runs, over a Map instead of a key-value store, with
/// the open house on — a device that asks is licensed for a month, so
/// the suite plays live without a shop to buy from. The service's own
/// key is BIP-340's published pair, and the app is built to expect it.
export const localService = {
  key: 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659',
  secret: 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef',
};

async function handlersFor(serve) {
  const { default: handler, memoryStore } = await import(new URL('../service/functions/worker.mjs', import.meta.url));
  const store = memoryStore();
  const env = {
    OH_SERVICE_SECRET: localService.secret,
    OH_SERVICE_KEY: localService.key,
    OH_OPEN_HOUSE: '1',
    OH_STORE: {
      get: async (at, kind) => {
        const [pk, sk] = at.split('|');
        const row = await store.get(pk, sk);
        return kind === 'json' ? row : row === null ? null : JSON.stringify(row);
      },
      put: async (at, raw) => {
        const [pk, sk] = at.split('|');
        await store.put(pk, sk, JSON.parse(raw));
      },
      list: async ({ prefix }) => ({ keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }),
    },
    ASSETS: { fetch: serve },
  };
  return (request) => handler.fetch(request, env);
}

export async function serveApp() {
  // Static files as a fetch, which is what the worker's own ASSETS
  // binding is: the handlers reach the app's wasm through it exactly
  // as they do on the site.
  const asset = async (request) => {
    const path = decodeURIComponent(new URL(request.url ?? request).pathname);
    // The app is served at the root here and at /play/ on the site;
    // the worker asks for its wasm by the site's path.
    const file = join(appDir, (path.startsWith('/play/') ? path.slice(5) : path) === '/' ? 'index.html' : path.startsWith('/play/') ? path.slice(5) : path);
    try {
      const body = await readFile(file);
      return new Response(body, { status: 200, headers: { 'content-type': types[extname(file)] ?? 'application/octet-stream' } });
    } catch {
      return new Response(null, { status: 404 });
    }
  };
  const handlers = await handlersFor(asset);
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host ?? '127.0.0.1'}`);
    if (url.pathname.startsWith('/api/')) {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const answer = await handlers(
        new Request(url, {
          method: req.method,
          headers: req.headers,
          ...(chunks.length ? { body: Buffer.concat(chunks) } : {}),
        }),
      );
      res.writeHead(answer.status, Object.fromEntries(answer.headers));
      res.end(Buffer.from(await answer.arrayBuffer()));
      return;
    }
    const answer = await asset(url);
    if (!answer.ok) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { 'content-type': answer.headers.get('content-type'), 'cache-control': 'no-store' });
    res.end(Buffer.from(await answer.arrayBuffer()));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}`, stop: () => server.close() };
}

// ---- driving the app through its accessibility tree ----------------------

/// A semantics node's own label: its aria-label, or its own text and
/// that of plain child elements — never the text of nested nodes, or
/// every container would carry its children's names too.
export const labelOf = `(e) => e.getAttribute('aria-label') || [...e.childNodes]
  .filter((n) => n.nodeType === 3 || (n.nodeType === 1 && n.tagName.toLowerCase() !== 'flt-semantics'))
  .map((n) => n.textContent).join('').trim()`;

/// Every label in the semantics tree, as the app exposes it.
export const texts = (page) => page.evaluate(`[...document.querySelectorAll('flt-semantics')].map(${labelOf}).filter(Boolean)`);

export async function has(page, re) {
  return (await texts(page)).some((t) => re.test(t));
}

export async function waitFor(page, re, { timeout = 30000, what = String(re) } = {}) {
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
export async function dismiss(page, re) {
  try {
    await click(page, re);
  } catch (e) {
    if (!String(e.message).startsWith('nothing to click')) throw e;
  }
}

/// Clicks the first semantics node whose label or text matches.
export async function click(page, re) {
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
export async function type(page, label, value) {
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

export const cardName = /^(2|3|4|5|6|7|8|9|10|jack|queen|king|ace) of (clubs|diamonds|spades|hearts)$/;

/// One step of play for a page, if it has something to do. Returns what it did.
export async function act(page) {
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
export async function playUntil(pages, done, { timeout = 120000, idle = [] } = {}) {
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

