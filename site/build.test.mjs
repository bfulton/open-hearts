import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { build, languages, pages, problems } from './build.mjs';

/// The pages that teach the game, for someone who searched for it.
const teaching = ['how-to-play', 'rules', 'shooting-the-moon', 'strategy'];

test('every language has every string, with English markup', () => {
  for (const l of languages) assert.deepEqual(problems(l.code), [], l.code);
});

test('an English page sends a browser to each other language the site is built in, and to no other', () => {
  const script = readFileSync(new URL('./public/lang.js', import.meta.url), 'utf8');
  const others = JSON.parse(/const others = (\[[^\]]*\]);/.exec(script)[1].replaceAll("'", '"'));
  assert.deepEqual(others.sort(), languages.map((l) => l.code).filter((c) => c !== 'en').sort(), 'others in site/public/lang.js');
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
    for (const p of teaching) {
      const html = readFileSync(join(dir, `${p}.html`), 'utf8');
      assert.match(html, new RegExp(`<p class="go"><a href="https://play\\.openhearts\\.game/\\?lang=${l.code}">`), `${l.code}/${p}`);
    }
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
  // Only the site's names a sitemap: the app's host has no pages to list.
  const site = readFileSync(new URL('./public/robots.txt', import.meta.url), 'utf8');
  const app = readFileSync(new URL('../app/web/robots.txt', import.meta.url), 'utf8');
  const arachnid = 'User-Agent: ProjectArachnid/E2Z7A4DOVNGNKQIUSZP4UGZACZODKBYW\nAllow: *\n';
  assert.equal(app, arachnid);
  assert.equal(site, `${arachnid}\nSitemap: https://openhearts.game/sitemap.xml\n`);
});

test('the sitemap robots.txt names lists every page in every language, by its canonical, with the copies its head names', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  const sitemapAt = readFileSync(join(out, 'robots.txt'), 'utf8').match(/^Sitemap: https:\/\/openhearts\.game\/(.+)$/m)[1];
  const xml = readFileSync(join(out, sitemapAt), 'utf8');
  assert.match(xml, /^<\?xml version="1\.0" encoding="UTF-8"\?>\n<urlset xmlns="http:\/\/www\.sitemaps\.org\/schemas\/sitemap\/0\.9" xmlns:xhtml="http:\/\/www\.w3\.org\/1999\/xhtml">\n/);
  assert.match(xml, /\n<\/urlset>\n$/);
  // Written out here rather than asked of build.mjs, so the addresses
  // are checked, not only agreed on: English at the root, every other
  // language under its code, and the front page as a directory.
  const address = (code, page) => `https://openhearts.game${code === 'en' ? '' : `/${code}`}${page === 'index' ? '/' : `/${page}`}`;
  const copies = (page) => [...languages.map((l) => `${l.lang} ${address(l.code, page)}`), `x-default ${address('en', page)}`].sort();
  // The pages too, so that one dropped from the build is missed here
  // rather than dropped from the sitemap along with it.
  const site = ['index', ...teaching, 'support', 'privacy', 'terms'];
  const listed = [...xml.matchAll(/<url>\n {4}<loc>([^<]+)<\/loc>\n((?: {4}<xhtml:link [^>]+\/>\n)+) {2}<\/url>/g)]
    .map(([, loc, links]) => [loc, [...links.matchAll(/<xhtml:link rel="alternate" hreflang="([^"]+)" href="([^"]+)"\/>/g)].map(([, h, href]) => `${h} ${href}`).sort()]);
  const want = languages.flatMap((l) => site.map((p) => [address(l.code, p), copies(p)]));
  assert.deepEqual(listed.sort(), want.sort());
  assert.equal(xml.match(/<url>/g).length, want.length, 'every entry is whole');
  // And each page says the same of itself.
  for (const l of languages) {
    for (const p of site) {
      const html = readFileSync(join(l.code === 'en' ? out : join(out, l.code), `${p}.html`), 'utf8');
      assert.equal(html.match(/<link rel="canonical" href="([^"]+)">/)[1], address(l.code, p), `${l.code}/${p}`);
      const named = [...html.matchAll(/<link rel="alternate" hreflang="([^"]+)" href="([^"]+)">/g)].map(([, h, href]) => `${h} ${href}`).sort();
      assert.deepEqual(named, copies(p), `${l.code}/${p}`);
    }
  }
});

test('every nav marks the page it is on, and nothing else is marked', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  // A page linked from the footer and from the pages that teach is
  // marked in both.
  const marks = { index: 1, 'how-to-play': 2, rules: 2, 'shooting-the-moon': 1, strategy: 1, support: 1, privacy: 1, terms: 1 };
  assert.deepEqual(Object.keys(marks).sort(), pages().sort());
  for (const l of languages) {
    const prefix = l.code === 'en' ? '' : `/${l.code}`;
    for (const p of pages()) {
      const html = readFileSync(join(l.code === 'en' ? out : join(out, l.code), `${p}.html`), 'utf8');
      const self = `${prefix}${p === 'index' ? '/' : `/${p}`}`;
      const links = html.match(/<nav[^>]*>[\s\S]*?<\/nav>/g).flatMap((nav) => [...nav.matchAll(/<a href="([^"]*)"( aria-current="page")?/g)]);
      for (const [, href, mark] of links) assert.equal(Boolean(mark), href === self, `${l.code}/${p}: ${href}`);
      assert.equal(links.filter(([, href]) => href === self).length, marks[p], `${l.code}/${p}`);
      assert.equal(html.match(/aria-current="page"/g).length, marks[p], `${l.code}/${p}: marked outside a nav`);
    }
  }
});

test('the pages that teach link one another, and the front page, every footer and support link them', () => {
  const out = mkdtempSync(join(tmpdir(), 'site-'));
  build(out);
  for (const l of languages) {
    const prefix = l.code === 'en' ? '' : `/${l.code}`;
    const read = (p) => readFileSync(join(l.code === 'en' ? out : join(out, l.code), `${p}.html`), 'utf8');
    const links = (html, p) => html.includes(`<a href="${prefix}/${p}"`);
    for (const p of ['index', ...teaching]) {
      for (const q of teaching) assert.ok(links(read(p), q), `${l.code}/${p} links ${q}`);
    }
    for (const p of pages()) {
      const footer = read(p).match(/<footer[\s\S]*<\/footer>/)[0];
      for (const q of ['how-to-play', 'rules']) assert.ok(links(footer, q), `${l.code}/${p}'s footer links ${q}`);
    }
    const support = read('support');
    assert.ok(links(support.match(/<h3 id="play">[\s\S]*?<h3 /)[0], 'how-to-play'), `${l.code}: How do I play? links how to play`);
    assert.ok(links(support.match(/<h3 id="rules">[\s\S]*?<h3 /)[0], 'rules'), `${l.code}: the rules in brief link the rules in full`);
  }
});
