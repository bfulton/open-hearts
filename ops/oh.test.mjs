// The oh command: its reference is its table, every command it lists
// can be run as its example shows, and what each does is held to what
// it says (ops/oh.mjs, ops/commands.mjs).
//
//   node --test ops/*.test.mjs

import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { ARGUMENTS, COMMANDS } from './commands.mjs';
import { root } from './env.mjs';
import { releaseProblems } from './gate.mjs';
import { commandOf, main, markdown, parse } from './oh.mjs';
import { INVITED_DAYS, withHouseKey, withPreviewKey } from './preview.mjs';
import { rejected, reshaped } from './setup.mjs';
import { KNOWN_ROW } from '../service/do/checkers.mjs';
import { configOf } from '../service/functions/config.mjs';
import { backupCodeOf, entitlementOf, redeemBackup } from '../service/functions/accounts.mjs';
import { dayAfter, memoryStore } from '../service/functions/rows.mjs';
import { config as committed, languages, origin, render, strings } from '../site/build.mjs';
import { fingerprintOf, formatLedger } from '../site/ledger.mjs';

/// A context that records what a command says and starts, with [store]
/// for the production store and [capture] answering the programs it
/// asks about.
function fake({ store = memoryStore(), capture = async () => ({ code: 0, out: '' }), fetch: fetchImpl, config = { appOrigin: 'https://play.example' }, ...rest } = {}) {
  const said = [];
  const warned = [];
  const started = [];
  const withList = Object.assign(store, { list: async (prefix) => [...store.rows.keys()].filter((k) => k.startsWith(prefix)) });
  return {
    said,
    warned,
    started,
    env: {},
    fetch: fetchImpl ?? (async () => new Response('{}', { status: 200 })),
    log: (line) => said.push(line),
    warn: (line) => warned.push(line),
    store: async () => withList,
    bucket: () => ({ list: async () => [], get: async () => null, put: async () => {} }),
    stripe: () => {
      throw new Error('no Stripe in this test');
    },
    config: async () => config,
    run: async (command, args, options = {}) => {
      started.push({ command, args, ...options });
      return 0;
    },
    capture,
    now: () => Date.parse('2026-10-16T12:00:00Z'),
    carryOptions: { tries: 1, wait: 0 },
    ...rest,
  };
}

/// The site as this checkout builds it, served, with a ledger whose
/// newest entries are it: production with no change to the terms to
/// publish (ops/terms.test.mjs holds the rest).
function settled() {
  const summary = Object.fromEntries(languages.map((l) => [l.code, 'Where it begins.']));
  const ledger = {
    terms: [{ date: '2026-10-16', fingerprint: fingerprintOf('terms'), change: 'first', price: committed().price, storesNotified: null, summary }],
    privacy: [{ date: '2026-10-13', fingerprint: fingerprintOf('privacy'), change: 'first', storesNotified: null, summary }],
  };
  const ledgerFile = join(mkdtempSync(join(tmpdir(), 'ledger-')), 'ledger.json');
  writeFileSync(ledgerFile, formatLedger(ledger));
  return {
    ledgerFile,
    config: { ...committed(), appOrigin: 'https://play.example' },
    fetch: async (url) => {
      const [, code = 'en', doc] = new RegExp(`^${origin}(?:/(es|pt|de|fr))?/(terms|privacy)$`).exec(String(url)) ?? [];
      return doc ? new Response(render(doc, languages.find((l) => l.code === code), strings(code))) : new Response('no', { status: 404 });
    },
  };
}

const account = '0123456789abcdef0123456789abcdef';

test('the reference is the table, as ./oh help --markdown writes it', () => {
  const page = readFileSync(join(root, 'docs/reference/oh.md'), 'utf8');
  assert.equal(page, markdown(), 'run ./oh help --markdown > docs/reference/oh.md');
});

