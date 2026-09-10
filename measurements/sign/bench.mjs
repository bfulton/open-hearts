// Opens bench.html in headless Chromium and prints what the Dart code
// reports. Uses the global Playwright install (npm root -g).
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname } from 'node:path';

const globalRoot = execSync('npm root -g').toString().trim();
const require = createRequire(import.meta.url);
const { chromium } = require(`${globalRoot}/playwright`);

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm' };
const server = createServer(async (req, res) => {
  const file = new URL('.' + (req.url === '/' ? '/bench.html' : req.url), import.meta.url);
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file.pathname)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const browser = await chromium.launch();
const page = await browser.newPage();
page.on('console', (m) => { if (m.type() === 'error') console.error('page:', m.text()); });
page.on('pageerror', (e) => console.error('page error:', e.message));
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await page.waitForFunction(() => document.body.dataset.done, null, { timeout: 120000 });
console.log(await page.evaluate(() => document.body.dataset.done));
await browser.close();
server.close();
