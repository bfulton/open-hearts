// The buckets as oh reaches them through Cloudflare's API (ops/env.mjs,
// service/tool/r2.mjs): the pictures bucket the relay's wrangler.toml
// binds, and each object at the path Wrangler uses for it.
//
//   node --test ops/*.test.mjs

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { picturesBucket, recordsBucket } from './env.mjs';

const env = { CLOUDFLARE_API_TOKEN: 'token', CLOUDFLARE_ACCOUNT_ID: 'acct' };
const objects = (bucket) => `https://api.cloudflare.com/client/v4/accounts/acct/r2/buckets/${bucket}/objects`;

/// A fetch that answers each call with the next of [answers] and keeps
/// what was asked.
function asked(...answers) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url, method: init.method ?? 'GET', headers: init.headers ?? {}, body: init.body });
    return answers.shift();
  };
  return { calls, fetchImpl };
}

test('the pictures bucket: listed by prefix a page at a time, and each object read, written and deleted at its own path', async () => {
  const { calls, fetchImpl } = asked(
    new Response(JSON.stringify({ success: true, result: [{ key: 'account/a/1.jpg' }], result_info: { is_truncated: true, cursor: 'c 2' } })),
    new Response(JSON.stringify({ success: true, result: [{ key: 'account/b/2.jpg' }], result_info: { is_truncated: false } })),
    new Response(Uint8Array.from([0xff, 0xd8, 1])),
    new Response('', { status: 404 }),
    new Response('', { status: 500 }),
    new Response('{}'),
    new Response('', { status: 404 }),
    new Response('', { status: 500 }),
  );
  const pictures = await picturesBucket(env, fetchImpl);
  assert.deepEqual(await pictures.list('account/'), ['account/a/1.jpg', 'account/b/2.jpg']);
  const at = objects('open-hearts-pictures');
  assert.deepEqual(calls.map((c) => c.url), [`${at}?prefix=account%2F`, `${at}?prefix=account%2F&cursor=c%202`]);
  assert.equal(calls[0].headers.authorization, 'Bearer token');

  assert.deepEqual(await pictures.read('account/a/ab.jpg'), Uint8Array.from([0xff, 0xd8, 1]));
  assert.equal(calls[2].url, `${at}/account/a/ab.jpg`, "a key's slashes stay in the path");
  assert.equal(await pictures.read('account/a/gone.jpg'), null);
  await assert.rejects(pictures.read('account/a/ab.jpg'), /reading said 500/);

  await pictures.write('held/a/ab.jpg', Uint8Array.from([1]), 'image/jpeg');
  assert.deepEqual([calls[5].method, calls[5].url, calls[5].headers['content-type']], ['PUT', `${at}/held/a/ab.jpg`, 'image/jpeg']);
  await pictures.remove('account/a/gone.jpg');
  assert.equal(calls[6].method, 'DELETE');
  await assert.rejects(pictures.remove('account/a/ab.jpg'), /deleting said 500/);
});

test('the records bucket: a record at its path, and its bytes as any object', async () => {
  const { calls, fetchImpl } = asked(new Response('{"a":1}'), new Response('{}'));
  const records = recordsBucket(env, fetchImpl);
  assert.deepEqual(await records.get('tables/t 1.json'), { a: 1 });
  assert.equal(calls[0].url, `${objects('open-hearts-records')}/tables/t%201.json`);
  await records.write('held/a/ab.jpg', Uint8Array.from([1]), 'image/jpeg');
  assert.equal(calls[1].url, `${objects('open-hearts-records')}/held/a/ab.jpg`);
});
