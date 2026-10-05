import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { build, languages, pages, problems } from './build.mjs';

test('every language has every string, with English markup', () => {
  for (const l of languages) assert.deepEqual(problems(l.code), [], l.code);
});

test('every page is built in every language, with nothing left unfilled', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  for (const l of languages) {
    const dir = l.code === 'en' ? out : join(out, l.code);
    assert.deepEqual(readdirSync(dir).filter((f) => f.endsWith('.html')).sort(), pages().map((p) => `${p}.html`).sort());
    for (const p of pages()) {
      const html = readFileSync(join(dir, `${p}.html`), 'utf8');
      assert.doesNotMatch(html, /\{\{|\}\}/, `${l.code}/${p}`);
      assert.match(html, new RegExp(`<html lang="${l.lang}">`), `${l.code}/${p}`);
      assert.match(html, new RegExp(`lang="${l.lang}" selected>`), `${l.code}/${p}: its own language chosen in the menu`);
    }
  }
});

test('a page offers its copy in each language, and to its own language\'s pages', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  const terms = readFileSync(join(out, 'de', 'terms.html'), 'utf8');
  for (const l of languages) {
    assert.match(terms, new RegExp(`<option value="${l.code === 'en' ? '' : `/${l.code}`}/terms" lang="${l.lang}"`));
  }
  assert.match(terms, /<a href="\/de\/privacy"/);
  assert.match(terms, /<a href="\/de\/terms" aria-current="page"/);
  assert.match(readFileSync(join(out, 'index.html'), 'utf8'), /<link rel="canonical" href="https:\/\/openhearts.game\/">/);
});
