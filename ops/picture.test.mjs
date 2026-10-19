// oh picture allow: a picture the automatic check hid, put back, and
// kept from being hidden again; oh picture hide: one withheld at the
// relay by its digest; and oh picture report: one the operator found,
// handed to the relay to act on (ops/picture.mjs).
//
//   node --test ops/*.test.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { main } from './oh.mjs';
import { REPORT_KEPT_S } from '../service/do/known.mjs';
import { PICTURES_ROW, WITHHELD_FOR_MS, allowedOf, allowing, withheldOf, withholding } from '../service/functions/pictures.mjs';
import { memoryStore } from '../service/functions/rows.mjs';

const now = Date.parse('2026-10-19T12:00:00Z');
const digest = 'ab'.repeat(32);
const other = 'cd'.repeat(32);

function context(store) {
  const said = [];
  return { said, env: {}, log: (line) => said.push(line), warn: (line) => said.push(`oh: ${line}`), store: async () => store, now: () => now };
}

test('picture allow: says what it would do, and with --apply puts the picture back and allows it', async () => {
  const store = memoryStore();
  await store.put(...PICTURES_ROW, withholding(null, digest, now - 1000));
  const dry = context(store);
  assert.equal(await main(['picture', 'allow', digest.toUpperCase()], dry), 0);
  assert.deepEqual(dry.said, [`${digest}: withheld at the relay`, 'would stop withholding it, and keep the check from hiding it for 30 days', 'nothing changed; --apply does it']);
  assert.ok(withheldOf(await store.get(...PICTURES_ROW), now).has(digest), 'a dry run changes nothing');

  const done = context(store);
  assert.equal(await main(['picture', 'allow', digest, '--apply'], done), 0);
  const row = await store.get(...PICTURES_ROW);
  assert.ok(!withheldOf(row, now).has(digest));
  assert.ok(allowedOf(row, now).has(digest));
  assert.match(done.said.at(-1), /^done:/);

  const again = context(store);
  await main(['picture', 'allow', digest], again);
  assert.equal(again.said[0], `${digest}: not withheld, allowed already`);
});

test('a picture is named by its SHA-256, or by the address of its copy', async () => {
  for (const command of ['allow', 'hide']) {
    for (const wrong of ['ab'.repeat(31), `https://pictures.openhearts.game/review/${'ab'.repeat(31)}.jpg`, `${digest}.png`, `${digest}x`, '']) {
      const ctx = context(memoryStore());
      assert.equal(await main(['picture', command, wrong], ctx), 2, `${command} ${wrong}`);
      assert.match(ctx.said.join('\n'), /name the picture by its SHA-256/);
    }
    for (const right of [`https://pictures.openhearts.game/review/${digest}.jpg`, `/review/${digest}.jpg`, ` ${digest} `]) {
      const ctx = context(memoryStore());
      assert.equal(await main(['picture', command, right], ctx), 0, `${command} ${right}`);
      assert.match(ctx.said[0], new RegExp(`^${digest}: `));
    }
  }
});

test('picture hide: says what it would do, and with --apply withholds the picture for 30 days, over its having been allowed', async () => {
  const store = memoryStore();
  await store.put(...PICTURES_ROW, allowing(withholding(null, other, now - 1000), digest, now - 1000));
  const dry = context(store);
  assert.equal(await main(['picture', 'hide', digest], dry), 0);
  assert.deepEqual(dry.said, [
    `${digest}: not withheld, allowed already`,
    'would withhold it at the relay for 30 days from now, wherever it was put out, as a picture taken off an account is, and no longer allow it',
    'nothing changed; --apply does it',
  ]);
  assert.ok(!withheldOf(await store.get(...PICTURES_ROW), now).has(digest), 'a dry run changes nothing');

  const done = context(store);
  assert.equal(await main(['picture', 'hide', `https://pictures.openhearts.game/review/${digest}.jpg`, '--apply'], done), 0);
  const row = await store.get(...PICTURES_ROW);
  assert.ok(withheldOf(row, now).has(digest));
  assert.ok(withheldOf(row, now + WITHHELD_FOR_MS - 1).has(digest), 'for 30 days');
  assert.ok(!withheldOf(row, now + WITHHELD_FOR_MS).has(digest), 'and no longer');
  assert.ok(!allowedOf(row, now).has(digest), 'no longer allowed');
  assert.ok(withheldOf(row, now).has(other), 'what else was withheld still is');
  assert.match(done.said.at(-1), /^done: the relay withholds it/);
});