test('every command says what it is, what it needs and where its how-to is, and its example runs as written', () => {
  const seen = new Set();
  for (const c of COMMANDS) {
    const name = c.words.join(' ');
    assert.ok(!seen.has(name), `${name} twice`);
    seen.add(name);
    assert.ok(c.summary && Array.isArray(c.needs) && c.example, name);
    const [path, hash] = c.howto.split('#');
    assert.ok(existsSync(join(root, path)), `${name}: ${path}`);
    if (hash) assert.match(readFileSync(join(root, path), 'utf8'), new RegExp(`^#+ ${hash.replace(/-/g, '[ -]')}$`, 'im'), `${name}: #${hash}`);
    for (const a of c.args ?? []) assert.ok(ARGUMENTS[a], `${name}: <${a}> is not described`);
    const words = c.example.split(' ').map((w) => w.replace(/^'|'$/g, ''));
    assert.equal(words[0], 'oh');
    assert.equal(commandOf(words.slice(1)), c, `${name}: its example runs another command`);
    assert.doesNotThrow(() => parse(c, c.example.match(/'[^']*'|\S+/g).slice(1 + c.words.length).map((w) => w.replace(/^'|'$/g, ''))), name);
  }
});

test('asked wrongly, oh says how and exits 2; asked for help, it helps; nothing it does not know runs', async () => {
  const ctx = fake();
  assert.equal(await main(['acount'], ctx), 2);
  assert.equal(await main(['account', 'remove', account], ctx), 2, 'a missing <what>');
  assert.equal(await main(['account', 'suspend', account, '--aply'], ctx), 2, 'a misspelt --apply is not a dry run but a mistake');
  assert.equal(await main(['account', 'suspend', account, 'extra'], ctx), 2);
  assert.equal(await main(['deploy', 'site', '--label'], ctx), 2, '--label without its value');
  assert.match(ctx.warned.join('\n'), /no command acount/);
  assert.equal(await main(['help', 'account', 'suspend'], ctx), 0);
  assert.equal(await main(['account', 'suspend', '--help'], ctx), 0);
  assert.match(ctx.said.join('\n'), /oh account suspend <account> \[--apply\]/);
  assert.equal(ctx.started.length, 0);
});

test('an act on an account says what it would do and changes nothing without --apply; with it, the service is asked', async () => {
  const store = memoryStore();
  await store.put(`ACCOUNT#${account}`, 'META', { subscription: null });
  await store.put(`ACCOUNT#${account}`, 'DEVICE#aa', {});
  const asked = [];
  const ctx = fake({
    store,
    fetch: async (url, init) => {
      asked.push({ url, body: JSON.parse(init.body) });
      return new Response(JSON.stringify({ act: 'suspend', suspended: true }), { status: 200 });
    },
  });
  assert.equal(await main(['account', 'suspend', account], ctx), 0);
  assert.match(ctx.said.join('\n'), /would refuse its 1 device\(s\) licences/);
  assert.match(ctx.said.at(-1), /nothing changed; --apply does it/);
  assert.equal(asked.length, 0);
  assert.equal([...store.rows.keys()].filter((k) => k.startsWith('ORDER#')).length, 0, 'no order written');

  assert.equal(await main(['account', 'suspend', account, '--apply'], ctx), 0);
  assert.equal(asked.length, 1);
  assert.equal(asked[0].url, 'https://play.example/api/order');
  assert.match(ctx.said.at(-1), /^done: /);

  assert.equal(await main(['account', 'show', 'f'.repeat(32)], fake({ store })), 1, 'no such account');
});

test('production is released only from main as it was reviewed', async () => {
  const git = (answers) => async (command, args) => ({ code: 0, out: answers[args.join(' ')] ?? '' });
  const clean = { 'rev-parse HEAD': 'abc1234\n', 'rev-parse origin/main': 'abc1234\n', 'status --porcelain --untracked-files=no': '' };
  assert.deepEqual(await releaseProblems(fake({ capture: git(clean), ...settled() }), 'site'), []);
  const ahead = await releaseProblems(fake({ capture: git({ ...clean, 'rev-parse HEAD': 'def5678\n' }) }), 'relay');
  assert.match(ahead.join('\n'), /HEAD \(def5678\) is not origin\/main \(abc1234\)/);
  const dirty = await releaseProblems(fake({ capture: git({ ...clean, 'status --porcelain --untracked-files=no': ' M deploy.sh\n M oh\n' }), ...settled() }), 'site');
  assert.deepEqual(dirty, ['uncommitted changes: 2 file(s)']);

  // oh deploy says so and, asked to deploy, starts nothing.
  const ctx = fake({ capture: git({ ...clean, 'rev-parse HEAD': 'def5678\n', 'rev-parse --abbrev-ref HEAD': 'main\n' }), ...settled() });
  assert.equal(await main(['deploy', 'site', '--apply'], ctx), 1);
  assert.equal(ctx.started.length, 0);
  // A preview is for looking at, and is not held to it.
  const preview = fake({ capture: git({ ...clean, 'rev-parse HEAD': 'def5678\n' }) });
  assert.equal(await main(['deploy', 'site', '--label', 'my-change', '--apply'], preview), 0);
  assert.deepEqual(preview.started.map((s) => s.args), [['my-change']]);
});

test('a relay deploy says what it lacks before it starts', async () => {
  const capture = async (command, args) => ({ code: command === 'docker' ? 1 : 0, out: args.includes('HEAD') || args.includes('origin/main') ? 'abc\n' : '' });
  const ctx = fake({ capture });
  assert.equal(await main(['deploy', 'relay'], ctx), 0);
  assert.match(ctx.said.join('\n'), /not ready: needs Docker, running/);
  assert.equal(await main(['deploy', 'relay', '--apply'], ctx), 1);
  assert.equal(ctx.started.length, 0);
});

test('a run-time row is checked as the service checks it before it is written', async () => {
  assert.deepEqual(rejected(configOf, { live: false }), []);
  assert.deepEqual(rejected(configOf, { live: 'no', banner: { id: 'x', text: { en: 'Hi' } } }), ['live']);
  assert.deepEqual(rejected(configOf, { liev: false }), ['liev'], 'a misspelt field is not quietly ignored');
  assert.deepEqual(rejected(configOf, { live: true }), [], 'a field set to its default took');
  assert.deepEqual(rejected(configOf, { banner: { id: 'not an id!', text: { en: 'Hi' } } }), ['banner']);
  assert.deepEqual(
    reshaped(configOf, { banner: { id: 'x', text: { en: 'Hi' } } }).map(([field]) => field),
    ['banner'],
    'a default filled in is said, not refused',
  );
});

test('the checker of known images in use is the run-time row known, written where the relay reads it, and only as a checker it knows', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'known-'));
  const file = (name, row) => (writeFileSync(join(dir, name), JSON.stringify(row)), join(dir, name));
  const ctx = fake();
  assert.equal(await main(['config', 'set', 'known', file('photodna.json', { checker: 'photodna' }), '--apply'], ctx), 0);
  const store = await ctx.store();
  assert.equal(store.rows.get(KNOWN_ROW.join('|')), JSON.stringify({ checker: 'photodna' }));
  assert.equal(await main(['config', 'set', 'known', file('typo.json', { checker: 'photdna' }), '--apply'], ctx), 1);
  assert.equal(store.rows.get(KNOWN_ROW.join('|')), JSON.stringify({ checker: 'photodna' }), 'nothing written');
  assert.equal(await main(['config', 'clear', 'known', '--apply'], ctx), 0);
  assert.equal(store.rows.has(KNOWN_ROW.join('|')), false, 'back to Shield');
});

