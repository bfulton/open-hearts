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
import { Failed, root } from './env.mjs';
import { releaseProblems } from './gate.mjs';
import { commandOf, main, markdown, parse } from './oh.mjs';
import { INVITED_DAYS, withHouseKey, withPreviewKey } from './preview.mjs';
import { PREVIEWS_KEPT, sweepable } from './release.mjs';
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

/// A deployment of the site as Cloudflare lists one, made [minute]
/// minutes into a day. [aliases] makes it live; [status] is how its
/// last stage, the deploy, ended.
const deployment = (id, environment, minute, aliases = null, status = 'success') => ({
  id,
  environment,
  created_on: new Date(Date.UTC(2026, 9, 31, 0, minute)).toISOString().replace('Z', '000Z'),
  aliases,
  latest_stage: { name: 'deploy', status },
  deployment_trigger: { metadata: { branch: environment === 'production' ? 'main' : 'dev' } },
});

/// A fake of the Pages project's deployments API holding [deployments],
/// newest first, 25 to a page. With [shifted], every page after the
/// first starts one place early, as when a deployment is made while
/// the list is read. Deleting an id in [refused] fails. [listing], when
/// given, answers every GET instead. [asked] records each request,
/// [deleted] each id deleted.
function pagesApi(deployments, { shifted = false, refused = [], listing = null } = {}) {
  const held = [...deployments];
  const api = { asked: [], deleted: [] };
  api.fetch = async (url, init = {}) => {
    const u = new URL(String(url));
    const method = init.method ?? 'GET';
    api.asked.push(`${method} ${u.pathname.replace('/client/v4/accounts/acct/pages/projects/open-hearts/deployments', '')}${u.search}`);
    assert.equal(u.origin, 'https://api.cloudflare.com');
    assert.match(u.pathname, /^\/client\/v4\/accounts\/acct\/pages\/projects\/open-hearts\/deployments/);
    assert.equal(init.headers?.Authorization, 'Bearer tok');
    if (method === 'GET') {
      if (listing) return listing();
      const page = Number(u.searchParams.get('page'));
      const per = Number(u.searchParams.get('per_page'));
      const from = (page - 1) * per - (shifted && page > 1 ? 1 : 0);
      return Response.json({ success: true, errors: [], result: held.slice(from, from + per) });
    }
    const id = decodeURIComponent(u.pathname.split('/').at(-1));
    if (refused.includes(id)) return Response.json({ success: false, errors: [{ code: 8000034, message: 'not now' }] }, { status: 400 });
    api.deleted.push(id);
    return Response.json({ success: true, errors: [], result: null });
  };
  return api;
}

const cloudflareEnv = { CLOUDFLARE_API_TOKEN: 'tok', CLOUDFLARE_ACCOUNT_ID: 'acct' };
const ids = (list) => list.map((d) => d.id);

