// site/public/_headers: what the app is served with, read the way Pages
// reads it (headers.mjs), and the Content-Security-Policy it holds
// against the code and the configuration it is there for. The app
// loaded under it, in a browser, is e2e/csp.mjs.
//
//   node --test site/headers.test.mjs
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';
import { headersFor, parseHeaders } from './headers.mjs';

const here = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, here), 'utf8');
const rules = parseHeaders(read('site/public/_headers'));
const config = JSON.parse(read('config/openhearts.json'));

// ---- the reader ---------------------------------------------------------

test('a path takes the headers of every rule that matches it, joined in the order of the file', () => {
  const r = parseHeaders(`
# A comment, and a blank line.
/*
  X-One: a
  X-Two: x
/app/*
  X-One: b
  x-one: c
/app/index.html
  X-Three: z
`);
  assert.deepEqual(headersFor(r, '/'), { 'x-one': 'a', 'x-two': 'x' });
  assert.deepEqual(headersFor(r, '/app/main.js'), { 'x-one': 'a, b, c', 'x-two': 'x' });
  assert.deepEqual(headersFor(r, '/app/index.html'), { 'x-one': 'a, b, c', 'x-two': 'x', 'x-three': 'z' });
});

test('a * is any run of characters, the bare directory included, and nothing else is special', () => {
  const r = parseHeaders('/play/*\n  X-A: 1\n/a.b\n  X-B: 2\n');
  assert.ok('x-a' in headersFor(r, '/play/'), 'the directory itself');
  assert.ok('x-a' in headersFor(r, '/play/deep/er/file.js'));
  assert.ok(!('x-a' in headersFor(r, '/play')), 'the path without its slash');
  assert.ok(!('x-a' in headersFor(r, '/playground/x')), 'a longer name');
  assert.ok('x-b' in headersFor(r, '/a.b'));
  assert.ok(!('x-b' in headersFor(r, '/aXb')), 'a . is a dot');
});

test('what Pages does that this does not is refused rather than guessed at', () => {
  assert.throws(() => parseHeaders('/a/:id\n  X: 1\n'), /only a path/);
  assert.throws(() => parseHeaders('https://x.example/*\n  X: 1\n'), /only a path/);
  assert.throws(() => parseHeaders('/a\n  ! X-Frame-Options\n'), /taken off/);
  assert.throws(() => parseHeaders('  X: 1\n'), /not "Name: value" under a path/);
  assert.throws(() => parseHeaders('/a\n  no colon here\n'), /not "Name: value"/);
});

// ---- the policy ---------------------------------------------------------

/// The policies of a Content-Security-Policy header, one for each of its
/// comma-joined values, each as directive -> sources.
const policiesOf = (header) =>
  header.split(',').map((policy) =>
    Object.fromEntries(
      policy
        .split(';')
        .map((d) => d.trim())
        .filter(Boolean)
        .map((d) => {
          const [name, ...sources] = d.split(/\s+/);
          return [name.toLowerCase(), sources];
        }),
    ),
  );

/// The sources [header] gives [directive]: those of the one policy that
/// names it. A header in which two did would be read by their
/// intersection, which a list cannot say, so it is not read at all.
function sourcesFor(header, directive) {
  const naming = policiesOf(header).filter((p) => directive in p);
  assert.ok(naming.length <= 1, `${naming.length} policies name ${directive}`);
  return naming[0]?.[directive];
}

const policyOf = (path) => headersFor(rules, path)['content-security-policy'];

/// Every file of the app is under /play/ (service/functions/app_host.mjs):
/// the page, what it loads, its workers, its wasm.
const appPaths = [
  '/play/',
  '/play/index.html',
  '/play/main.dart.js',
  '/play/flutter_bootstrap.js',
  '/play/observability.js',
  '/play/deal_worker.js',
  '/play/offline_worker.js',
  '/play/review_worker.js',
  '/play/deal.wasm',
  '/play/canvaskit/chromium/canvaskit.wasm',
  '/play/zxing/zxing-library-0.23.0.min.js',
  '/play/assets/FontManifest.json',
];

const observability = read('app/web/observability.js');
const tokens = read('app/lib/net/provider_tokens_web.dart');

/// The origin New Relic's loader fetches its parts from.
const agentOrigin = () => {
  const path = observability.match(/\.p="(https:\/\/[^"]+)"/)?.[1];
  assert.ok(path, "app/web/observability.js names no public path for New Relic's parts");
  return new URL(path).origin;
};

/// The origin a sign-in provider's script is fetched from, by the name
/// of the constant in provider_tokens_web.dart that holds its address.
const providerOrigin = (constant) => {
  const script = tokens.match(new RegExp(`const ${constant} = '(https://[^']+)'`))?.[1];
  assert.ok(script, `provider_tokens_web.dart names no ${constant}`);
  return new URL(script).origin;
};

/// The origins the app loads third-party scripts from under [cfg]: New
/// Relic's always (on play.openhearts.game), and a provider's where the
/// build is given its identifier (deploy.sh, app/tool/defines.mjs).
const thirdParties = (cfg) =>
  [agentOrigin(), ...(cfg.apple?.servicesId ? [providerOrigin('_appleScript')] : []), ...(cfg.google?.webClientId ? [providerOrigin('_googleScript')] : [])].sort();

