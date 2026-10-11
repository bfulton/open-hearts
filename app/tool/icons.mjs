// Makes every icon and launch image the app and the site ship from
// tool/icon.svg: the web app's (favicon, manifest, maskable), Android's
// launcher icon (whole, and as the felt and heart layers of an adaptive
// icon), iOS's app icon set, the heart both phones show while the app
// starts, and the site's favicon. Run it after changing the SVG:
//
//     node tool/icons.mjs     (from app/)
//
// Chromium draws them (e2e/browser.mjs, the global Playwright's), so
// what is shipped is what a browser shows.
//
// Masks and launch screens show only a centred circle of an icon: a
// maskable icon 80% of it, an adaptive icon's layer 66 of its 108 dp,
// Android 12's launch screen 192 of 288 dp. The heart sits well inside
// every one of them at the icon's own proportions, so each is drawn at
// those proportions, and this checks the heart still fits before it
// writes anything.
import { readFile, writeFile } from 'node:fs/promises';
import { chromium } from '../../e2e/browser.mjs';

const svg = await readFile(new URL('./icon.svg', import.meta.url), 'utf8');
const ground = svg.match(/<rect id="ground"[^>]*\/>/)?.[0];
const card = svg.match(/<g id="card">[\s\S]*?<\/g>/)?.[0];
const heart = card?.match(/<path d="([^"]+)" fill="(#[0-9A-Fa-f]{6})"\/>/);
if (!ground || !card || !heart) throw new Error('icon.svg: no rect#ground, or no g#card with one filled path');

// [svg] with its ground and card swapped for [ground] and [card].
const variant = ({ ground: g = '', card: c = '' }) => svg.replace(ground, g).replace(card, c);
// About the centre, by [s].
const scaled = (s, inner) => `<g transform="translate(512 512) scale(${s}) translate(-512 -512)">${inner}</g>`;

// An adaptive icon is drawn 108 dp and shown through 72 of them, so
// both layers are at two thirds to look as the whole icon does. The
// felt goes past the canvas's edges, its gradient with it.
const adaptive = 72 / 108;
const layers = {
  background: variant({ ground: scaled(adaptive, '<rect x="-1024" y="-1024" width="3072" height="3072" fill="url(#felt)"/>') }),
  foreground: variant({ card: scaled(adaptive, card) }),
};
// The heart alone, on nothing, as the launch screens put it on the felt.
const alone = variant({ card });

// What each mask or launch screen shows: the radius of its circle, as a
// fraction of the canvas, and how much the heart is scaled on it.
const fits = [
  ['a maskable icon', 0.4, 1],
  ["an adaptive icon's foreground", 33 / 108, adaptive],
  ["Android 12's launch screen", 96 / 288, 1],
];

// Drawn on nothing, with an alpha channel. Every other image is opaque
// and has none, which the App Store requires of an app icon.
const clear = true;

const app = new URL('../', import.meta.url);
const out = [
  ['web/favicon.png', 64, svg],
  ['web/icons/Icon-192.png', 192, svg],
  ['web/icons/Icon-512.png', 512, svg],
  ['web/icons/Icon-maskable-192.png', 192, svg],
  ['web/icons/Icon-maskable-512.png', 512, svg],
  ['../site/public/icon-512.png', 512, svg],
  ['../site/public/favicon.png', 64, svg],
];
for (const [d, scale] of Object.entries({ mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 })) {
  const res = `android/app/src/main/res/mipmap-${d}`;
  out.push([`${res}/ic_launcher.png`, 48 * scale, svg]);
  out.push([`${res}/ic_launcher_background.png`, 108 * scale, layers.background]);
  out.push([`${res}/ic_launcher_foreground.png`, 108 * scale, layers.foreground, clear]);
}
// iOS's launch screen: the heart on a 288 pt canvas, as Android's.
for (const [suffix, scale] of [['', 1], ['@2x', 2], ['@3x', 3]]) {
  out.push([`ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage${suffix}.png`, 288 * scale, alone, clear]);
}
// The iOS set: every file its Contents.json names.
const set = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
const contents = JSON.parse(await readFile(new URL(`${set}/Contents.json`, app), 'utf8'));
for (const img of contents.images) {
  if (!img.filename) continue;
  out.push([`${set}/${img.filename}`, Math.round(parseFloat(img.size) * parseInt(img.scale)), svg]);
}

const browser = await chromium.launch();
const page = await browser.newPage();
const show = async (px, source) => {
  await page.setViewportSize({ width: px, height: px });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${px}px;height:${px}px}</style>${source}`);
};

// How far from the centre the heart reaches, as a fraction of the
// canvas: its farthest drawn pixel, at 1024.
await show(1024, alone);
const reach = await page.evaluate(async () => {
  const img = new Image();
  img.src = `data:image/svg+xml,${encodeURIComponent(document.querySelector('svg').outerHTML)}`;
  await img.decode();
  const c = new OffscreenCanvas(1024, 1024);
  const g = c.getContext('2d');
  g.drawImage(img, 0, 0, 1024, 1024);
  const { data } = g.getImageData(0, 0, 1024, 1024);
  let far = 0;
  for (let y = 0; y < 1024; y++) {
    for (let x = 0; x < 1024; x++) {
      if (data[(y * 1024 + x) * 4 + 3] > 0) far = Math.max(far, Math.hypot(x + 0.5 - 512, y + 0.5 - 512));
    }
  }
  return far / 1024;
});
if (!(reach > 0)) throw new Error('no heart drawn to measure');
for (const [what, radius, scale] of fits) {
  const r = reach * scale;
  if (r > radius) {
    await browser.close();
    throw new Error(`the heart reaches ${r.toFixed(3)} of the canvas from its centre, past ${what}'s ${radius.toFixed(3)}`);
  }
  console.log(`fits ${what}: ${r.toFixed(3)} of ${radius.toFixed(3)}`);
}

for (const [path, px, source, transparent = false] of out) {
  await show(px, source);
  await writeFile(new URL(path, app), await page.screenshot({ omitBackground: transparent }));
  console.log(`${px}\t${path}`);
}
await browser.close();

// The same heart for Android's launch screens, as a vector it scales
// itself (res/values/styles.xml, values-v31/styles.xml).
const drawable = 'android/app/src/main/res/drawable/launch_heart.xml';
await writeFile(
  new URL(drawable, app),
  `<?xml version="1.0" encoding="utf-8"?>
<!-- The icon's heart on a 288 dp canvas, for the launch screens: made by
     tool/icons.mjs from tool/icon.svg, so changed there, not here. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="288dp"
    android:height="288dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">
    <path
        android:fillColor="${heart[2]}"
        android:pathData="${heart[1]}" />
</vector>
`,
);
console.log(`vector\t${drawable}`);
