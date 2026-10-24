// oh photodna put and get, and the relay deploy's PhotoDNA module: kept
// in the private bucket by SHA-256, pinned in config/openhearts.json,
// fetched and checked against its pins only to deploy, and never left
// on disk after (ops/photodna.mjs, ops/release.mjs); and the check that
// none of it is ever in the repository (ops/no_private.mjs).
//
//   node --test ops/*.test.mjs

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { MARKS, OWN_WASM, privateProblems } from './no_private.mjs';
import { main } from './oh.mjs';
import { root } from './env.mjs';
import { ENTRY, MODULE_ALIAS, MODULE_DIR, keyOf, pinsOf, withPins } from './photodna.mjs';

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const temp = (name) => mkdtempSync(join(tmpdir(), `${name}-`));

/// A config file as config/openhearts.json is written, the PhotoDNA
/// member pinning [module].
const configText = (module) => `{
  "appOrigin": "https://play.example",
  "photodna": {
    "endpoint": "https://photodna.example/MatchHash",
    "module": ${module === null ? 'null' : JSON.stringify(module)}
  },
  "ncmec": { "endpoint": "https://ncmec.example" }
}
`;

/// A module's files in a folder of their own.
function moduleIn(files = { 'edge.mjs': 'export const edgeHashes = null;\n', 'core.wasm': '\0asm' }) {
  const dir = temp('module');
  for (const [name, text] of Object.entries(files)) writeFileSync(join(dir, name), text);
  return { dir, pins: Object.fromEntries(Object.entries(files).map(([n, t]) => [n, sha256(Buffer.from(t))])) };
}

/// The private bucket: its objects by key, and what was written.
function privateBucket(objects = new Map()) {
  const written = [];
  return {
    objects,
    written,
    list: async (prefix) => [...objects.keys()].filter((k) => k.startsWith(prefix)),
    read: async (key) => objects.get(key) ?? null,
    write: async (key, bytes, type) => {
      written.push({ key, type });
      objects.set(key, Uint8Array.from(bytes));
    },
  };
}

/// A context for [config] (its file's text), with [bucket] as the
/// private bucket.
function context({ config = configText(null), bucket = privateBucket(), ...rest } = {}) {
  const configFile = join(temp('config'), 'openhearts.json');
  writeFileSync(configFile, config);
  const said = [];
  const warned = [];
  const started = [];
  return {
    said,
    warned,
    started,
    bucket,
    configFile,
    env: {},
    log: (l) => said.push(l),
    warn: (l) => warned.push(l),
    config: async () => JSON.parse(readFileSync(configFile, 'utf8')),
    privateFiles: async () => bucket,
    run: async (command, args, options) => (started.push({ command, args, ...options }), 0),
    capture: async (command, args) => ({ code: 0, out: args.includes('HEAD') || args.includes('origin/main') ? 'abc\n' : '' }),
    ...rest,
  };
}

test('the relay is told to build the module where the deploy puts it, in place of the stand-in', () => {
  const [name, path] = MODULE_ALIAS.split(':');
  assert.match(readFileSync(join(root, 'service/do/wrangler.toml'), 'utf8'), new RegExp(`^"${name}" = `, 'm'));
  assert.equal(join(root, 'service/do', path), join(MODULE_DIR, ENTRY));
  assert.match(readFileSync(join(root, '.gitignore'), 'utf8'), /^service\/do\/private\/$/m, 'and git ignores it');
});

test('the pins: each file named and its SHA-256, edge.mjs among them, or none', () => {
  assert.equal(pinsOf({}), null);
  assert.equal(pinsOf({ photodna: { module: null } }), null);
  const pins = { 'edge.mjs': 'a'.repeat(64), 'x.wasm': 'b'.repeat(64) };
  assert.deepEqual(pinsOf({ photodna: { module: pins } }), pins);
  for (const module of [{}, { 'x.wasm': 'b'.repeat(64) }, { 'edge.mjs': 'A'.repeat(64) }, { 'edge.mjs': 'a'.repeat(63) }, { 'edge.mjs': 'a'.repeat(64), '../x': 'b'.repeat(64) }, { 'edge.mjs': 'a'.repeat(64), 'sub/x': 'b'.repeat(64) }]) {
    assert.throws(() => pinsOf({ photodna: { module } }), /photodna.module in config\/openhearts.json/, JSON.stringify(module));
  }
});

