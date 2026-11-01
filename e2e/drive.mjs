// Driving the built app in a browser: the relay, the static server, and
// the app's own accessibility tree as the way in.
//
// The tree is how every e2e suite here presses things, because it is
// the app's own account of what is on screen and what can be pressed.
// It is not the whole story: a click on a semantics node never touches
// Flutter's hit test, so a suite that only ever clicks them cannot see
// a tap landing in the wrong place. `tapAt` in flows.mjs is the other
// half.
import { AsyncLocalStorage } from 'node:async_hooks';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import { createInterface } from 'node:readline';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { format } from 'node:util';
import { build as buildSite } from '../site/build.mjs';
import { configOf } from '../service/functions/config.mjs';
import { wakePath } from '../service/do/bench.mjs';

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
/// The room an address is in: `/room/ABCD` (app/lib/router.dart), or
/// null.
export const roomIn = (url) => new URL(url).pathname.match(/\/room\/([A-Z0-9]+)$/)?.[1] ?? null;
/// Where a line said with [log] goes: the console, or — for a flow
/// running beside others (pool.mjs) — that flow's own lines, printed
/// together when it ends, so each flow still reads as one story.
export const logTo = new AsyncLocalStorage();
export const log = (...a) => {
  const line = `${new Date().toISOString().slice(11, 19)} ${format(...a)}`;
  const sink = logTo.getStore();
  if (sink) sink(line);
  else console.log(line);
};
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- the relay and the app ----------------------------------------------

/// Which suite this is (flows, run, …), for the names of its logs: two
/// suites on one machine each write their own.
export const suite = basename(process.argv[1] ?? 'e2e', '.mjs');

/// A port nobody on this machine is listening on, for a relay. Each
/// suite's relay has one of its own, and tells its pages so (`?relay=`,
/// app/lib/net/relays.dart), so suites can run side by side. Drawn from
/// below the range Linux hands out for outgoing connections (32768 up),
/// so a browser's own sockets cannot take it between the asking and the
/// relay binding it.
export async function freePort() {
  for (;;) {
    const port = 20000 + Math.floor(Math.random() * 12000);
    const free = await new Promise((resolveFree) => {
      const probe = createTcpServer();
      probe.once('error', () => resolveFree(false));
      probe.listen(port, '127.0.0.1', () => probe.close(() => resolveFree(true)));
    });
    if (free) return port;
  }
}

/// [url] with the rig's relay named in it (`relay=PORT`), and the pace
/// the rig asks for (`pace=`), when it is an address of the rig's and
/// does not name them already: what every page a suite opens is given,
/// so the app finds the suite's own relay.
export function withRelay(url, port, pace = null) {
  const u = new URL(url);
  const local = u.hostname === 'localhost' || u.hostname === '127.0.0.1' || u.hostname.endsWith('.localhost');
  if (!local) return url;
  if (port !== undefined && port !== null && !u.searchParams.has('relay')) u.searchParams.set('relay', String(port));
  if (pace !== null && !u.searchParams.has('pace')) u.searchParams.set('pace', String(pace));
  return u.toString();
}

/// The rig's house (e2e/build.sh): BIP-340's third published pair, a
/// key known to everyone and so to nothing that matters. Every table
/// the rig's build seats names it, and the rig's relay referees sealed
/// tables for it alone.
export const rigHouse = {
  secret: 'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9',
  key: 'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8',
};

/// The house as a program compiled ahead of time, as its container runs
/// it (service/bench/build.sh): made once for whatever service/ and the
/// packages it takes are at, under service/.dart_tool/e2e/<their hash>,
/// and shared by every suite and worker after. Each `dart run` would
/// compile the whole table package again before saying a word. Where
/// the compiler is not to be had, `dart run` as before.
const programs = new Map();
export function serviceProgram(name) {
  if (!programs.has(name)) programs.set(name, compileProgram(name));
  return programs.get(name);
}

