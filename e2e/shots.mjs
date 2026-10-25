// Screenshots of the table at the shapes docs/explanation/screens.md names,
// from the built app in a headless browser, served as the browser suites
// serve it (drive.mjs) — for looking at a layout before a phone does.
//
//   ./e2e/build.sh
//   node e2e/shots.mjs            # writes app/build/shots/*.png
//
// Each shape gets the pass (thirteen cards, the Pass button), then a
// trick under way (the pass made, and this seat to play to a card already
// led), so both the fan and the trick are in the picture. Both are
// moments that last until this script acts, found by the app's own word
// (its semantics labels, as the suites read them), and each picture is
// taken once the screen has stopped moving: never after a fixed wait.
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { chromium } from './browser.mjs';
import { act, click, has, root, serveApp, sleep, still, texts, waitFor } from './drive.mjs';

const outDir = join(root, 'app', 'build', 'shots');

const shapes = [
  { name: 'phone-portrait', width: 390, height: 844 },
  // The width most Android phones have.
  { name: 'android-portrait', width: 360, height: 800 },
  { name: 'phone-landscape', width: 844, height: 390 },
  { name: 'tablet-portrait', width: 1024, height: 1366 },
  { name: 'tablet-landscape', width: 1366, height: 1024 },
  // The Duo's inner display is the outer one's shape at a larger
  // scale, so unfolding is a change of size and not of composition.
  { name: 'duo-closed', width: 375, height: 812 },
  { name: 'duo-open', width: 620, height: 1342 },
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'narrow-split', width: 340, height: 720 },
];

await mkdir(outDir, { recursive: true });
const app = await serveApp();
const browser = await chromium.launch();
try {
  for (const shape of shapes) {
    // Reduced motion holds the breathing turn pill still
    // (table_view.dart, _YourTurn), so a screen waiting on this seat
    // comes to rest.
    const ctx = await browser.newContext({ viewport: { width: shape.width, height: shape.height }, locale: 'en-US', reducedMotion: 'reduce' });
    const page = await ctx.newPage();
    // ?e2e turns the semantics tree on, which is what the clicks and
    // waits go through (the suites do the same).
    await page.goto(app.at('/?e2e=1'));
    await waitFor(page, /^Play solo$/, { what: `${shape.name}: the app`, timeout: 60000 });
    await click(page, /^Play solo$/);
    await waitFor(page, /^Choose 3 more to pass$/, { what: `${shape.name}: the pass` });
    await writeFile(join(outDir, `${shape.name}-pass.png`), await still(page, `${shape.name}: the pass`));
    // Played as the suites play, a step at a time, until it is this
    // seat's turn with another's card on the table: the trick waits
    // there for as long as this seat does.
    const until = Date.now() + 60000;
    while (!(await has(page, /^Your turn$/) && (await has(page, /^(?!You ).+ led the /)))) {
      if (Date.now() > until) throw new Error(`${shape.name}: no trick to play to\nsaw: ${(await texts(page)).join(' | ')}`);
      await act(page);
      await sleep(100);
    }
    await writeFile(join(outDir, `${shape.name}-play.png`), await still(page, `${shape.name}: the trick`));
    console.log(`${shape.name}: ${shape.width}x${shape.height} → ${outDir}/${shape.name}-{pass,play}.png`);
    await ctx.close();
  }
} finally {
  await browser.close();
  app.stop();
}
