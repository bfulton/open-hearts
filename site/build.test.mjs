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
    // carry.html is public/'s, copied as it is, in no language.
    const built = readdirSync(dir).filter((f) => f.endsWith('.html') && f !== 'carry.html');
    assert.deepEqual(built.sort(), pages().map((p) => `${p}.html`).sort());
    for (const p of pages()) {
      const html = readFileSync(join(dir, `${p}.html`), 'utf8');
      assert.doesNotMatch(html, /\{\{|\}\}/, `${l.code}/${p}`);
      assert.match(html, new RegExp(`<html lang="${l.lang}">`), `${l.code}/${p}`);
      assert.match(html, /aria-current="true">/, `${l.code}/${p}: its own language marked`);
    }
  }
});

test('a page links to its copy in each language, and to its own language\'s pages', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  const terms = readFileSync(join(out, 'de', 'terms.html'), 'utf8');
  for (const l of languages) {
    assert.match(terms, new RegExp(`href="${l.code === 'en' ? '' : `/${l.code}`}/terms" hreflang="${l.lang}"`));
  }
  assert.match(terms, /<a href="\/de\/privacy"/);
  assert.match(terms, /<a href="\/de\/terms" aria-current="page"/);
  assert.match(readFileSync(join(out, 'index.html'), 'utf8'), /<link rel="canonical" href="https:\/\/openhearts.game\/">/);
});

test('stylesheets, scripts and pictures are linked by their content, so a deploy reaches a cached browser', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  const home = readFileSync(join(out, 'index.html'), 'utf8');
  for (const file of ['home.css', 'langs.css', 'lang.js', 'heart.js', 'img/broken-en.png', 'favicon.png']) {
    assert.match(home, new RegExp(`"/${file.replace('.', '\\.')}\\?v=[0-9a-f]{10}"`), file);
  }
});

test("every link to the game goes to play.openhearts.game, in the page's language", () => {
  // The app has an origin of its own (docs/explanation/service.md, "Where the
  // app is"), so it no longer shares the site's storage, where the
  // language links keep a choice: the language goes in the address.
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  for (const l of languages) {
    const dir = l.code === 'en' ? out : join(out, l.code);
    const home = readFileSync(join(dir, 'index.html'), 'utf8');
    assert.match(home, new RegExp(`<a class="cta play" href="https://play\\.openhearts\\.game/\\?lang=${l.code}">`), l.code);
    const support = readFileSync(join(dir, 'support.html'), 'utf8');
    assert.match(support, new RegExp(`<a href="https://play\\.openhearts\\.game/\\?lang=${l.code}">play\\.openhearts\\.game</a>`), l.code);
    assert.match(support, new RegExp(`<a href="https://play\\.openhearts\\.game/subscription\\?lang=${l.code}">`), l.code);
    for (const p of pages()) {
      const html = readFileSync(join(dir, `${p}.html`), 'utf8');
      assert.doesNotMatch(html, /href="\/play|openhearts\.game\/play/, `${l.code}/${p}: a link to where the app used to be`);
    }
  }
});

test('the page that hands a device on to the app answers only the app, and only when asked', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  const carry = readFileSync(join(out, 'carry.html'), 'utf8');
  assert.match(carry, /'https:\/\/play\.openhearts\.game'/);
  assert.match(carry, /event\.origin !== app \|\| event\.source !== window\.parent/);
  assert.match(carry, /postMessage\(\{ type: 'oh-carry\/entries', entries \}, app\)/);
  assert.doesNotMatch(carry, /removeItem|clear\(\)/, 'nothing is deleted');
});

test('a badge with no store listing yet says so where it can be seen', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  for (const l of languages) {
    const html = readFileSync(join(l.code === 'en' ? out : join(out, l.code), 'index.html'), 'utf8');
    assert.match(html, /<a class="cta badge" aria-disabled="true"/, l.code);
    assert.match(html, /<p class="soon">[^<]+<\/p>/, l.code);
  }
});

test('every link to a part of a page finds that part', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  for (const l of languages) {
    const dir = l.code === 'en' ? out : join(out, l.code);
    const prefix = l.code === 'en' ? '' : `/${l.code}`;
    const ids = Object.fromEntries(pages().map((p) => [p,
      new Set([...readFileSync(join(dir, `${p}.html`), 'utf8').matchAll(/ id="([^"]+)"/g)].map((m) => m[1]))]));
    for (const p of pages()) {
      const html = readFileSync(join(dir, `${p}.html`), 'utf8');
      for (const [, to, part] of html.matchAll(/href="([^"#:]*)#([^"]+)"/g)) {
        const page = to === '' ? p : to === `${prefix}/` ? 'index' : to.slice(prefix.length + 1);
        assert.ok(ids[page]?.has(part), `${l.code}/${p}: ${to}#${part}`);
      }
    }
  }
});

test('robots.txt lets Project Arachnid\'s crawler in, on the site and on the app\'s host alike', () => {
  // Arachnid Shield confirms Open Hearts runs these hosts by this line;
  // every other crawler has no group of its own here, so is let in too.
  const site = readFileSync(new URL('./public/robots.txt', import.meta.url), 'utf8');
  const app = readFileSync(new URL('../app/web/robots.txt', import.meta.url), 'utf8');
  assert.equal(app, site);
  assert.match(site, /^User-Agent: ProjectArachnid\/E2Z7A4DOVNGNKQIUSZP4UGZACZODKBYW\nAllow: \*\n$/);
});
