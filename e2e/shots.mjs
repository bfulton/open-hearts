// Screenshots of the table at the shapes docs/05-form-factors.md names,
// from the built app in a headless browser — for looking at a layout
// before a phone does.
//
//   cd app && flutter build web -o build/e2e --base-href / --no-web-resources-cdn
//   node e2e/shots.mjs            # writes app/build/shots/*.png
//
// Each shape gets the pass (thirteen cards, the Pass button), then the
// first trick under way (the pass made, a card played), so both the fan
// and the trick are in the picture.
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, readFile } from 'node:fs/promises';
import { extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const appDir = process.env.OH_APP_DIR ?? join(root, 'app', 'build', 'e2e');
const outDir = join(root, 'app', 'build', 'shots');
const require = createRequire(import.meta.url);
const { chromium } = require(`${execSync('npm root -g').toString().trim()}/playwright`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const shapes = [
  { name: 'phone-portrait', width: 390, height: 844 },
  { name: 'phone-landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'narrow-split', width: 340, height: 720 },
];

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json', '.png': 'image/png', '.css': 'text/css' };
async function serveApp() {
  const server = createServer(async (req, res) => {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = join(appDir, path === '/' ? 'index.html' : path);
    try {
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}`, stop: () => server.close() };
}

const labelOf = `(e) => e.getAttribute('aria-label') || [...e.childNodes]
  .filter((n) => n.nodeType === 3 || (n.nodeType === 1 && n.tagName.toLowerCase() !== 'flt-semantics'))
  .map((n) => n.textContent).join('').trim()`;
const labels = (page) => page.evaluate(`(() => { const labelOf = ${labelOf}; return [...document.querySelectorAll('flt-semantics')].map((e) => ({ label: labelOf(e), button: e.getAttribute('role') === 'button', disabled: e.getAttribute('aria-disabled') === 'true' })).filter((n) => n.label); })()`);
const click = (page, re, button = false) => page.evaluate(`((src, button) => { const labelOf = ${labelOf}; const re = new RegExp(src); for (const e of document.querySelectorAll('flt-semantics')) { if (button && e.getAttribute('role') !== 'button') continue; if (re.test(labelOf(e)) && e.getAttribute('aria-disabled') !== 'true') { e.click(); return labelOf(e); } } return null; })(${JSON.stringify(re.source)}, ${button})`);
const cardName = /^(2|3|4|5|6|7|8|9|10|jack|queen|king|ace) of (clubs|diamonds|spades|hearts)$/;
async function until(page, re, timeout = 20000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if ((await labels(page)).some((n) => re.test(n.label))) return true;
    await sleep(200);
  }
  return false;
}

async function main() {
  await mkdir(outDir, { recursive: true });
  const app = await serveApp();
  const browser = await chromium.launch();
  try {
    for (const shape of shapes) {
      const ctx = await browser.newContext({ viewport: { width: shape.width, height: shape.height }, locale: 'en-US' });
      const page = await ctx.newPage();
      // ?e2e turns the semantics tree on, which is what the clicks go
      // through (the suite does the same).
      await page.goto(`${app.url}/?e2e=1`);
      if (!(await until(page, /^Play alone$/, 60000))) throw new Error(`${shape.name}: no app`);
      await click(page, /^Play alone$/, true);
      if (!(await until(page, /^Pass$/))) throw new Error(`${shape.name}: no table`);
      await sleep(700);
      await page.screenshot({ path: join(outDir, `${shape.name}-pass.png`) });
      // Three cards, the pass, then the first legal card.
      const cards = (await labels(page)).filter((n) => n.button && cardName.test(n.label)).map((n) => n.label);
      for (const c of cards.slice(0, 3)) await click(page, new RegExp(`^${c}$`), true);
      await sleep(300);
      await click(page, /^Pass$/, true);
      await sleep(1500);
      const legal = (await labels(page)).filter((n) => n.button && !n.disabled && cardName.test(n.label)).map((n) => n.label);
      if (legal.length) await click(page, new RegExp(`^${legal[0]}$`), true);
      await sleep(1200);
      await page.screenshot({ path: join(outDir, `${shape.name}-play.png`) });
      console.log(`${shape.name}: ${shape.width}x${shape.height} → ${outDir}/${shape.name}-{pass,play}.png`);
      await ctx.close();
    }
  } finally {
    await browser.close();
    app.stop();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