test('a sweep keeps the newest previews and production deployments, the newest that succeeded, and every live one', () => {
  const listed = [
    deployment('p5', 'production', 50, ['https://openhearts.game', 'https://play.openhearts.game']),
    deployment('v8', 'preview', 48, ['https://dev.open-hearts.pages.dev']),
    deployment('p4', 'production', 45),
    deployment('v7', 'preview', 44),
    deployment('v6', 'preview', 43),
    deployment('v5', 'preview', 42),
    deployment('v4', 'preview', 41),
    deployment('p3', 'production', 40),
    deployment('v3', 'preview', 30),
    // The newest deployment of a branch nobody has deployed to since:
    // still live on its branch's address.
    deployment('v2', 'preview', 20, ['https://pr38.open-hearts.pages.dev']),
    deployment('p2', 'production', 15),
    deployment('p1', 'production', 10),
    deployment('v1', 'preview', 5),
  ];
  assert.equal(PREVIEWS_KEPT, 5);
  assert.deepEqual(ids(sweepable(listed)), ['v3', 'p2', 'p1', 'v1']);
  assert.deepEqual(ids(sweepable([...listed].reverse())), ['v3', 'p2', 'p1', 'v1'], 'ordered by date, not by how they were listed');
  assert.deepEqual(ids(sweepable(listed, 0)), ['v7', 'v6', 'v5', 'v4', 'v3', 'p2', 'p1', 'v1'], 'only the live ones kept');
  assert.deepEqual(ids(sweepable(listed, 7)), ['p2', 'p1', 'v1']);
  assert.deepEqual(ids(sweepable(listed.filter((d) => d.environment === 'production'))), ['p2', 'p1']);
  assert.deepEqual(sweepable([]), []);

  // Rolled back: the live deployment is older than three that are not
  // live, and is kept.
  const rolledBack = [
    deployment('p4', 'production', 40),
    deployment('p3', 'production', 30),
    deployment('p2', 'production', 20),
    deployment('p1', 'production', 10, ['https://openhearts.game']),
    deployment('p0', 'production', 5),
  ];
  assert.deepEqual(ids(sweepable(rolledBack)), ['p0']);
  // Any environment but production counts as a preview.
  assert.deepEqual(ids(sweepable([deployment('x2', 'staging', 20), deployment('x1', 'staging', 10)], 1)), ['x1']);

  // Failed uploads don't push out the deployments a rollback needs: the
  // newest three that succeeded are kept too.
  const failing = [
    deployment('n', 'production', 60, ['https://openhearts.game']),
    deployment('f2', 'production', 55, null, 'failure'),
    deployment('f1', 'production', 50, null, 'canceled'),
    deployment('l', 'production', 40),
    deployment('r1', 'production', 30),
    deployment('r2', 'production', 20),
  ];
  assert.deepEqual(ids(sweepable(failing)), ['r2']);
  const manyFailed = [
    ...[5, 4, 3, 2, 1].map((n) => deployment(`f${n}`, 'production', 50 + n, null, 'failure')),
    deployment('s3', 'production', 40, ['https://openhearts.game']),
    deployment('s2', 'production', 30),
    deployment('s1', 'production', 20),
    deployment('s0', 'production', 10),
  ];
  assert.deepEqual(ids(sweepable(manyFailed)), ['f2', 'f1', 's0'], 'the newest three kept, failed or not, and the newest three that succeeded');
  // Only a deploy stage that succeeded counts as succeeded.
  const unfinished = { ...deployment('b', 'preview', 30), latest_stage: { name: 'build', status: 'success' } };
  assert.deepEqual(ids(sweepable([deployment('f', 'preview', 40, null, 'failure'), unfinished, deployment('ok', 'preview', 20), deployment('old', 'preview', 10)], 1)), ['b', 'old']);

  // Without a readable date for every deployment, which are newest can't
  // be known, and nothing is deleted.
  for (const created_on of [undefined, null, '', 'yesterday']) {
    const odd = { ...deployment('odd', 'preview', 30), created_on };
    assert.throws(() => sweepable([odd, ...listed]), (e) => e instanceof Failed && /deployment odd without a readable date \(.*\), so nothing was deleted/.test(e.message), String(created_on));
  }
});

