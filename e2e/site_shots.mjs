// The pictures the site shows of the game, taken from the game, in each
// of the site's languages, into site/public/img/:
//
//   broken-<lang>.png  the menu button and the menu open below it, the
//                      pointer on "Tell us what's broken"
//   cancel-<lang>.png  the same menu, the pointer on "Subscription",
//                      over the subscription page's "Manage
//                      subscription", the pointer on that
//   add-<lang>.png     the same, to the page's "Add a device"
//
// Run after a change to either, from the repository root, with the e2e
// build:
//
//   ./e2e/build.sh && node e2e/site_shots.mjs
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { languages as siteLanguages } from '../site/build.mjs';
import { chromium } from './browser.mjs';
import { click, has, labelOf, log, root, serveApp, waitFor } from './drive.mjs';

const languages = siteLanguages.map((l) => l.code);
const words = (code) => JSON.parse(readFileSync(join(root, 'app', 'lib', 'l10n', `app_${code}.arb`), 'utf8'));
const exactly = (text) => new RegExp(`^${text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`);
const out = (name) => join(root, 'site', 'public', 'img', name);

// A pointer drawn over the page: a screenshot leaves the real one out.
const pointer = `<svg xmlns="http://www.w3.org/2000/svg" width="22" height="30" viewBox="0 0 22 30">
  <path d="M1 1v24l6.2-5.6L11.4 29l4.2-1.9-4.1-9.3H20z" fill="#fff" stroke="#000" stroke-width="1.6" stroke-linejoin="round"/>
</svg>`;

const rectOf = (page, re) => page.evaluate(`((src) => {
  const labelOf = ${labelOf};
  const e = [...document.querySelectorAll('flt-semantics')].find((e) => new RegExp(src).test(labelOf(e)));
  const r = e.getBoundingClientRect();
  return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
})(${JSON.stringify(re.source)})`);

/// The pointer resting just under [label]'s words, so it covers none of
/// them, and the thing under it showing that it is hovered.
async function hover(page, label, along = 150) {
  const r = await rectOf(page, label);
  const at = { x: Math.min(r.left + along, (r.left + r.right) / 2 + 40), y: (r.top + r.bottom) / 2 + 11 };
  await page.mouse.move(at.x, at.y);
  await page.waitForTimeout(400);
  await page.evaluate(([svg, x, y]) => {
    const tip = document.createElement('div');
    tip.className = 'drawn-pointer';
    tip.innerHTML = svg;
    Object.assign(tip.style, { position: 'fixed', left: `${x}px`, top: `${y}px`, zIndex: 2147483647, pointerEvents: 'none' });
    document.body.appendChild(tip);
  }, [pointer, at.x, at.y]);
}
const unhover = (page) => page.evaluate(() => document.querySelectorAll('.drawn-pointer').forEach((e) => e.remove()));

/// What covers [boxes], and a margin; the menu's panel runs on past its
/// last entry, so a little more below.
function around(boxes, edge = 8) {
  const left = Math.max(0, Math.min(...boxes.map((r) => r.left)) - edge);
  const top = Math.max(0, Math.min(...boxes.map((r) => r.top)) - edge);
  return {
    x: left, y: top,
    width: Math.ceil(Math.max(...boxes.map((r) => r.right)) + edge - left),
    height: Math.ceil(Math.max(...boxes.map((r) => r.bottom)) + 2 * edge - top),
  };
}

const app = await serveApp();
const browser = await chromium.launch();
try {
  for (const code of languages) {
    const w = words(code);
    // A real browser's language: this machine's own (en-US@posix) is one
    // the app cannot read. Wide enough that the front door's heart, in
    // the middle, is well clear of the menu at the left.
    const page = await browser.newPage({ viewport: { width: 720, height: 900 }, deviceScaleFactor: 2, locale: 'en-US' });
    await page.goto(`${app.url}/?e2e=1&lang=${code}`);
    await waitFor(page, exactly(w.menu));
    // Where the button is, while it is still in the tree: an open menu
    // takes the page behind it out of it.
    const button = await rectOf(page, exactly(w.menu));
    // The rig licenses every device; the menu is drawn when it opens, so
    // it is opened once the licence is in, and every picture is the same.
    for (let tries = 0; ; tries++) {
      await click(page, exactly(w.menu));
      await waitFor(page, exactly(w.tellUsWhatsBroken));
      if (await has(page, exactly(w.subscription))) break;
      if (tries === 20) throw new Error(`${code}: no licence`);
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);
    }
    const menu = async () => around([button, ...await page.evaluate(() => [...document.querySelectorAll('flt-semantics[role="menuitem"]')]
      .map((e) => e.getBoundingClientRect()).map((r) => ({ left: r.left, top: r.top, right: r.right, bottom: r.bottom })))]);

    await hover(page, exactly(w.tellUsWhatsBroken));
    await page.screenshot({ path: out(`broken-${code}.png`), clip: await menu() });
    await unhover(page);

    // To cancel, and to add a device: the menu's Subscription, then a
    // button on the page it opens, with the line above it.
    await hover(page, exactly(w.subscription));
    const shown1 = await menu();
    const step1 = await page.screenshot({ clip: shown1 });
    await unhover(page);
    await click(page, exactly(w.subscription));
    await waitFor(page, exactly(w.manageSubscription));
    await page.waitForTimeout(600);
    for (const [name, label, above] of [
      ['cancel', w.manageSubscription, w.manageSubscriptionHint],
      ['add', w.addDevice, null],
    ]) {
      const target = await rectOf(page, exactly(label));
      const boxes = above ? [await rectOf(page, exactly(above)), target] : [target];
      await hover(page, exactly(label), 130);
      const shown2 = around(boxes, 12);
      const step2 = await page.screenshot({ clip: shown2 });
      await unhover(page);
      const png = (b) => `data:image/png;base64,${b.toString('base64')}`;
      const sheet = await browser.newPage({ deviceScaleFactor: 2 });
      await sheet.setContent(`<body style="margin:0">
        <div id="both" style="display:inline-flex;flex-direction:column;align-items:flex-start;gap:8px">
          <img src="${png(step1)}" style="width:${shown1.width}px;border-radius:12px">
          <svg style="margin-left:24px" width="20" height="26" viewBox="0 0 20 26" fill="none" stroke="#E4B363" stroke-width="2.5"
            stroke-linecap="round" stroke-linejoin="round"><path d="M10 2v20M3 15l7 7 7-7"/></svg>
          <img src="${png(step2)}" style="width:${shown2.width}px;border-radius:12px">
        </div></body>`);
      await sheet.locator('#both').screenshot({ path: out(`${name}-${code}.png`), omitBackground: true });
      await sheet.close();
    }
    log(code);
    await page.close();
  }
} finally {
  await browser.close();
  app.stop();
}
