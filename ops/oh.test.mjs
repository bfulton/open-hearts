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
import { rejected, reshaped } from './setup.mjs';
import { KNOWN_ROW } from '../service/do/checkers.mjs';
import { configOf } from '../service/functions/config.mjs';
import { memoryStore } from '../service/functions/rows.mjs';
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
  assert.equal(await main(['secret', 'set', 'OH_SERVICE_SECRET', '--apply'], ctx), 0);
  assert.deepEqual(
    ctx.started.map((s) => s.args.slice(2)),
    [
      ['pages', 'secret', 'put', 'OH_SERVICE_SECRET', '--project-name', 'open-hearts'],
      ['pages', 'secret', 'put', 'OH_SERVICE_SECRET', '--project-name', 'open-hearts', '--env', 'preview'],
    ],
  );
  assert.ok(ctx.started.every((s) => s.input === 's3cret'));
  assert.ok(!ctx.said.join('\n').includes('s3cret'), 'never said back');
  const relay = fake({ readSecret: async () => 'x' });
  assert.equal(await main(['secret', 'set', 'OH_JUROR_SECRET', '--apply'], relay), 0);
  assert.deepEqual(relay.started.map((s) => s.args.slice(2)), [['secret', 'put', 'OH_JUROR_SECRET']]);
  // One set only once it is issued, as a checker's credentials are: the
  // relay's too, and only the relay's.
  for (const name of ['OH_ARACHNID_USERNAME', 'OH_ARACHNID_PASSWORD', 'OH_PHOTODNA_KEY', 'OH_NCMEC_USERNAME', 'OH_NCMEC_PASSWORD']) {
    const optional = fake({ readSecret: async () => 'x' });
    assert.equal(await main(['secret', 'set', name, '--apply'], optional), 0, name);
    assert.deepEqual(optional.started.map((s) => [s.args.slice(2), s.cwd.endsWith('service/do')]), [[['secret', 'put', name], true]], name);
  }
  assert.equal(await main(['secret', 'set', 'OH_NOT_A_SECRET', '--apply'], fake()), 2);
});
