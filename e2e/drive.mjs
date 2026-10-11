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
import { spawn, spawnSync } from 'node:child_process';
import { createSocket } from 'node:dgram';
import { createServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { format } from 'node:util';
import { build as buildSite } from '../site/build.mjs';

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

/// The backup jurors, and how they are run.
///
/// A table whose bot seats the jury holds needs juryToHoldBots of
/// them, and here there is nobody else online to make that number up,
/// so every one of them is the service's. Normally it is one process
/// serving all four, which is what the service itself runs.
///
/// `apart` gives each juror a process of its own, for a run that has
/// to take a *single* juror off the air: which of them holds which
/// bot seat is drawn, so the one to silence is not known until the
/// deal says so, and killing a process that held four seats would say
/// nothing about an escrow. It is not the default because it is not
/// free — four Dart VMs against one, on a machine already running
/// four headless browsers, a relay and a server, and four browsers
/// each also serving as a juror for the others' tables. At that load
/// a browser gets starved long enough to be judged silent, its bot
/// seat goes to the escrow, and a run fails at something that is the
/// machine rather than the protocol.
///
/// A secret each, so the keys are the same on every run and a process
/// can be told from its key before either has said a word; each
/// process still prints the key it derived, which is what the suite
/// matches against.
const benchSecrets = [
  '1111111111111111111111111111111111111111111111111111111111111111',
  '2222222222222222222222222222222222222222222222222222222222222222',
  '3333333333333333333333333333333333333333333333333333333333333333',
  '4444444444444444444444444444444444444444444444444444444444444444',
];

/// The relay and the juror as programs compiled ahead of time, as the
/// backup jurors' container runs the juror (service/bench/build.sh): made once
/// for whatever service/ and the packages it takes are at, under
/// service/.dart_tool/e2e/<their hash>, and shared by every suite and
/// worker after. A suite starts four or five of them, and each `dart
/// run` would compile the whole table package again before saying a
/// word. Where the compiler is not to be had, `dart run` as before.
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

/// The relay on [port] — one of its own unless told — its log named for
/// [tag] (the suite, and the worker for a suite run side by side), and
/// the jurors' lines said through [say].
export async function startRelay({ apart = false, port = null, tag = suite, say = log } = {}) {
  // The relay; and beside it, the backup jurors: the four browsers
  // are all at one table, so a jury can only come from the service.
  // Beside rather than inside, because a relay verifies every event it
  // carries and must never wait on a juror's work.
  // The relay's whole log, always, at a known path for a debugging run.
  // A relay started again under the same tag — a worker's, flow after
  // flow — adds to the log this run began rather than starting it over.
  const logFile = join(root, 'app', 'build', 'logs', `relay-${tag}.log`);
  mkdirSync(dirname(logFile), { recursive: true });
  const relayLog = createWriteStream(logFile, { flags: relayLogs.has(logFile) ? 'a' : 'w' });
  relayLogs.add(logFile);
  port ??= await freePort();
  const [relayCmd, ...relayArgs] = await serviceProgram('service');
  const jurorProgram = await serviceProgram('juror');
  const proc = spawn(relayCmd, [...relayArgs, '--port', `${port}`], { cwd: join(root, 'service') });
  const bench = [];
  const url = await new Promise((resolveUrl, reject) => {
    let out = '';
    proc.stdout.on('data', (d) => {
      out += d.toString();
      const m = out.match(/relay (ws:\/\/\S+)/);
      if (m) resolveUrl(m[1]);
      // The jurors of last resort's own lines, once the relay is up.
      if (relayLog) relayLog.write(d);
      if (m && bench.length === 0) {
        if (apart) {
          for (const secret of benchSecrets) bench.push(startJuror(jurorProgram, m[1], secret, relayLog, 1, say));
        } else {
          bench.push(startJuror(jurorProgram, m[1], benchSecrets[0], relayLog, benchSecrets.length, say));
        }
      }
    });
    proc.stderr.on('data', (d) => process.stderr.write(d));
    proc.on('exit', (code) => reject(new Error(`relay exited ${code}\n${out}`)));
    setTimeout(() => reject(new Error('relay did not start')), 60000);
  });
  // Stopped, and gone: the port is free again once this resolves, for a
  // relay started on it after.
  const stop = async () => {
    const gone = (p) => (p.exitCode !== null || p.signalCode !== null ? null : new Promise((r) => p.once('exit', r)));
    const all = [proc, ...bench.map((j) => j.proc)].map(gone);
    for (const j of bench) j.kill();
    proc.kill();
    await Promise.all(all);
    relayLog.end();
  };
  return { url, port, bench, stop };
}

/// The relay logs this run has written, to add to rather than start over.
const relayLogs = new Set();

/// A juror process: `size` jurors served from it, each with a key
/// derived from `secret`. `key` resolves to the eight characters it
/// prints of the first one, which is how a run finds the juror that a
/// deal named; `said` is every line it has written, for a run that
/// has to check what a juror did rather than what a browser could see
/// it do. Both are only meaningful when the jurors are `apart` and this
/// process is one juror.
function startJuror([cmd, ...args], relay, secret, relayLog, size, say) {
  const juror = spawn(cmd, [...args, '--relay', relay, '--jurors', `${size}`],
      // The rig's service key, to hold every seat to its licence as a
      // device does (packages/table, licence.dart).
      { cwd: join(root, 'service'), env: { ...process.env, OH_JUROR_SECRET: secret, OH_SERVICE_KEY: localService.key } });
  const said = [];
  let named;
  const key = new Promise((resolve) => { named = resolve; });
  // Its whole log goes with the relay's, for a debugging run.
  juror.stdout.on('data', (d) => {
    if (relayLog) relayLog.write(d);
    for (const line of d.toString().split('\n')) {
      if (line === '') continue;
      said.push(line);
      const m = line.match(/^jurors of last resort (\w{8}) /);
      if (m) named(m[1]);
      if (/juror|summoned|called|verdict|done with/.test(line)) say(`juror: ${line.trim()}`);
    }
  });
  juror.stderr.on('data', (d) => process.stderr.write(d));
  return { key, said, proc: juror, kill: () => juror.kill() };
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

/// A TURN server on this machine (coturn's turnserver), for the app's
/// channels to go through as they go through Cloudflare's in
/// production: TURN only, so the rig plays the path production plays.
/// The handlers hand out its address and the user `rig`.
export async function startTurn({ tag = suite } = {}) {
  if (spawnSync('turnserver', ['--version']).error) {
    throw new Error("coturn's turnserver is needed for the browser suites (apt-get install coturn)");
  }
  // A free port, as the system gives one; coturn takes no port 0.
  const port = await new Promise((resolve) => {
    const probe = createSocket('udp4');
    probe.bind(0, '127.0.0.1', () => {
      const p = probe.address().port;
      probe.close(() => resolve(p));
    });
  });
  const logFile = join(root, 'app', 'build', 'logs', `turn-${tag}.log`);
  mkdirSync(dirname(logFile), { recursive: true });
  const proc = spawn('turnserver', [
    '-n', '--no-cli', '--no-tls', '--no-dtls',
    '--listening-ip=127.0.0.1', '--relay-ip=127.0.0.1', `--listening-port=${port}`,
    '--lt-cred-mech', '--user=rig:rig', '--realm=openhearts.local',
    // The peers it relays between are on this machine too.
    '--allow-loopback-peers',
    `--log-file=${logFile}`, '--simple-log', '--no-stdout-log',
  ]);
  await new Promise((resolveUp, reject) => {
    proc.on('exit', (code) => reject(new Error(`turnserver exited ${code}; see ${logFile}`)));
    setTimeout(resolveUp, 500);
  });
  // Gone with the suite, however the suite ends.
  process.on('exit', () => proc.kill());
  return { url: `turn:127.0.0.1:${port}`, stop: () => proc.kill() };
}

async function handlersFor(serve, turn, records, config) {
  const { default: handler, memoryStore } = await import(new URL('../service/functions/worker.mjs', import.meta.url));
  const store = memoryStore();
  // The operator's remote config (docs/06-service.md), where a suite
  // sets one: the row the worker checks and serves at /api/config.
  if (config) await store.put('config', 'app', config);
  const env = {
    OH_SERVICE_SECRET: localService.secret,
    OH_SERVICE_KEY: localService.key,
    OH_OPEN_HOUSE: '1',
    OH_TURN_LOCAL: turn,
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
/// what the site would keep in R2. A flow can look at it, or put a game
/// in it to open (`app.records`). One to each rig.
const recordsBucket = () => ({
  kept: new Map(),
  async head(key) {
    return this.kept.has(key) ? { key } : null;
  },
  async get(key) {
    const body = this.kept.get(key);
    return body ? { body: new Blob([body]).stream() } : null;
  },
  async put(key, body) {
    this.kept.set(key, Buffer.from(body));
  },
});

/// The site and the app, served as the site's Pages project serves them:
/// one directory — the site built in every language at the root, the app
/// at /play/ — behind the site's own worker (service/functions/worker.mjs),
/// which routes by host (docs/06-service.md, "Where the app is").
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
/// of the rig's for the app to find it; [tag] names the logs. [pace] is
/// the share of its tables' beats the app is asked to take (`pace=`,
/// app/lib/net/address.dart), which `app.at` names as well; [config] is
/// the operator's remote config, as the handlers serve it.
export async function serveApp({ relayPort = null, tag = suite, pace = null, config = null } = {}) {
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
  const turn = await startTurn({ tag });
  const records = recordsBucket();
  const handlers = await handlersFor(asset, turn.url, records, config);
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
    relayPort,
    /// An address of the rig's — a path under the app's host, or a whole
    /// address — with the rig's relay named in it, and its pace.
    at: (url) => withRelay(url.startsWith('/') ? `http://play.openhearts.localhost:${port}${url}` : url, relayPort, pace),
    stop: () => {
      server.close();
      turn.stop();
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
  // How long one pass over every page takes, which is how often any
  // one page is looked at. A state that comes and goes is caught only
  // if that period is shorter than the state lasts, so when this
  // times out the period is half the answer to why. The pages are
  // looked at together, as four people look at their own screens: a
  // pass is as long as its slowest page, not all four end to end.
  const periods = [];
  while (Date.now() < until) {
    const round = Date.now();
    const caught = await Promise.all(pages.map(async (page, i) => {
      if (page.isClosed()) return true;
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
      if (!finished.has(i) && (await done(page, i))) finished.add(i);
      return finished.has(i);
    }));
    const all = caught.every(Boolean);
    if (all) return;
    await sleep(300);
    periods.push(Date.now() - round);
  }
  periods.sort((a, b) => a - b);
  const at = (q) => periods[Math.min(periods.length - 1, Math.floor(periods.length * q))] ?? 0;
  throw new Error(
    `timed out after ${periods.length} passes over the pages, each taking ${at(0)}–${at(0.99)} ms ` +
      `(median ${at(0.5)}); ${finished.size} of ${pages.length} pages were caught: ` +
      `${await Promise.all(pages.filter((p) => !p.isClosed()).map(async (p) => (await texts(p)).join(' | ')))}`,
  );
}