/// The pictures bucket as restObjects reaches it: keys only, so a test
/// can see that a picture's bytes are never asked for.
const listing = (keys) => ({ list: async (prefix) => keys.filter((k) => k.startsWith(prefix)), read: async () => assert.fail('the picture read') });

/// A context for oh picture report: the relay answering [answers] in
/// turn, and what it was asked.
function reporting(store, keys, answers) {
  const ctx = context(store);
  ctx.asked = [];
  ctx.pictures = async () => listing(keys);
  ctx.relay = async () => 'https://relay.example';
  ctx.carryOptions = { tries: 4, wait: 0, sleep: async () => {} };
  ctx.fetch = async (url, init) => {
    ctx.asked.push({ url, body: JSON.parse(init.body) });
    const [status, body] = answers.shift();
    return Response.json(body, { status });
  };
  return ctx;
}

const A = '0123456789abcdef0123456789abcdef';
const C = 'abcdefabcdefabcdefabcdefabcdefab';

test('picture report: says who put it out and what the relay would do; with --apply hands it to the relay, asked again while the store has not shown it', async () => {
  const store = memoryStore();
  const keys = [`review/${digest}.jpg`, `seen/${A}/${digest}`, `seen/${A}/${other}`];
  const dry = reporting(store, keys, []);
  assert.equal(await main(['picture', 'report', digest, '--account', C, '--how', 'a player reported it'], dry), 0);
  assert.equal(dry.said[0], `${digest}: the relay has its copy; put out by 2 account(s)`);
  assert.deepEqual(dry.said.slice(1, 3), [`  ${A}`, `  ${C}`]);
  assert.match(dry.said[3], /hold and terminate each account.*report it to NCMEC as a picture you looked at \(a player reported it\)/);
  assert.equal(dry.said.at(-1), 'nothing changed; --apply does it');
  assert.equal(store.rows.size, 0, 'a dry run writes nothing');

  const puts = [];
  const watched = { ...store, put: async (pk, sk, value, options) => (puts.push({ pk, options }), store.put(pk, sk, value)) };
  const done = reporting(watched, keys, [[404, { error: 'no such report' }], [200, { reported: digest, accounts: [C, A] }]]);
  assert.equal(await main(['picture', 'report', digest, '--account', C, '--how', 'a player reported it', '--apply'], done), 0);
  const [[key, raw]] = [...store.rows];
  const id = key.slice('KNOWN#'.length, -'|META'.length);
  assert.deepEqual(JSON.parse(raw), { digest, accounts: [A, C], how: 'a player reported it' });
  assert.deepEqual(puts, [{ pk: `KNOWN#${id}`, options: { ttl: REPORT_KEPT_S } }], 'written once, to run out by itself');
  assert.deepEqual(done.asked, [{ url: 'https://relay.example/known', body: { report: id } }, { url: 'https://relay.example/known', body: { report: id } }]);
  assert.match(done.said.at(-1), /^done: the relay is acting on it for 2 account\(s\)/);
});

test('picture report: the relay refusing is said, and nothing is asked again', async () => {
  const ctx = reporting(memoryStore(), [], [[404, { error: 'no copy of that picture is kept: report it by hand' }]]);
  assert.equal(await main(['picture', 'report', digest, '--apply'], ctx), 1);
  assert.match(ctx.said.join('\n'), /without its copy, name an account it was taken off/);
  assert.match(ctx.said.at(-1), /the relay said 404: no copy of that picture is kept: report it by hand/);
  assert.equal(ctx.asked.length, 1);

  for (const wrong of [['--account', 'not one'], ['--how', ' '], ['--how', 'x'.repeat(301)]]) {
    const bad = reporting(memoryStore(), [], []);
    assert.equal(await main(['picture', 'report', digest, ...wrong], bad), 2, wrong.join(' '));
  }
});