test('oh deploy prune lists what would go, reading every page once, and with --apply deletes it, trying every one', async () => {
  // Fifty: production's newest three, then previews, the newest of them
  // live. They come in two full pages and a third, which a deployment
  // made while listing pushes one over into.
  const fifty = [
    deployment('p3', 'production', 600, ['https://openhearts.game']),
    deployment('p2', 'production', 590),
    deployment('p1', 'production', 580),
    ...Array.from({ length: 47 }, (_, i) => deployment(`v${String(47 - i).padStart(2, '0')}`, 'preview', 500 - i, i === 0 ? ['https://dev.open-hearts.pages.dev'] : null)),
  ];
  const doomedIds = fifty.slice(8).map((d) => d.id);
  const kept = "Kept: of the previews, the newest 5 and the newest 5 that succeeded; of production's, the newest 3 and the newest 3 that succeeded; and every live one.";

  const dry = pagesApi(fifty, { shifted: true });
  const looked = fake({ env: cloudflareEnv, fetch: dry.fetch });
  assert.equal(await main(['deploy', 'prune'], looked), 0);
  assert.deepEqual(dry.asked, ['GET ?per_page=25&page=1', 'GET ?per_page=25&page=2', 'GET ?per_page=25&page=3']);
  assert.deepEqual(dry.deleted, []);
  const would = looked.said.filter((l) => l.startsWith('would delete '));
  assert.deepEqual(would.slice(0, -1).map((l) => l.split(' ')[2]), doomedIds.map((id) => id.slice(0, 8)), 'each once, though one was listed twice');
  assert.equal(would[0], 'would delete v42  2026-10-31 08:15  dev (preview)');
  assert.equal(looked.said.at(-1), `would delete 42 of 50 deployment(s); --apply deletes them. ${kept}`);

  const real = pagesApi(fifty);
  const swept = fake({ env: cloudflareEnv, fetch: real.fetch });
  assert.equal(await main(['deploy', 'prune', '--apply'], swept), 0);
  assert.deepEqual(real.deleted, doomedIds);
  assert.deepEqual(real.asked.filter((a) => a.startsWith('DELETE')), doomedIds.map((id) => `DELETE /${id}`));
  assert.equal(swept.said.at(-1), `deleted 42 of 50 deployment(s). ${kept}`);

  const fewer = pagesApi(fifty);
  assert.equal(await main(['deploy', 'prune', '--keep', '40', '--apply'], fake({ env: cloudflareEnv, fetch: fewer.fetch })), 0);
  assert.deepEqual(fewer.deleted, doomedIds.slice(35));

  // A failed upload is said to be one.
  const failed = fake({ env: cloudflareEnv, fetch: pagesApi([...fifty.slice(0, 8), deployment('vf', 'preview', 1, null, 'failure')]).fetch });
  assert.equal(await main(['deploy', 'prune'], failed), 0);
  assert.equal(failed.said[0], 'would delete vf  2026-10-31 00:01  dev (preview, failed)');

  // Cloudflare refuses one: the rest are deleted all the same, and the
  // sweep fails saying so.
  const refusing = pagesApi(fifty, { refused: ['v30'] });
  const partly = fake({ env: cloudflareEnv, fetch: refusing.fetch });
  assert.equal(await main(['deploy', 'prune', '--apply'], partly), 1);
  assert.deepEqual(refusing.deleted, doomedIds.filter((id) => id !== 'v30'));
  assert.ok(partly.said.some((l) => /^not deleted v30 .*: Cloudflare said 400 to DELETE deployments\/v30: .*not now/.test(l)));
  assert.match(partly.warned.join('\n'), /deleted 41 of 42 old deployment\(s\); 1 could not be deleted \(above\)/);

  // Nothing to delete.
  const tidy = fake({ env: cloudflareEnv, fetch: pagesApi(fifty.slice(0, 8)).fetch });
  assert.equal(await main(['deploy', 'prune', '--apply'], tidy), 0);
  assert.deepEqual(tidy.said, [`nothing to delete among 8 deployment(s). ${kept}`]);

  // Asked wrongly, or unable to read the list: nothing is deleted.
  for (const keep of ['many', '', '-1']) assert.equal(await main(['deploy', 'prune', '--keep', keep, '--apply'], fake({ env: cloudflareEnv, fetch: real.fetch })), 2, `--keep ${JSON.stringify(keep)}`);
  const bare = fake({ fetch: real.fetch });
  assert.equal(await main(['deploy', 'prune', '--apply'], bare), 1);
  assert.match(bare.warned.join('\n'), /needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID/);
  const refusedList = async (answer, pattern) => {
    const api = pagesApi(fifty, { listing: answer });
    const ctx = fake({ env: cloudflareEnv, fetch: api.fetch });
    assert.equal(await main(['deploy', 'prune', '--apply'], ctx), 1, String(pattern));
    assert.match(ctx.warned.join('\n'), pattern);
    assert.deepEqual(api.deleted, []);
  };
  await refusedList(() => Response.json({ success: false, errors: [{ code: 10000, message: 'Authentication error' }] }, { status: 403 }), /Cloudflare said 403 to GET deployments\?per_page=25&page=1: .*Authentication error/);
  await refusedList(() => Response.json({ success: true, errors: [], result: [] }, { status: 500 }), /Cloudflare said 500 to GET deployments\?per_page=25&page=1/);
  await refusedList(() => new Response('<html>a proxy said no</html>', { status: 200 }), /Cloudflare said 200 to GET deployments\?per_page=25&page=1: not JSON$/);
  for (const result of [undefined, null, { not: 'a list' }, 'none']) {
    await refusedList(() => Response.json({ success: true, errors: [], result }), /Cloudflare's answer to GET deployments\?per_page=25&page=1 has no list of deployments/);
  }
  await refusedList(() => Response.json({ success: true, errors: [], result: [{ ...fifty[9], created_on: null }, ...fifty.slice(0, 9)] }), /without a readable date \(null\), so nothing was deleted/);
  const unreachable = fake({ env: cloudflareEnv, fetch: async () => { throw new TypeError('fetch failed'); } });
  assert.equal(await main(['deploy', 'prune'], unreachable), 1);
  assert.match(unreachable.warned.join('\n'), /Cloudflare did not answer GET deployments\?per_page=25&page=1: fetch failed/);
  assert.equal(real.deleted.length, doomedIds.length, 'none of those deleted anything');
});

test("production's site deploy deletes old deployments first and deploys even if that fails; a preview's deletes nothing", async () => {
  const git = (answers) => async (command, args) => ({ code: 0, out: answers[args.join(' ')] ?? '' });
  const onMain = git({ 'rev-parse HEAD': 'abc1234\n', 'rev-parse origin/main': 'abc1234\n', 'rev-parse --abbrev-ref HEAD': 'main\n' });
  // Rolled back to p1, which is live; seven previews.
  const listed = [
    deployment('p4', 'production', 50),
    deployment('p3', 'production', 40),
    deployment('p2', 'production', 30),
    deployment('p1', 'production', 20, ['https://openhearts.game']),
    deployment('p0', 'production', 10),
    ...[7, 6, 5, 4, 3, 2, 1].map((n) => deployment(`v${n}`, 'preview', n)),
  ];
  /// A deploy where deploy.sh exits [published], against [api]: what
  /// happened, in order. With [relay], deploy all's relay before it,
  /// with no PhotoDNA module to fetch and a throwaway module folder.
  const deploy = async (argv, api, { published = 0, capture = onMain, relay = false } = {}) => {
    const site = settled();
    const order = [];
    const ctx = fake({
      ...site,
      ...(relay ? { moduleDir: join(mkdtempSync(join(tmpdir(), 'relay-')), 'private', 'photodna'), config: { ...site.config, photodna: { ...site.config.photodna, module: undefined } } } : {}),
      env: cloudflareEnv,
      capture,
      fetch: async (url, init) => {
        if (!String(url).startsWith('https://api.cloudflare.com/')) return site.fetch(url, init);
        order.push(`${init?.method ?? 'GET'} cloudflare`);
        return api.fetch(url, init);
      },
    });
    ctx.run = async (command, args) => {
      order.push(`${command.split('/').at(-1)} ${args.join(' ')}`);
      return published;
    };
    const code = await main(argv, ctx);
    return { code, order, said: ctx.said.join('\n'), warned: ctx.warned.join('\n') };
  };

  // The live deployment, older than three that are not, is kept: it is
  // the one a bad deploy rolls back to. Five previews are kept.
  const api = pagesApi(listed);
  const done = await deploy(['deploy', 'site', '--apply'], api);
  assert.equal(done.code, 0, done.warned);
  assert.deepEqual(done.order, ['GET cloudflare', 'DELETE cloudflare', 'DELETE cloudflare', 'DELETE cloudflare', 'deploy.sh main']);
  assert.deepEqual(api.deleted, ['p0', 'v2', 'v1']);
  assert.match(done.said, /deleted v1 .* dev \(preview\)\ndeleted 3 of 12 deployment\(s\)\. Kept: /);
  assert.equal(done.warned, '');

  // The same from deploy all, after its relay.
  const viaAll = await deploy(['deploy', 'all', '--apply'], pagesApi(listed), { relay: true });
  assert.equal(viaAll.code, 0, viaAll.warned);
  assert.deepEqual(viaAll.order.slice(-5), ['GET cloudflare', 'DELETE cloudflare', 'DELETE cloudflare', 'DELETE cloudflare', 'deploy.sh main']);
  assert.ok(viaAll.order.slice(0, -5).every((o) => o.startsWith('npx ')), viaAll.order.join(', '));

  // Old deployments are deleted even if the publish then fails: they
  // are the ones oh deploy prune would delete anyway.
  const unpublished = await deploy(['deploy', 'site', '--apply'], pagesApi(listed), { published: 1 });
  assert.equal(unpublished.code, 1);
  assert.equal(unpublished.order.at(-1), 'deploy.sh main');

  // A sweep that fails is reported, and the deploy goes on.
  const failures = [
    [pagesApi(listed, { listing: () => Response.json({ success: false, errors: [{ code: 7003, message: 'no route' }] }, { status: 500 }) }), /^could not delete old deployments: Cloudflare said 500 to GET deployments\?per_page=25&page=1: .*no route.*\. Deploying anyway; \.\/oh deploy prune --apply tries again\.$/],
    [pagesApi(listed, { refused: ['p0'] }), /^could not delete old deployments: deleted 2 of 3 old deployment\(s\); 1 could not be deleted \(above\)\. Deploying anyway; /],
    [pagesApi(listed, { listing: () => Response.json({ success: true, result: { not: 'a list' } }) }), /^could not delete old deployments: Cloudflare's answer .* has no list of deployments/],
  ];
  for (const [failing, pattern] of failures) {
    const went = await deploy(['deploy', 'site', '--apply'], failing);
    assert.equal(went.code, 0, went.warned);
    assert.equal(went.order.at(-1), 'deploy.sh main');
    assert.match(went.warned, pattern);
  }

  // A dry run says it will delete old deployments, and asks Cloudflare
  // nothing.
  const dry = await deploy(['deploy', 'site'], pagesApi(listed));
  assert.equal(dry.code, 0);
  assert.deepEqual(dry.order, []);
  assert.match(dry.said, /first deletes old deployments: oh deploy prune lists the ones that would go/);

  // A preview's deploy publishes and deletes nothing.
  const preview = await deploy(['deploy', 'site', '--label', 'my-change', '--apply'], pagesApi(listed), { capture: git({ 'rev-parse --abbrev-ref HEAD': 'my-change\n' }) });
  assert.equal(preview.code, 0);
  assert.deepEqual(preview.order, ['deploy.sh my-change']);
  assert.doesNotMatch(preview.said, /delete/);

  // An empty label is refused, not read as no label: on main that would
  // be a production deploy.
  const empty = await deploy(['deploy', 'site', '--label', '', '--apply'], pagesApi(listed));
  assert.equal(empty.code, 2);
  assert.deepEqual(empty.order, []);
  assert.match(empty.warned, /--label takes a value/);
});

test('a relay deploy says what it lacks before it starts', async () => {
  const capture = async (command, args) => ({ code: command === 'docker' ? 1 : 0, out: args.includes('HEAD') || args.includes('origin/main') ? 'abc\n' : '' });
  const ctx = fake({ capture });
  assert.equal(await main(['deploy', 'relay'], ctx), 0);
  assert.match(ctx.said.join('\n'), /not ready: needs Docker, running/);
  assert.equal(await main(['deploy', 'relay', '--apply'], ctx), 1);
  assert.equal(ctx.started.length, 0);
});

test('a relay deploy is built before anything is uploaded, and what served is put back if the deploy fails after its upload', async () => {
  const moduleDir = join(mkdtempSync(join(tmpdir(), 'relay-')), 'private', 'photodna');
  /// A production relay deploy where `wrangler deploy --dry-run` exits
  /// [built], `wrangler deploy` [deployed] and `wrangler rollback`
  /// [rolled]; `deployments status` says [serving] before the deploy and
  /// [after] once it has run: one version at all of the traffic, its
  /// versions as they are split, or none.
  const run = async ({ built = 0, deployed = 0, rolled = 0, serving = 'v1', after = serving } = {}) => {
    let done = false;
    const versions = (v) => (Array.isArray(v) ? v : v ? [{ version_id: v, percentage: 100 }] : []);
    const status = (v) => `▲ [WARNING] Proxy environment variables detected.\n${JSON.stringify({ id: 'd', versions: versions(v) }, null, 2)}\nnpm notice\n`;
    const ctx = fake({
      config: { appOrigin: 'https://play.example', houseKey: 'd'.repeat(64) },
      moduleDir,
      capture: async (command, args) => {
        if (args.includes('HEAD') || args.includes('origin/main')) return { code: 0, out: 'abc\n' };
        if (args.includes('deployments')) return { code: 0, out: status(done ? after : serving) };
        return { code: 0, out: '' };
      },
    });
    ctx.run = async (command, args, options = {}) => {
      ctx.started.push({ command, args, ...options });
      if (args.includes('--dry-run')) return built;
      if (args.includes('rollback')) return rolled;
      done = true;
      return deployed;
    };
    const code = await main(['deploy', 'relay', '--apply'], ctx);
    return { code, ran: ctx.started.map((s) => s.args.slice(2)), warned: ctx.warned.join('\n') };
  };

  // Its build or its image fails: nothing is uploaded.
  const unbuilt = await run({ built: 1 });
  assert.equal(unbuilt.code, 1);
  assert.deepEqual(unbuilt.ran, [['deploy', '--dry-run']]);
  assert.match(unbuilt.warned, /relay: not deployed: its build or the house's image failed \(wrangler deploy --dry-run exited 1\), and nothing was uploaded/);

  // Built, then deployed.
  const fine = await run();
  assert.equal(fine.code, 0);
  assert.deepEqual(fine.ran, [['deploy', '--dry-run'], ['deploy']]);

  // The deploy fails before its upload: what served still does.
  const before = await run({ deployed: 1 });
  assert.equal(before.code, 1);
  assert.deepEqual(before.ran, [['deploy', '--dry-run'], ['deploy']]);
  assert.match(before.warned, /relay: wrangler deploy exited 1; v1 still serves/);

  // The deploy fails after its upload: what served before is put back.
  const after = await run({ deployed: 1, after: 'v2' });
  assert.equal(after.code, 1);
  assert.deepEqual(after.ran, [['deploy', '--dry-run'], ['deploy'], ['rollback', 'v1', '--message', 'relay: its deploy failed after the upload', '--yes']]);
  assert.match(after.warned, /relay: wrangler deploy exited 1 with v2 live; v1, which served before, serves again/);

  // And says so when that fails too.
  const stuck = await run({ deployed: 1, after: 'v2', rolled: 1 });
  assert.equal(stuck.code, 1);
  assert.match(stuck.warned, /with v2 live, and putting v1 back failed too \(wrangler rollback exited 1\)/);

  // What served can't be told: nothing is rolled back blind.
  const blind = await run({ deployed: 1, serving: null, after: 'v2' });
  assert.equal(blind.code, 1);
  assert.equal(blind.ran.length, 2);
  assert.match(blind.warned, /which version serves can't be told: see wrangler deployments status, from service\/do/);
  const split = await run({ deployed: 1, serving: [{ version_id: 'v0', percentage: 50 }, { version_id: 'v1', percentage: 50 }], after: 'v2' });
  assert.equal(split.ran.length, 2, 'nor when its traffic was split');
  assert.match(split.warned, /can't be told/);
  const partial = await run({ deployed: 1, serving: [{ version_id: 'v1', percentage: 90 }], after: 'v2' });
  assert.equal(partial.ran.length, 2, 'nor when one version had only some of it');
  const lost = await run({ deployed: 1, after: null });
  assert.equal(lost.ran.length, 2, 'nor when what serves after the deploy can\'t be told');
  assert.match(lost.warned, /can't be told/);
  assert.ok(!existsSync(moduleDir), 'and the module folder is gone after each');
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
  // Made again, it is replaced where it is: production's, and not the
  // previews' beside it.
  const again = withHouseKey(written, 'e'.repeat(64));
  assert.equal(JSON.parse(again).houseKey, 'e'.repeat(64));
  assert.equal(again.match(/^ *"houseKey": /gm).length, 1);
  assert.deepEqual(JSON.parse(again).preview, JSON.parse(text).preview, "the previews' keys as they were");
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
  assert.deepEqual(ctx.started.map((s) => s.args.slice(2)), [['deploy', '--dry-run', '--env', 'preview'], ['deploy', '--env', 'preview']]);
  assert.ok(ctx.started.every((s) => s.cwd.endsWith('service/do')));
  // And production's is still held to main.
  const production = fake({ capture, config: { preview: { serviceKey: 'b'.repeat(64) } } });
  assert.equal(await main(['deploy', 'relay', '--apply'], production), 1);
  assert.equal(production.started.length, 0);
});