async function compileProgram(name) {
  const service = join(root, 'service');
  const hash = createHash('sha1');
  const walk = (dir) => {
    if (!existsSync(dir)) return;
    for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.dart') || e.name.startsWith('pubspec.')) hash.update(p).update(readFileSync(p));
    }
  };
  for (const dir of ['service/bin', 'service/lib', 'packages/engine/lib', 'packages/deal/lib', 'packages/table/lib']) walk(join(root, dir));
  for (const f of ['service/pubspec.yaml', 'service/pubspec.lock']) {
    if (existsSync(join(root, f))) hash.update(f).update(readFileSync(join(root, f)));
  }
  const dir = join(service, '.dart_tool', 'e2e', hash.digest('hex').slice(0, 16));
  const exe = join(dir, name);
  if (existsSync(exe)) return [exe];
  mkdirSync(dir, { recursive: true });
  const tmp = `${exe}.${process.pid}.tmp`;
  const made = await new Promise((done) => {
    const c = spawn('dart', ['compile', 'exe', join('bin', `${name}.dart`), '-o', tmp], { cwd: service, stdio: 'ignore' });
    c.on('exit', (code) => done(code === 0));
    c.on('error', () => done(false));
  });
  if (!made) return ['dart', 'run', join('bin', `${name}.dart`)];
  renameSync(tmp, exe);
  // What older sources made is no use to anybody now.
  for (const old of readdirSync(dirname(dir))) {
    if (join(dirname(dir), old) !== dir) rmSync(join(dirname(dir), old), { recursive: true, force: true });
  }
  return [exe];
}

/// Whether [p] has gone.
const exited = (p) => p.exitCode !== null || p.signalCode !== null;

/// [p] stopped, and gone.
async function stopped(p) {
  if (exited(p)) return;
  const gone = new Promise((r) => p.once('exit', r));
  p.kill();
  await gone;
}

/// The relay on [port] — one of its own unless told — and beside it the
/// house, as the deployment has them: the relay the Cloudflare object
/// runs, on a node socket (service/do/host.mjs), asking every socket
/// who it is by the rig's service and refereeing tables for the rig's
/// house; and the house, started and woken for each table and each pool
/// that wants it, as the object wakes its container
/// (service/do/bench.mjs), and told with every wake the clocks of
/// [config], the operator's remote config the suite's app is served
/// ([serveApp]). Their log is named for [tag] (the suite, and the worker
/// for a suite run side by side), and the house's word on its tables is
/// said through [say]. Its bots think at [pace], the share of every beat
/// the suite's app takes ([serveApp]; service/bin/house.dart, `--pace`).
///
/// `house.stop()` takes the house off the air, as a container that has
/// gone; the next table that wants it starts it again, and it goes on
/// from the log.
export async function startRelay({ port = null, tag = suite, say = log, pace = 1, config = null } = {}) {
  // The whole log of both, always, at a known path for a debugging run.
  // A relay started again under the same tag — a worker's, flow after
  // flow — adds to the log this run began rather than starting it over.
  const logFile = join(root, 'app', 'build', 'logs', `relay-${tag}.log`);
  mkdirSync(dirname(logFile), { recursive: true });
  const relayLog = createWriteStream(logFile, { flags: relayLogs.has(logFile) ? 'a' : 'w' });
  relayLogs.add(logFile);
  port ??= await freePort();
  const house = houseOn(await freePort(), relayLog, say, pace, config);
  const proc = spawn(process.execPath, [join(root, 'service', 'do', 'host.mjs'), '--port', `${port}`, '--object', '--gate', localService.key, '--house', rigHouse.key],
      { cwd: root });
  const url = await new Promise((resolveUrl, reject) => {
    const seen = [];
    createInterface({ input: proc.stdout }).on('line', (line) => {
      relayLog.write(`${line}\n`);
      const at = line.match(/^relay (ws:\/\/\S+)$/);
      if (at) {
        house.relay = `${at[1]}/{tag}`;
        return resolveUrl(at[1]);
      }
      if (seen.length < 50) seen.push(line);
      if (!line.startsWith('{')) return;
      let said;
      try {
        said = JSON.parse(line);
      } catch {
        return;
      }
      // A table that wants its house, and the house not on its log; or a
      // pool somebody waits in, and the house not there.
      if (typeof said.wanted === 'string') house.wake(said.wanted).catch((e) => say(`house: not woken for ${said.wanted.slice(0, 8)}: ${e.message}`));
    });
    proc.stderr.on('data', (d) => process.stderr.write(d));
    proc.on('exit', (code) => reject(new Error(`relay exited ${code}\n${seen.join('\n')}`)));
    setTimeout(() => reject(new Error('relay did not start')), 60000);
  });
  // Stopped, and gone: the port is free again once this resolves, for a
  // relay started on it after.
  const stop = async () => {
    await Promise.all([stopped(proc), house.stop()]);
    relayLog.end();
  };
  return { url, port, house, stop };
}