test('pinning changes only the module in the config, written as the file is', () => {
  const pins = { 'edge.mjs': 'a'.repeat(64), 'x.wasm': 'b'.repeat(64) };
  const text = configText(null);
  const pinned = withPins(text, pins);
  assert.deepEqual(JSON.parse(pinned), { ...JSON.parse(text), photodna: { ...JSON.parse(text).photodna, module: pins } });
  assert.ok(pinned.startsWith(text.slice(0, text.indexOf('"photodna"'))));
  assert.ok(pinned.endsWith(text.slice(text.indexOf('  "ncmec"') - 2)));
  assert.match(pinned, /\n {6}"x\.wasm": "b{64}"\n {4}\}\n {2}\},\n/);
  assert.equal(withPins(pinned, pins), pinned, 'pinned already: the same');
  const committed = readFileSync(new URL('../config/openhearts.json', import.meta.url), 'utf8');
  const theirs = JSON.parse(committed).photodna.module;
  if (theirs) assert.equal(withPins(committed, theirs), committed, 'the committed config is as pinning writes it');
  assert.throws(() => withPins('{}', pins), /has no "photodna"/);
});

test('put says what it would keep and changes nothing; with --apply keeps each file once, by its SHA-256, and pins them', async () => {
  const { dir, pins } = moduleIn();
  const ctx = context();
  assert.equal(await main(['photodna', 'put', dir], ctx), 0);
  assert.deepEqual(ctx.bucket.written, []);
  assert.equal(readFileSync(ctx.configFile, 'utf8'), configText(null));
  assert.match(ctx.said.join('\n'), /edge\.mjs: [0-9a-f]{64}, to keep/);
  assert.match(ctx.said.at(-1), /--apply keeps them and pins them/);

  assert.equal(await main(['photodna', 'put', dir, '--apply'], ctx), 0);
  assert.deepEqual(ctx.bucket.written.map((w) => w.key).sort(), Object.values(pins).map(keyOf).sort());
  for (const [name, hash] of Object.entries(pins)) assert.deepEqual(Buffer.from(ctx.bucket.objects.get(keyOf(hash))), readFileSync(join(dir, name)));
  assert.deepEqual(JSON.parse(readFileSync(ctx.configFile, 'utf8')).photodna.module, pins);

  // Again: kept already, and pinned already.
  const before = ctx.bucket.written.length;
  ctx.said.length = 0;
  assert.equal(await main(['photodna', 'put', dir, '--apply'], ctx), 0);
  assert.equal(ctx.bucket.written.length, before);
  assert.match(ctx.said.join('\n'), /kept already/);
  assert.match(ctx.said.at(-1), /pins these already/);

  // Only a module: one with no entry is refused, and so is no folder.
  const { dir: entryless } = moduleIn({ 'core.wasm': '\0asm' });
  assert.equal(await main(['photodna', 'put', entryless, '--apply'], context()), 1);
  assert.equal(await main(['photodna', 'put', '--apply'], context()), 2);
});

test('get fetches exactly the pinned files, each checked against its pin', async () => {
  const { dir, pins } = moduleIn();
  const kept = new Map(Object.entries(pins).map(([name, hash]) => [keyOf(hash), readFileSync(join(dir, name))]));
  const ctx = context({ config: configText(pins), bucket: privateBucket(kept) });
  const out = join(temp('out'), 'module');
  assert.equal(await main(['photodna', 'get', out], ctx), 0);
  for (const name of Object.keys(pins)) assert.deepEqual(readFileSync(join(out, name)), readFileSync(join(dir, name)));

  // Not kept, or not what is pinned: refused.
  const missing = context({ config: configText(pins), bucket: privateBucket(new Map([...kept].slice(1))) });
  assert.equal(await main(['photodna', 'get', join(temp('out'), 'm')], missing), 1);
  assert.match(missing.warned.join('\n'), /is not in the private bucket/);
  const changed = new Map(kept);
  changed.set(keyOf(pins['edge.mjs']), Buffer.from('export const edgeHashes = () => [];\n'));
  const wrong = context({ config: configText(pins), bucket: privateBucket(changed) });
  assert.equal(await main(['photodna', 'get', join(temp('out'), 'm')], wrong), 1);
  assert.match(wrong.warned.join('\n'), /is not what config\/openhearts.json pins/);

  // Nothing pinned: nothing to get.
  const none = context();
  assert.equal(await main(['photodna', 'get', join(temp('out'), 'm')], none), 1);
  assert.match(none.warned.join('\n'), /pins no PhotoDNA module/);
});