test('every file of the app is served with a policy that names script-src and worker-src, and still lets nobody frame it', () => {
  for (const path of appPaths) {
    const header = policyOf(path);
    assert.ok(header, `${path} has no Content-Security-Policy`);
    assert.ok(sourcesFor(header, 'script-src'), `${path}: no script-src`);
    assert.ok(sourcesFor(header, 'worker-src'), `${path}: no worker-src`);
    assert.ok(policiesOf(header).some((p) => p['frame-ancestors']?.join(' ') === "'none'"), `${path}: nobody may frame it`);
  }
});

test("the app's own rule is a whole policy: it needs nothing of the rule for every path to stand alone", () => {
  // Pages joins the values of a header that more than one rule sets
  // (headers.mjs); a platform that took the last instead would leave
  // the app with this rule's alone.
  const own = rules.find((r) => r.pattern === '/play/*')?.set.filter(([name]) => name.toLowerCase() === 'content-security-policy');
  assert.equal(own?.length, 1, 'one Content-Security-Policy under /play/*');
  const [policy, ...more] = policiesOf(own[0][1]);
  assert.equal(more.length, 0, 'one policy');
  assert.deepEqual(policy['frame-ancestors'], ["'none'"]);
  assert.ok(policy['script-src'] && policy['worker-src']);
});

test('scripts: the app itself, WebAssembly, and the third parties the code and configuration load from, and nothing else', () => {
  const sources = sourcesFor(policyOf('/play/'), 'script-src');
  assert.deepEqual(sources.filter((s) => s.startsWith("'")).sort(), ["'self'", "'wasm-unsafe-eval'"], 'no unsafe-inline, no unsafe-eval, no nonce or hash');
  const hosts = sources.filter((s) => !s.startsWith("'"));
  for (const s of hosts) assert.match(s, /^https:\/\/[a-z0-9.-]+$/, `${s}: a script source is an https origin, with no wildcard, no scheme alone and no path`);
  assert.deepEqual(hosts.sort(), thirdParties(config), 'the policy names exactly the origins the code and config/openhearts.json load scripts from');
});

test("a sign-in provider's script is allowed exactly when the build is given its identifier", () => {
  const hosts = sourcesFor(policyOf('/play/'), 'script-src');
  assert.equal(hosts.includes(providerOrigin('_appleScript')), !!config.apple?.servicesId, 'Apple: config apple.servicesId and the policy disagree');
  assert.equal(hosts.includes(providerOrigin('_googleScript')), !!config.google?.webClientId, 'Google: config google.webClientId and the policy disagree');
  // And the rule is live: a configuration that offered Google on the web
  // would want its script, which this policy does not allow, and one
  // that offered no Apple would not want Apple's, which it does.
  const withGoogle = thirdParties({ ...config, google: { ...config.google, webClientId: 'x.apps.googleusercontent.com' } });
  assert.ok(withGoogle.includes(providerOrigin('_googleScript')) && !hosts.includes(providerOrigin('_googleScript')));
  assert.ok(!thirdParties({ ...config, apple: { ...config.apple, servicesId: null } }).includes(providerOrigin('_appleScript')));
});

test('workers: the app, and a blob for the deal, which a script may not be', () => {
  assert.deepEqual(sourcesFor(policyOf('/play/'), 'worker-src').sort(), ["'self'", 'blob:']);
  assert.ok(!sourcesFor(policyOf('/play/'), 'script-src').some((s) => /:$/.test(s) || s === '*'), 'a script source is a whole scheme, or anything');
  // The one thing in the app that makes an object URL is the deal's
  // worker, the reason for blob: (packages/deal/lib/src/worker_web.dart).
  // Something else that does is for somebody to look at the policy for.
  const walk = (dir) =>
    readdirSync(new URL(dir, here), { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(`${dir}${e.name}/`) : /\.(dart|js)$/.test(e.name) ? [`${dir}${e.name}`] : []));
  const sources = ['app/lib/', 'app/web/', 'app/worker/', ...readdirSync(new URL('packages/', here)).map((p) => `packages/${p}/lib/`)].flatMap(walk);
  const makers = sources.filter((f) => !f.startsWith('app/web/zxing/') && f !== 'app/web/observability.js' && /createObjectURL/.test(read(f)));
  assert.deepEqual(makers, ['packages/deal/lib/src/worker_web.dart']);
});

test("New Relic's loader fetches its parts from the origin the policy names, and makes no code from text", () => {
  assert.ok(sourcesFor(policyOf('/play/'), 'script-src').includes(agentOrigin()));
  for (const [what, re] of [['eval', /\beval\s*\(/], ['new Function', /new Function\b/], ['a worker', /new Worker\b/], ['importScripts', /importScripts\b/], ['document.write', /document\.write\b/]]) {
    assert.ok(!re.test(observability), `the loader uses ${what}`);
  }
});

test("the app's page has no inline script and no inline handler, and every script it names is a file beside it", () => {
  const html = read('app/web/index.html').replace(/<!--[\s\S]*?-->/g, '');
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  assert.ok(scripts.length >= 4, 'the page loads its scripts');
  for (const [, attrs, body] of scripts) {
    assert.equal(body.trim(), '', `an inline script: ${body.trim().slice(0, 60)}`);
    const src = attrs.match(/\bsrc="([^"]+)"/)?.[1];
    assert.ok(src && !/^([a-z]+:)?\/\//i.test(src) && !src.startsWith('/'), `${src}: not a file beside the page`);
  }
  assert.ok(!/\son[a-z]+\s*=/i.test(html), 'an inline event handler');
  assert.ok(!/javascript:/i.test(html), 'a javascript: address');
});