/// The relay logs this run has written, to add to rather than start over.
const relayLogs = new Set();

/// The house on [port], for the relay its `relay` names: started when a
/// table or a pool first wants it, and again once it has gone, then
/// woken for it, with the clocks of [config] as the bench says the
/// operator's. `said` is every line it has written, for a run that has
/// to check what the house did rather than what a browser could see.
function houseOn(port, relayLog, say, pace, config) {
  let proc = null;
  let up = null;
  const said = [];
  const start = async () => {
    const [cmd, ...args] = await serviceProgram('house');
    const p = spawn(cmd, [...args, '--relay', house.relay, '--port', `${port}`, '--pace', `${pace}`], {
      cwd: join(root, 'service'),
      // The rig's service key, to hold every seat to its licence as a
      // device does (packages/table, licence.dart).
      env: { ...process.env, OH_HOUSE_SECRET: rigHouse.secret, OH_HOUSE_KEY: rigHouse.key, OH_SERVICE_KEY: localService.key },
    });
    proc = p;
    p.stderr.on('data', (d) => process.stderr.write(d));
    await new Promise((resolveUp, reject) => {
      createInterface({ input: p.stdout }).on('line', (line) => {
        relayLog.write(`house: ${line}\n`);
        said.push(line);
        if (/^house: answering on port /.test(line)) resolveUp();
        if (/ (woken|over: )| refused: /.test(line)) say(`house: ${line}`);
      });
      p.on('exit', (code) => reject(new Error(`the house exited ${code}\n${said.join('\n')}`)));
    });
  };
  const house = {
    relay: null,
    said,
    async wake(tag) {
      // One start at a time: two tables that want the house at once
      // wait on the same one, as the container is started once
      // (service/do/bench.mjs). Started again once it has gone.
      if (!up || (proc && exited(proc))) up = start();
      await up;
      const res = await fetch(`http://127.0.0.1:${port}${wakePath(tag)}`, {
        method: 'POST',
        body: JSON.stringify({ timing: configOf(config).table ?? null }),
      });
      if (!res.ok) throw new Error(`the house answered ${res.status}`);
    },
    async stop() {
      if (proc) await stopped(proc);
    },
  };
  return house;
}

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
  '.json': 'application/json', '.png': 'image/png', '.otf': 'font/otf', '.ttf': 'font/ttf', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.frag': 'application/octet-stream', '.symbols': 'text/plain',
};

/// The service's handlers in local mode (docs/explanation/service.md): the same
/// worker the site runs, over a Map instead of a key-value store, with
/// the open house on — a device that asks is licensed for a month, so
/// the suite plays live without a shop to buy from. The service's own
/// key is BIP-340's published pair, and the app is built to expect it.
export const localService = {
  key: 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659',
  secret: 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef',
};

