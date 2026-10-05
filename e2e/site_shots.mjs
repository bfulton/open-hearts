// The pictures the site shows of the game, taken from the game: its
// menu open on "Tell us what's broken", the pointer resting on it, in
// each of the site's languages, into site/public/img/. Run after a
// change to the menu, from the repository root, with the e2e build:
//
//   ./e2e/build.sh && node e2e/site_shots.mjs
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { chromium } from './browser.mjs';
import { click, has, labelOf, log, root, serveApp, waitFor } from './drive.mjs';

const languages = ['en', 'es', 'pt', 'de', 'fr'];
const words = (code) => JSON.parse(readFileSync(join(root, 'app', 'lib', 'l10n', `app_${code}.arb`), 'utf8'));
const exactly = (text) => new RegExp(`^${text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`);

// A pointer drawn over the page: a screenshot leaves the real one out.
const pointer = `<svg xmlns="http://www.w3.org/2000/svg" width="22" height="30" viewBox="0 0 22 30">
  <path d="M1 1v24l6.2-5.6L11.4 29l4.2-1.9-4.1-9.3H20z" fill="#fff" stroke="#000" stroke-width="1.6" stroke-linejoin="round"/>
</svg>`;

const app = await serveApp();
const browser = await chromium.launch();
try {
  for (const code of languages) {
    const { menu, tellUsWhatsBroken, subscription } = words(code);
    // A real browser's language: this machine's own (en-US@posix) is one
    // the app cannot read.
    const page = await browser.newPage({ viewport: { width: 390, height: 640 }, deviceScaleFactor: 2, locale: 'en-US' });
    await page.goto(`${app.url}/?e2e=1&lang=${code}`);
    await waitFor(page, exactly(menu));
    // The rig licenses every device; the menu is drawn when it opens, so
    // it is opened once the licence is in, and every picture is the same.
    for (let tries = 0; ; tries++) {
      await click(page, exactly(menu));
      await waitFor(page, exactly(tellUsWhatsBroken));
      if (await has(page, exactly(subscription))) break;
      if (tries === 20) throw new Error(`${code}: no licence`);
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);
    }
    const rect = (re) => page.evaluate(`((src) => {
      const labelOf = ${labelOf};
      const e = [...document.querySelectorAll('flt-semantics')].find((e) => new RegExp(src).test(labelOf(e)));
      const r = e.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    })(${JSON.stringify(re.source)})`);
    const item = await rect(exactly(tellUsWhatsBroken));
    // Just under the words, so the pointer covers none of them.
    const at = { x: item.x + 150, y: item.y + item.height / 2 + 11 };
    await page.mouse.move(at.x, at.y);
    await page.waitForTimeout(400);
    await page.evaluate(([svg, x, y]) => {
      const tip = document.createElement('div');
      tip.innerHTML = svg;
      Object.assign(tip.style, { position: 'fixed', left: `${x}px`, top: `${y}px`, zIndex: 2147483647, pointerEvents: 'none' });
      document.body.appendChild(tip);
    }, [pointer, at.x, at.y]);
    // The menu to its edge; the site rounds the corners as the menu does.
    const items = await page.evaluate(() => [...document.querySelectorAll('flt-semantics[role="menuitem"]')]
      .map((e) => e.getBoundingClientRect()).map((r) => ({ left: r.left, top: r.top, right: r.right, bottom: r.bottom })));
    const edge = 4;
    const left = Math.max(0, Math.min(...items.map((r) => r.left)) - edge);
    const top = Math.max(0, Math.min(...items.map((r) => r.top)) - edge);
    const clip = {
      x: left, y: top,
      width: Math.ceil(Math.max(...items.map((r) => r.right)) + edge - left),
      height: Math.ceil(Math.max(...items.map((r) => r.bottom)) + edge - top),
    };
    const out = join(root, 'site', 'public', 'img', `broken-${code}.png`);
    await page.screenshot({ path: out, clip });
    log(code, out);
    await page.close();
  }
} finally {
  await browser.close();
  app.stop();
}
