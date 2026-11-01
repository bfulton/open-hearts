// site/headers.mjs: Pages' `_headers` file, read the way Pages reads it,
// so that the browser rig serves the app with the headers production does
// (e2e/drive.mjs, serveApp).
//
//   node --test site/headers.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { headersFor, parseHeaders } from './headers.mjs';

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

test('the file as committed is one it understands, and every path of the site gets the framing rules', () => {
  const rules = parseHeaders(readFileSync(new URL('./public/_headers', import.meta.url), 'utf8'));
  for (const path of ['/', '/terms', '/play/', '/play/main.dart.js']) {
    const headers = headersFor(rules, path);
    assert.match(headers['content-security-policy'], /frame-ancestors 'none'/, path);
    assert.equal(headers['x-frame-options'], 'DENY', path);
  }
});