async function handlersFor(serve, records, store, config) {
  const { default: handler } = await import(new URL('../service/functions/worker.mjs', import.meta.url));
  // The operator's remote config (docs/explanation/service.md), where a suite
  // sets one: the row the worker checks and serves at /api/config.
  if (config) await store.put('config', 'app', config);
  const env = {
    OH_SERVICE_SECRET: localService.secret,
    OH_SERVICE_KEY: localService.key,
    // The house the rig's tables name, which a kept game's result is the
    // word of (service/functions/records.mjs, keepRecord).
    OH_HOUSE_KEY: rigHouse.key,
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
      delete: async (at) => {
        const [pk, sk] = at.split('|');
        await store.del(pk, sk);
      },
      list: async ({ prefix }) => ({ keys: [...store.rows.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }),
    },
    ASSETS: { fetch: serve },
    OH_RECORDS: records,
  };
  return (request) => handler.fetch(request, env);
}

/// The kept games' bucket (service/functions/records.mjs), in memory:
/// what the site would keep in R2, custom metadata, etags and listing
/// too. A flow can look at it, or put a game in it to open
/// (`app.records`). One to each rig.
const recordsBucket = () => ({
  kept: new Map(),
  noted: new Map(),
  etags: new Map(),
  written: 0,
  async head(key) {
    return this.kept.has(key) ? { key, etag: this.etags.get(key), customMetadata: this.noted.get(key) } : null;
  },
  async get(key) {
    const body = this.kept.get(key);
    return body ? { body: new Blob([body]).stream(), etag: this.etags.get(key), customMetadata: this.noted.get(key) } : null;
  },
  // As R2 writes: an `onlyIf` that does not hold writes nothing and
  // answers null.
  async put(key, body, options = {}) {
    const { etagMatches, etagDoesNotMatch } = options.onlyIf ?? {};
    const here = this.kept.has(key);
    if (etagMatches !== undefined && (!here || this.etags.get(key) !== etagMatches)) return null;
    if (etagDoesNotMatch !== undefined && here && (etagDoesNotMatch === '*' || this.etags.get(key) === etagDoesNotMatch)) return null;
    this.kept.set(key, Buffer.from(body));
    this.noted.set(key, options.customMetadata);
    this.etags.set(key, `rig-${++this.written}`);
    return { key };
  },
  async list({ prefix, include = [] }) {
    const objects = [...this.kept.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({
      key,
      ...(include.includes('customMetadata') ? { customMetadata: this.noted.get(key) } : {}),
    }));
    return { objects, truncated: false };
  },
});