test('a secret is set wherever its definition says it lives, from what is typed', async () => {
  const ctx = fake({ readSecret: async () => 's3cret' });
  assert.equal(await main(['secret', 'set', 'OH_ID_HMAC', '--apply'], ctx), 0);
  assert.deepEqual(
    ctx.started.map((s) => s.args.slice(2)),
    [
      ['pages', 'secret', 'put', 'OH_ID_HMAC', '--project-name', 'open-hearts'],
      ['pages', 'secret', 'put', 'OH_ID_HMAC', '--project-name', 'open-hearts', '--env', 'preview'],
    ],
  );
  assert.ok(ctx.started.every((s) => s.input === 's3cret'));
  assert.ok(!ctx.said.join('\n').includes('s3cret'), 'never said back');
  // The service's secret is production's alone: previews have their own
  // (oh preview secrets), and production's is never put on one.
  const service = fake({ readSecret: async () => 'x' });
  assert.equal(await main(['secret', 'set', 'OH_SERVICE_SECRET', '--apply'], service), 0);
  assert.deepEqual(service.started.map((s) => s.args.slice(2)), [['pages', 'secret', 'put', 'OH_SERVICE_SECRET', '--project-name', 'open-hearts']]);
  // The house's is never typed in: oh house key makes it, with the key
  // that goes into the config beside it.
  const house = fake({ readSecret: async () => 'x' });
  assert.equal(await main(['secret', 'set', 'OH_HOUSE_SECRET', '--apply'], house), 2);
  assert.equal(house.started.length, 0);
  // One set only once it is issued, as a checker's credentials are: the
  // relay's too, and only the relay's.
  for (const name of ['OH_ARACHNID_USERNAME', 'OH_ARACHNID_PASSWORD', 'OH_PHOTODNA_KEY', 'OH_NCMEC_USERNAME', 'OH_NCMEC_PASSWORD']) {
    const optional = fake({ readSecret: async () => 'x' });
    assert.equal(await main(['secret', 'set', name, '--apply'], optional), 0, name);
    assert.deepEqual(optional.started.map((s) => [s.args.slice(2), s.cwd.endsWith('service/do')]), [[['secret', 'put', name], true]], name);
  }
  assert.equal(await main(['secret', 'set', 'OH_NOT_A_SECRET', '--apply'], fake()), 2);
});