test('the relay is deployed with the pinned module in the stand-in\'s place, fetched only for the build and gone after', async () => {
  const { dir, pins } = moduleIn();
  const kept = new Map(Object.entries(pins).map(([name, hash]) => [keyOf(hash), readFileSync(join(dir, name))]));
  const moduleDir = join(temp('relay'), 'private', 'photodna');
  mkdirSync(moduleDir, { recursive: true });
  writeFileSync(join(moduleDir, 'stale.mjs'), 'left from before');
  const seen = [];
  const ctx = context({ config: configText(pins), bucket: privateBucket(kept), moduleDir });
  ctx.run = async (command, args, options) => {
    seen.push(...Object.keys(pins).map((name) => readFileSync(join(moduleDir, name)).equals(readFileSync(join(dir, name)))));
    seen.push(existsSync(join(moduleDir, 'stale.mjs')));
    ctx.started.push({ command, args, ...options });
    return 0;
  };
  assert.equal(await main(['deploy', 'relay'], ctx), 0);
  assert.match(ctx.said.join('\n'), /with the PhotoDNA module config\/openhearts.json pins, from the private bucket \(2 files\)/);
  assert.equal(ctx.started.length, 0);

  assert.equal(await main(['deploy', 'relay', '--apply'], ctx), 0);
  const [{ args, cwd }] = ctx.started;
  assert.deepEqual(args.slice(-3), ['deploy', '--alias', MODULE_ALIAS]);
  assert.match(cwd, /service\/do$/);
  assert.deepEqual(seen, [true, true, false], 'the pinned files there as it builds, and nothing else');
  assert.ok(!existsSync(moduleDir), 'gone after');

  // A deploy that fails leaves nothing either.
  ctx.run = async () => 1;
  assert.equal(await main(['deploy', 'relay', '--apply'], ctx), 1);
  assert.ok(!existsSync(moduleDir));

  // A module not kept: nothing deployed.
  const lost = context({ config: configText(pins), moduleDir });
  assert.equal(await main(['deploy', 'relay', '--apply'], lost), 1);
  assert.equal(lost.started.length, 0);
  assert.ok(!existsSync(moduleDir));

  // Nothing pinned: the stand-in, said so.
  const off = context({ moduleDir });
  assert.equal(await main(['deploy', 'relay', '--apply'], off), 0);
  assert.match(off.said.join('\n'), /without a PhotoDNA module/);
  assert.ok(!off.started[0].args.includes('--alias'));
});

test('nothing private in the repository: the module\'s folder, its pinned files, the private marks, and WebAssembly not the app\'s', () => {
  const file = (path, text) => ({ path, bytes: Buffer.from(text) });
  const pins = { 'edge.mjs': sha256(Buffer.from('the module')) };
  assert.deepEqual(privateProblems([file('service/do/photodna_off.mjs', 'export const edgeHashes = null;'), file(OWN_WASM[0], '\0asm')], pins), []);
  assert.deepEqual(privateProblems([file('service/do/private/photodna/x.txt', 'x')], pins), ["service/do/private/photodna/x.txt: the PhotoDNA module's folder is never committed"]);
  assert.deepEqual(privateProblems([file('elsewhere/edge.js', 'the module')], pins), ["elsewhere/edge.js: is the PhotoDNA module's edge.mjs"]);
  assert.deepEqual(privateProblems([file('elsewhere/edge.js', 'the module')], null), [], 'nothing pinned');
  for (const mark of MARKS) assert.deepEqual(privateProblems([file('a.mjs', `// ${mark}\n`)], null), [`a.mjs: says "${mark}"`]);
  assert.deepEqual(privateProblems([file('service/do/edge.wasm', '\0asm')], null), ["service/do/edge.wasm: WebAssembly that is not the app's own"]);
});