/// The site and the app, served as the site's Pages project serves them:
/// one directory — the site built in every language at the root, the app
/// at /play/ — behind the site's own worker (service/functions/worker.mjs),
/// which routes by host (docs/explanation/service.md, "Where the app is").
/// Production's hosts have stand-ins here that a browser takes to be
/// this machine, and that are one site to it, as production's are:
///
///   url       http://play.openhearts.localhost:PORT   the app at the root
///   site      http://openhearts.localhost:PORT        the site; nothing
///                                                     of the app, no /api/
///   preview   http://127.0.0.1:PORT                   a preview: the app
///                                                     at /play/
///
/// `legacy(true)` serves the site's host as it was before the app moved
/// (as a preview is served, the app at /play/), for a suite that needs
/// a device made where the app used to be.
///
/// [relayPort] is the rig's relay's, which `app.at` names in an address
/// of the rig's for the app to find it. [pace] is
/// the share of its tables' beats the app is asked to take (`pace=`,
/// app/lib/net/address.dart), which `app.at` names as well; [config] is
/// the operator's remote config, as the handlers serve it.
export async function serveApp({ relayPort = null, pace = null, config = null } = {}) {
  const site = mkdtempSync(join(tmpdir(), 'oh-site-'));
  buildSite(site);
  // Static files as a fetch, which is what the worker's own ASSETS
  // binding is, by Pages' rules: a directory is its index.html, an
  // address with no extension its .html.
  const asset = async (request) => {
    const path = decodeURIComponent(new URL(request.url ?? request).pathname);
    const inApp = path === '/play' || path.startsWith('/play/');
    let file = inApp ? join(appDir, path.slice('/play'.length) || '/') : join(site, path);
    if (file.endsWith('/') || path.endsWith('/')) file = join(file, 'index.html');
    else if (!extname(file)) file += '.html';
    try {
      const body = await readFile(file);
      return new Response(body, { status: 200, headers: { 'content-type': types[extname(file)] ?? 'application/octet-stream' } });
    } catch {
      return new Response(null, { status: 404 });
    }
  };
  const records = recordsBucket();
  // The service's rows, which a flow can write as the operator's tools
  // do (`app.store`).
  const { memoryStore } = await import(new URL('../service/functions/rows.mjs', import.meta.url));
  const store = memoryStore();
  const handlers = await handlersFor(asset, records, store, config);
  let legacy = false;
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host ?? '127.0.0.1'}`);
    // Before the move, the site's host served the app itself at /play/:
    // as a preview does now.
    if (legacy && url.hostname === 'openhearts.localhost') url.hostname = '127.0.0.1';
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const answer = await handlers(
      new Request(url, {
        method: req.method,
        headers: req.headers,
        redirect: 'manual',
        ...(chunks.length ? { body: Buffer.concat(chunks) } : {}),
      }),
    );
    const headers = Object.fromEntries(answer.headers);
    // Nothing static is kept between runs: each build is the one served.
    if (!url.pathname.startsWith('/api/') && !headers['cache-control']) headers['cache-control'] = 'no-store';
    res.writeHead(answer.status, headers);
    res.end(Buffer.from(await answer.arrayBuffer()));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  return {
    url: `http://play.openhearts.localhost:${port}`,
    site: `http://openhearts.localhost:${port}`,
    preview: `http://127.0.0.1:${port}`,
    legacy: (on) => void (legacy = on),
    records,
    store,
    relayPort,
    /// An address of the rig's — a path under the app's host, or a whole
    /// address — with the rig's relay named in it, and its pace.
    at: (url) => withRelay(url.startsWith('/') ? `http://play.openhearts.localhost:${port}${url}` : url, relayPort, pace),
    stop: () => {
      server.close();
      rmSync(site, { recursive: true, force: true });
    },
  };
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

/// The page's picture once two frames in a row are the same: the cards
/// that were moving into place have arrived.
export async function still(page, what) {
  const until = Date.now() + 10000;
  let last = await page.screenshot();
  for (;;) {
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    const now = await page.screenshot();
    if (now.equals(last)) return now;
    if (Date.now() > until) throw new Error(`${what}: the screen did not settle`);
    last = now;
  }
}

/// [context]'s player agreed to the terms of use already, as a device
/// that has played live before has (app/lib/home_page.dart, `_agreed`):
/// every context a suite opens is, so that its flows go straight in.
/// The screen that asks is held by app/test/home_page_test.dart.
export const agreedToTerms = (context) =>
  context.addInitScript(() => localStorage.setItem('flutter.identity_agreed_terms', JSON.stringify('2026-01-01')));

/// Waits for the front door to say this device may play live. The rig
/// licenses every device that asks (localService), and the app asks as
/// it starts and again, a little further apart each time, until the
/// service answers (app/lib/entitlement.dart, keepAsking) — and takes
/// an answer that comes late — so a page on a busy machine is licensed
/// a little later, never not at all.
export async function licensed(page, { timeout = 30000 } = {}) {
  await waitFor(page, /^Play solo$/, { what: 'the front door', timeout: 60000 });
  await waitFor(page, /^Play live/, { what: 'the licence at the front door', timeout });
}

/// Waits for nothing on the screen to match [re] any longer.
export async function waitGone(page, re, { timeout = 30000, what = String(re) } = {}) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    if (!(await has(page, re))) return;
    await sleep(250);
  }
  throw new Error(`timed out waiting for ${what}\nsaw: ${(await texts(page)).join(' | ')}`);
}

/// Whether the node labelled [re] can be pressed: a way in that is
/// being opened is disabled, and one that has given up is not.
export const pressable = (page, re) =>
  page.evaluate(`((src) => {
    const labelOf = ${labelOf};
    const re = new RegExp(src);
    const e = [...document.querySelectorAll('flt-semantics')].find((e) => re.test(labelOf(e)));
    return !!e && e.getAttribute('aria-disabled') !== 'true';
  })(${JSON.stringify(re.source)})`);

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
          // Chosen already: a chosen card is a button marked current.
          if (e.getAttribute('aria-selected') === 'true' || e.getAttribute('aria-current') === 'true') continue;
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