// ---- previews ---------------------------------------------------------------

/// The committed config, copied where a command may write it.
function configCopy() {
  const text = readFileSync(join(root, 'config/openhearts.json'), 'utf8');
  const configFile = join(mkdtempSync(join(tmpdir(), 'config-')), 'openhearts.json');
  writeFileSync(configFile, text);
  return { text, configFile };
}

/// The rest of a config's text, its preview member taken out.
const outsidePreview = (text) => text.replace(/^ *"preview": \{[^}]*\},\n/m, '');

test("the previews' key goes beside production's, and nothing else in the file changes", () => {
  const { text } = configCopy();
  const before = outsidePreview(text);
  const key = 'b'.repeat(64);
  const made = withPreviewKey(before, key);
  assert.deepEqual(JSON.parse(made), { ...JSON.parse(before), preview: { serviceKey: key } });
  assert.equal(outsidePreview(made), before);
  assert.match(made, new RegExp(`"serviceKey": "${JSON.parse(before).serviceKey}",\n  "preview": \\{ "serviceKey": "${key}" \\},\n`));
  // Made again, it is replaced where it is, and what else it holds kept.
  const again = withPreviewKey(made.replace(`"serviceKey": "${key}" }`, `"serviceKey": "${key}", "kept": 1 }`), 'c'.repeat(64));
  assert.deepEqual(JSON.parse(again).preview, { serviceKey: 'c'.repeat(64), kept: 1 });
  assert.equal(outsidePreview(again), before);
});

/// A capture that answers `dart run bin/service_key.dart --json` with a
/// new pair each time, as the tool does: the pairs it made, in order.
function minting() {
  const made = [];
  const capture = async (command) => {
    if (command !== 'dart') return { code: 0, out: '' };
    const n = made.length + 1;
    const pair = { key: n.toString(16).repeat(64).slice(0, 64), secret: (n + 8).toString(16).repeat(64).slice(0, 64) };
    made.push(pair);
    return { code: 0, out: `Building package executable...\n${JSON.stringify(pair)}\n` };
  };
  return { made, capture };
}

test("previews' own secrets are made new, set where they live, and shown to nobody", async () => {
  const { text, configFile } = configCopy();
  const dry = fake({ capture: minting().capture, configFile });
  assert.equal(await main(['preview', 'secrets'], dry), 0);
  assert.equal(dry.started.length, 0);
  assert.equal(readFileSync(configFile, 'utf8'), text, 'nothing written without --apply');

  const { made, capture } = minting();
  const ctx = fake({ capture, configFile });
  assert.equal(await main(['preview', 'secrets', '--apply'], ctx), 0);
  const [service, house] = made;
  const [onPages, onRelay] = ctx.started;
  assert.deepEqual(onPages.args.slice(2), ['pages', 'secret', 'put', 'OH_SERVICE_SECRET', '--project-name', 'open-hearts', '--env', 'preview']);
  assert.equal(onPages.input, service.secret);
  assert.deepEqual(onRelay.args.slice(2), ['secret', 'put', 'OH_HOUSE_SECRET', '--env', 'preview']);
  assert.ok(onRelay.cwd.endsWith('service/do'));
  assert.equal(onRelay.input, house.secret, 'a pair of its own, not the service\'s');
  assert.equal(ctx.started.length, 2);
  // The public halves are written, beside production's, and the rest kept.
  const written = readFileSync(configFile, 'utf8');
  assert.deepEqual(JSON.parse(written).preview, { serviceKey: service.key, houseKey: house.key });
  assert.equal(outsidePreview(written), outsidePreview(text));
  // Neither secret is said; the keys are.
  const said = [...ctx.said, ...ctx.warned].join('\n');
  assert.ok(!said.includes(service.secret) && !said.includes(house.secret));
  assert.ok(said.includes(service.key) && said.includes(house.key));
});

