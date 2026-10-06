// On the web build, as an iPhone (its user agent, and the platform
// Flutter reads to decide it is one): a long press on the tagline offers
// Copy, and Copy puts the word on the clipboard.  node e2e/longpress_copy.mjs
import { serveApp, texts, waitFor } from './drive.mjs';
import { chromium } from './browser.mjs';
const app = await serveApp();
const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'en-US',
  userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  permissions: ['clipboard-read', 'clipboard-write'],
});
await ctx.addInitScript(() => {
  Object.defineProperty(Navigator.prototype, 'platform', { get: () => 'iPhone' });
  Object.defineProperty(Navigator.prototype, 'maxTouchPoints', { get: () => 5 });
});
const page = await ctx.newPage();
page.on('console', (m) => { if (/platform/i.test(m.text())) console.log('console:', m.text()); });
page.on('pageerror', (e) => console.log('page error:', e.message));
page.on('console', (m) => { if (/Overlay|Exception|Error/.test(m.text())) console.log('console:', m.text().slice(0, 200)); });
let ok = false;
try {
  await page.goto(`${app.url}/?e2e=1`);
  await waitFor(page, /^Play solo$/, { what: 'the app', timeout: 90000 });
  console.log('navigator.platform:', await page.evaluate('navigator.platform'));
  const node = await page.evaluateHandle(`[...document.querySelectorAll('flt-semantics')].find((e) => (e.textContent || '').trim() === 'Open source Hearts card game, no ads')`);
  const box = await node.asElement().boundingBox();
  const x = box.x + box.width * 0.2, y = box.y + box.height / 2;
  const cdp = await ctx.newCDPSession(page);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
  await new Promise((r) => setTimeout(r, 900));
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await new Promise((r) => setTimeout(r, 800));
  const seen = await texts(page);
  console.log('Copy offered:', seen.includes('Copy'));
  const copy = await page.evaluateHandle(`[...document.querySelectorAll('flt-semantics')].find((e) => (e.getAttribute('aria-label') || e.textContent || '').trim() === 'Copy')`);
  const cb = await copy.asElement()?.boundingBox();
  if (cb) {
    const cx = cb.x + cb.width / 2, cy = cb.y + cb.height / 2;
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: cx, y: cy }] });
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await new Promise((r) => setTimeout(r, 800));
    const clip = await page.evaluate('navigator.clipboard.readText()');
    console.log('clipboard:', JSON.stringify(clip));
    ok = clip.length > 0 && 'Open source Hearts card game, no ads'.includes(clip.trim());
  }
  await page.screenshot({ path: new URL('../app/build/longpress.png', import.meta.url).pathname });
} catch (e) { console.log('FAIL', e.message); }
await browser.close(); app.stop();
console.log(ok ? 'PASS' : 'FAIL'); process.exit(ok ? 0 : 1);
