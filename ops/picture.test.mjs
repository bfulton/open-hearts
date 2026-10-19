// oh picture allow: a picture the automatic check hid, put back, and
// kept from being hidden again; and oh picture hide: one withheld at the
// relay by its digest (ops/picture.mjs).
//
//   node --test ops/*.test.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { main } from './oh.mjs';
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