test("the house's key is made new, its secret set on the relay and shown to nobody, and its key written beside the service's", async () => {
  const { text, configFile } = configCopy();
  const dry = fake({ capture: minting().capture, configFile });
  assert.equal(await main(['house', 'key'], dry), 0);
  assert.equal(dry.started.length, 0);
  assert.equal(readFileSync(configFile, 'utf8'), text, 'nothing written without --apply');

  const { made, capture } = minting();
  const ctx = fake({ capture, configFile });
  assert.equal(await main(['house', 'key', '--apply'], ctx), 0);
  const [pair] = made;
  assert.deepEqual(ctx.started.map((s) => [s.args.slice(2), s.input, s.cwd.endsWith('service/do')]), [[['secret', 'put', 'OH_HOUSE_SECRET'], pair.secret, true]]);
  const written = readFileSync(configFile, 'utf8');
  assert.equal(JSON.parse(written).houseKey, pair.key);
  assert.deepEqual({ ...JSON.parse(written), houseKey: undefined }, { ...JSON.parse(text), houseKey: undefined }, 'nothing else changed');
  assert.match(written, new RegExp(`"serviceKey": "${JSON.parse(text).serviceKey}",\n  "houseKey": "${pair.key}",\n`));
  const said = [...ctx.said, ...ctx.warned].join('\n');
  assert.ok(!said.includes(pair.secret));
  assert.ok(said.includes(pair.key));
  // Made again, it is replaced where it is.
  const again = withHouseKey(written, 'e'.repeat(64));
  assert.equal(JSON.parse(again).houseKey, 'e'.repeat(64));
  assert.equal(again.split('"houseKey"').length, 2);
});

test("previews' secrets: without a key pair nothing is set, and what was said is not repeated", async () => {
  const { text, configFile } = configCopy();
  const ctx = fake({ capture: async () => ({ code: 1, out: 'c'.repeat(64) }), configFile });
  assert.equal(await main(['preview', 'secrets', '--apply'], ctx), 1);
  assert.equal(ctx.started.length, 0);
  assert.equal(readFileSync(configFile, 'utf8'), text);
  assert.ok(!ctx.warned.join('\n').includes('c'.repeat(64)));
});

test("an invitation is an account on the previews' store that nobody bought, and its code brings a device into it", async () => {
  const previews = memoryStore();
  const ctx = fake({ previewStore: async () => previews });
  assert.equal(await main(['preview', 'invite'], ctx), 0);
  assert.equal(previews.rows.size, 0, 'nothing made without --apply');
  assert.equal(await main(['preview', 'invite', '--apply'], ctx), 0);
  const said = ctx.said.join('\n');
  const code = /its code: (\S+)/.exec(said)[1];
  const account = /account ([0-9a-f]{32})/.exec(said)[1];
  const now = ctx.now();
  const device = 'd'.repeat(64);
  assert.equal((await redeemBackup(device, backupCodeOf(code), previews, { now })).status, 200);
  const held = await entitlementOf(previews, device, { now });
  assert.equal(held.account, account);
  assert.equal(held.licensed_until, dayAfter(now, INVITED_DAYS));
  assert.equal((await ctx.store()).rows.size, 0, "nothing in production's store");

  // Nobody bought it, so it holds no device: another invitation's code
  // brings the device into that one, as it would from an account whose
  // subscription had ended, with no dropping first.
  ctx.said.length = 0;
  assert.equal(await main(['preview', 'invite', '--apply'], ctx), 0);
  const other = /its code: (\S+)/.exec(ctx.said.join('\n'))[1];
  assert.equal((await redeemBackup(device, backupCodeOf(other), previews, { now })).status, 200);
  assert.notEqual((await entitlementOf(previews, device, { now })).account, account);
});

test('the preview relay is deployed from what is checked out, without the PhotoDNA module, once previews have a key', async () => {
  // HEAD is not main: a preview is not held to it.
  const capture = async (command, args) => ({ code: 0, out: args.includes('HEAD') ? 'def5678\n' : args.includes('origin/main') ? 'abc1234\n' : '' });
  const keyless = fake({ capture });
  assert.equal(await main(['deploy', 'relay', '--preview', '--apply'], keyless), 1);
  assert.match(keyless.said.join('\n'), /no preview\.serviceKey/);
  assert.equal(keyless.started.length, 0);
  const houseless = fake({ capture, config: { preview: { serviceKey: 'b'.repeat(64) } } });
  assert.equal(await main(['deploy', 'relay', '--preview', '--apply'], houseless), 1);
  assert.match(houseless.said.join('\n'), /no preview\.houseKey/);
  assert.equal(houseless.started.length, 0);
  const ctx = fake({ capture, config: { preview: { serviceKey: 'b'.repeat(64), houseKey: 'c'.repeat(64) } } });
  assert.equal(await main(['deploy', 'relay', '--preview', '--apply'], ctx), 0);
  assert.deepEqual(ctx.started.map((s) => s.args.slice(2)), [['deploy', '--env', 'preview']]);
  assert.ok(ctx.started[0].cwd.endsWith('service/do'));
  // And production's is still held to main.
  const production = fake({ capture, config: { preview: { serviceKey: 'b'.repeat(64) } } });
  assert.equal(await main(['deploy', 'relay', '--apply'], production), 1);
  assert.equal(production.started.length, 0);
});