/// Every node carrying a card's name, as the driver sees it: the label,
/// the role, and whether it is disabled — what act() filters on.
export const cardNodes = (page) =>
  page.evaluate(`((src) => {
    const labelOf = ${labelOf};
    const re = new RegExp(src);
    return [...document.querySelectorAll('flt-semantics')]
      .filter((e) => re.test(labelOf(e)))
      .map((e) => labelOf(e) + ' [role ' + e.getAttribute('role') + ', disabled ' + e.getAttribute('aria-disabled') +
        ', selected ' + e.getAttribute('aria-selected') + ', ' + [...e.attributes].map((a) => a.name).join(' ') + ']');
  })(${JSON.stringify(cardName.source)})`);

/// Plays on every live page until [done] holds on every one of them.
/// A page counts as done from the first poll that finds it so: the
/// pages pace their own tables, so a state that comes and goes — the
/// hand's score sheet — need not show on every screen at once.
export async function playUntil(pages, done, { timeout = 120000, idle = [] } = {}) {
  const until = Date.now() + timeout;
  const finished = new Set();
  // One page's look that throws ends every page's.
  let failed = false;
  const isOver = () => failed || finished.size === pages.length || Date.now() >= until;
  // Each page is looked at on its own, as four people look at their own
  // screens: a page held up — on a busy machine, for seconds at a time —
  // holds up nobody else's turn. Looked at together, a round of all
  // four was as long as the slowest of them, and a player alone with
  // bots, whose turns come one after another, was kept waiting out the
  // others' rounds until her clock ran out.
  //
  // How long each page takes to be looked at again: a state that comes
  // and goes is caught only if that is shorter than the state lasts, so
  // when this times out it is half the answer to why.
  const periods = pages.map(() => []);
  const watch = async (page, i) => {
    while (!isOver()) {
      const round = Date.now();
      if (page.isClosed()) {
        finished.add(i);
        return;
      }
      if (!idle.includes(i)) {
        const did = await act(page);
        // A page that has shown "Your turn" fifteen polls running: what
        // act() did about it this time, and every node carrying a
        // card's name as act() reads them — once, then every thirty
        // polls, so a timeout says why rather than only that.
        const onTurn = await has(page, /^Your (turn|lead)$/);
        page.__onTurn = onTurn ? (page.__onTurn ?? 0) + 1 : 0;
        if (page.__onTurn === 15 || (page.__onTurn > 15 && page.__onTurn % 30 === 0)) {
          log(`page ${i}: "Your turn" ${page.__onTurn} polls running; act() did: ${did ?? 'nothing'}; ` +
            `cards: ${(await cardNodes(page)).join(' | ')}`);
        }
      }
      // A page done goes on playing until every page is: the others'
      // tables may wait on its cards.
      if (!finished.has(i) && (await done(page, i))) finished.add(i);
      if (isOver()) return;
      await sleep(300);
      periods[i].push(Date.now() - round);
    }
  };
  await Promise.all(pages.map(async (page, i) => {
    try {
      await watch(page, i);
    } catch (e) {
      failed = true;
      throw e;
    }
  }));
  if (finished.size === pages.length) return;
  const spread = (ps) => {
    const sorted = [...ps].sort((a, b) => a - b);
    const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))] ?? 0;
    return `${sorted.length} looks, ${at(0)}–${at(0.99)} ms apart (median ${at(0.5)})`;
  };
  throw new Error(
    `timed out with ${finished.size} of ${pages.length} pages caught; each page ${periods.map((ps, i) => `${i}: ${spread(ps)}`).join('; ')}: ` +
      `${await Promise.all(pages.filter((p) => !p.isClosed()).map(async (p) => (await texts(p)).join(' | ')))}`,
  );
}

