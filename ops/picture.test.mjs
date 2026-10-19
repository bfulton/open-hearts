// oh picture allow: a picture the automatic check hid, put back, and
// kept from being hidden again (ops/picture.mjs).
//
//   node --test ops/*.test.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { main } from './oh.mjs';
import { PICTURES_ROW, allowedOf, withheldOf, withholding } from '../service/functions/pictures.mjs';
import { memoryStore } from '../service/functions/rows.mjs';

const now = Date.parse('2026-10-19T12:00:00Z');
const digest = 'ab'.repeat(32);

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

test('picture allow: a picture is named by its SHA-256', async () => {
  const ctx = context(memoryStore());
  assert.equal(await main(['picture', 'allow', 'ab'.repeat(31)], ctx), 2);
  assert.match(ctx.said.join('\n'), /name the picture by its SHA-256/);
});
