// The marketing site, built in every language (site/build.mjs) and served
// the way Pages serves it: a page in a browser that prefers Spanish
// becomes the Spanish page, a language picked is a choice that sticks, and
// no page in any language is wider than a phone.
//
//   node e2e/site.mjs
import { mkdtempSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { extname, join } from 'node:path';
import { build, languages, pages } from '../site/build.mjs';
import { chromium } from './browser.mjs';
import { log } from './drive.mjs';

const out = mkdtempSync(join(tmpdir(), 'site-'));
build(out);

// As Pages answers: /terms is terms.html, /es/ is es/index.html.
const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png' };
const server = createServer(async (req, res) => {
  let path = new URL(req.url, 'http://x').pathname;
  if (path.endsWith('/')) path += 'index.html';
  else if (!extname(path)) path += '.html';
  try {
    const body = await readFile(join(out, path));
    res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const site = `http://127.0.0.1:${server.address().port}`;

const browser = await chromium.launch();
const failures = [];
const check = (ok, what) => {
  log(ok ? 'ok  ' : 'FAIL', what);
  if (!ok) failures.push(what);
};
const pathOf = (page) => (page === 'index' ? '/' : `/${page}`);

try {
  // A Spanish browser, nothing chosen: the English page sends it on.
  {
    const context = await browser.newContext({ locale: 'es-ES' });
    const page = await context.newPage();
    await page.goto(`${site}/terms`);
    await page.waitForURL(`${site}/es/terms`);
    check(new URL(page.url()).pathname === '/es/terms', 'a Spanish browser is sent to /es/terms');

    // English chosen: kept, and the English page stays English.
    await page.selectOption('footer select.lang-pick', { label: 'English' });
    await page.waitForURL(`${site}/terms`);
    await page.goto(`${site}/`);
    await page.waitForLoadState('load');
    check(new URL(page.url()).pathname === '/', 'once English is chosen, a Spanish browser stays on /');
    check(await page.evaluate(() => localStorage.getItem('flutter.language')) === '"en"', 'the choice is kept where the app reads it');
    await context.close();
  }

  // An English browser that picks German: the choice follows it home.
  {
    const context = await browser.newContext({ locale: 'en-US' });
    const page = await context.newPage();
    await page.goto(`${site}/`);
    check(new URL(page.url()).pathname === '/', 'an English browser stays on /');
    await page.click('main a[hreflang="de"]');
    await page.waitForURL(`${site}/de/`);
    await page.goto(`${site}/support`);
    await page.waitForURL(`${site}/de/support`);
    check(true, 'after choosing Deutsch, /support becomes /de/support');
    check(await page.evaluate(() => document.documentElement.lang) === 'de', 'the German page says it is German');
    // A page asked for in another language is never left.
    await page.goto(`${site}/fr/privacy`);
    await page.waitForLoadState('load');
    check(new URL(page.url()).pathname === '/fr/privacy', 'an address in French stays French');
    await context.close();
  }

  // Every page, every language: nothing wider than a small phone, and no
  // error on the page.
  {
    const context = await browser.newContext({ viewport: { width: 360, height: 740 }, reducedMotion: 'reduce' });
    for (const l of languages) {
      for (const p of pages()) {
        const page = await context.newPage();
        const errors = [];
        page.on('pageerror', (e) => errors.push(e.message));
        // The language is chosen first, so no page is sent on.
        await page.goto(`${site}/`);
        await page.evaluate((code) => localStorage.setItem('flutter.language', JSON.stringify(code)), l.code);
        const path = `${l.code === 'en' ? '' : `/${l.code}`}${pathOf(p)}`;
        await page.goto(`${site}${path}`);
        await page.waitForLoadState('load');
        const wide = await page.evaluate(() => document.documentElement.scrollWidth);
        check(wide <= 360 && errors.length === 0, `${path} fits 360 px (${wide}) with no errors${errors.length ? `: ${errors}` : ''}`);
        await page.close();
      }
    }
    await context.close();
  }
} finally {
  await browser.close();
  server.close();
}

if (failures.length) {
  log(`${failures.length} failed`);
  process.exit(1);
}
log('PASS');
