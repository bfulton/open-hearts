// Renders tool/icon.svg into every icon the app and the site ship: the
// web app's (favicon, manifest, maskable), Android's launcher mipmaps,
// iOS's app icon set, and the site's favicon. Run it after
// changing the SVG:  node tool/icons.mjs   (from app/)
//
// Chromium draws it, so what is shipped is what a browser shows. A
// maskable icon keeps the card inside the middle 80%, the safe zone a
// launcher's mask may cut to; the rest are full bleed, since iOS and
// the launchers round the corners themselves.
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT ?? '/opt/node22/lib/node_modules/playwright');

const svg = await readFile(new URL('./icon.svg', import.meta.url), 'utf8');
// The card at 80%, centred on the same felt, for maskable icons.
const maskable = svg.replace('<g id="card" transform="', '<g id="card" transform="translate(512 512) scale(0.8) translate(-512 -512) ');

const app = new URL('../', import.meta.url);
const out = [
  ['web/favicon.png', 64, svg],
  ['web/icons/Icon-192.png', 192, svg],
  ['web/icons/Icon-512.png', 512, svg],
  ['web/icons/Icon-maskable-192.png', 192, maskable],
  ['web/icons/Icon-maskable-512.png', 512, maskable],
  ['../site/public/icon-512.png', 512, svg],
  ['../site/public/favicon.png', 64, svg],
  ...Object.entries({ mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 })
    .map(([d, px]) => [`android/app/src/main/res/mipmap-${d}/ic_launcher.png`, px, svg]),
];
// The iOS set: every file its Contents.json names.
for (const set of ['ios/Runner/Assets.xcassets/AppIcon.appiconset']) {
  const contents = JSON.parse(await readFile(new URL(`${set}/Contents.json`, app), 'utf8'));
  for (const img of contents.images) {
    if (!img.filename) continue;
    const px = Math.round(parseFloat(img.size) * parseInt(img.scale));
    out.push([`${set}/${img.filename}`, px, svg]);
  }
}

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM ?? '/opt/pw-browsers/chromium' });
const page = await browser.newPage();
const done = new Map();
for (const [path, px, source] of out) {
  await page.setViewportSize({ width: px, height: px });
  await page.setContent(`<style>html,body{margin:0}svg{display:block;width:${px}px;height:${px}px}</style>${source}`);
  const png = await page.screenshot({ omitBackground: false });
  await writeFile(new URL(path, app), png);
  done.set(path, px);
}
await browser.close();
for (const [path, px] of done) console.log(`${px}\t${path}`);
