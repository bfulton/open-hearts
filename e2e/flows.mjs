// Every flow one device can drive, in a real browser.
//
//   cd app && flutter build web -o build/e2e --base-href / --no-web-resources-cdn
//   node e2e/flows.mjs                 # from the repo root
//   node e2e/flows.mjs --only "a hand alone"
//
// run.mjs is the other half: four browsers at one table, which is the
// only way to see the live flows. This one is everything else — the
// front door, the game options, a game played out alone, the record it
// leaves, a room to share, the phone turned — and it is the only suite
// that presses anything with a real pointer rather than through the
// accessibility tree, so a tap landing in the wrong place has
// somewhere to show up.
import { execFileSync } from 'node:child_process';
import { statSync } from 'node:fs';
import { join } from 'node:path';

import { chromium } from './browser.mjs';
import { act, appDir, argOf, click, dismiss, has, labelOf, log, root, serveApp, sleep, startRelay, texts, type, waitFor } from './drive.mjs';

const portrait = { width: 390, height: 844 };
const landscape = { width: 844, height: 390 };

/// The rect of the first semantics node whose label matches, in CSS
/// pixels: where a thumb would land on it.
async function rectOf(page, re) {
  const r = await page.evaluate(`((src) => {
    const labelOf = ${labelOf};
    const re = new RegExp(src);
    for (const e of document.querySelectorAll('flt-semantics')) {
      if (re.test(labelOf(e))) { const b = e.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height, label: labelOf(e) }; }
    }
    return null;
  })(${JSON.stringify(re.source)})`);
  if (!r) throw new Error(`nothing on screen for ${re}\nsaw: ${(await texts(page)).join(' | ')}`);
  return r;
}

/// Presses where the thing is, with the pointer, rather than telling
/// the semantics node it was clicked. The nodes read the geometry and
/// then take no pointer events, so the press goes through the app's
/// own hit test — the path a thumb takes.
async function tapAt(page, re, { dx = 8, dy = null } = {}) {
  const r = await rectOf(page, re);
  const x = r.x + dx, y = r.y + (dy ?? r.h / 2);
  await page.touchscreen.tap(x, y);
  await sleep(250);
  return r.label;
}

/// The cards in the hand, in the order the fan lays them out.
async function handOf(page) {
  return (await texts(page)).filter((t) => cardName.test(t));
}

const cardName = /^(2|3|4|5|6|7|8|9|10|jack|queen|king|ace) of (clubs|diamonds|spades|hearts)$/;

// ---- the flows -----------------------------------------------------------

const flows = [];
const flow = (name, run) => flows.push({ name, run });

flow('the front door', async ({ open }) => {
  const page = await open();
  await waitFor(page, /^Open Hearts$/, { what: 'the home screen' });
  const seen = await texts(page);
  // Everything before a game is on this one screen: who you are, the
  // game being asked for, and the three ways in.
  for (const want of [
    /^Open source, no ads\. Play alone or live\.$/,
    /^Menu$/,
    /^Your profile$/,
    /^Play bots$/,
    /^50 points · rated$/,
    /^Game options$/,
    /^Play live/,
    /^Play friends$/,
  ]) {
    if (!seen.some((t) => want.test(t))) throw new Error(`the home screen has nothing for ${want}\nsaw: ${seen.join(' | ')}`);
  }
  // Who you are is behind the icon in the corner; nothing is typed on
  // the door itself.
  if (seen.some((t) => /^Your name$/.test(t))) throw new Error(`the door still asks for a name\nsaw: ${seen.join(' | ')}`);
  if (seen.some((t) => /^About$/.test(t))) throw new Error('About is in the menu now, not on the door');
});

flow('the game options', async ({ open }) => {
  const page = await open();
  await waitFor(page, /^50 points · rated$/, { what: 'the options line' });
  await click(page, /^Game options$/);
  await waitFor(page, /^100 points$/, { what: 'the options sheet' });
  await click(page, /^100 points$/);
  await click(page, /^Unrated$/);
  await click(page, /^Done$/);
  await waitFor(page, /^100 points · unrated$/, { what: 'the line, changed' });
  // The choice is a rule of the next game, not a label: the table
  // plays to it.
  await click(page, /^Play bots$/);
  await waitFor(page, /^Hand 1 .* to 100$/, { what: 'a game to a hundred' });
  await click(page, /^Menu$/);
  await waitFor(page, /^Leave the table$/, { what: 'the menu' });
  await click(page, /^Leave the table$/);
  // And it is the device's, still there when the app is opened again.
  await page.reload();
  await waitFor(page, /^100 points · unrated$/, { what: 'the options after a reload' });
});

flow('a hand alone', async ({ open }) => {
  const page = await open();
  await click(page, /^Play bots$/);
  await waitFor(page, /^Choose 3 more to pass$/, { what: 'the pass' });
  await playAlone(page, (p) => has(p, /^Next hand$/), 120000);
  await click(page, /^Next hand$/);
  await waitFor(page, /^Hand 2/, { what: 'the second hand' });
  await click(page, /^Menu$/);
  await waitFor(page, /^Leave the table$/, { what: 'the menu' });
  await click(page, /^Leave the table$/);
  await waitFor(page, /^Play bots$/, { what: 'the home screen again' });
});

flow('a thumb, not the tree', async ({ open }) => {
  // The only flow that presses with a pointer. Every other suite here
  // clicks the semantics nodes, which never touches the app's hit
  // test, so this is where a tap landing in the wrong place shows up.
  for (const [shape, viewport] of [['portrait', portrait], ['sideways', landscape]]) {
    const page = await open({ viewport, pointer: true });
    await click(page, /^Play bots$/);
    await waitFor(page, /^Choose 3 more to pass$/, { what: `the pass, ${shape}` });
    // Three named cards, each tapped where it is drawn: the count on
    // the line is how the app says the tap landed on that card and not
    // its neighbour.
    const hand = await handOf(page);
    for (const [i, card] of hand.slice(0, 3).entries()) {
      await tapAt(page, new RegExp(`^${card}$`));
      await waitFor(page, i < 2 ? new RegExp(`^Choose ${2 - i} more to pass$`) : /^Pass (left|right|across)$/, {
        what: `${shape}: the tap on "${card}" to land`,
        timeout: 5000,
      });
    }
    await tapAt(page, /^Pass$/, { dx: 20 });
    await waitFor(page, /^Your (turn|lead)$|passed you/, { what: `${shape}: the pass to go through` });
  }
});

flow('turning the phone mid-hand', async ({ open }) => {
  const page = await open();
  await click(page, /^Play bots$/);
  await waitFor(page, /^Choose 3 more to pass$/, { what: 'the pass' });
  await playAlone(page, (p) => has(p, /^Your (turn|lead)$/), 60000);
  const hand = (await texts(page)).find((t) => /^Hand \d/.test(t));
  const cards = (await texts(page)).filter((t) => cardName.test(t)).sort();
  await page.setViewportSize(landscape);
  await sleep(700);
  const sideways = (await texts(page)).filter((t) => cardName.test(t)).sort();
  if ((await texts(page)).find((t) => /^Hand \d/.test(t)) !== hand) throw new Error('the hand changed when the phone turned');
  if (sideways.join() !== cards.join()) throw new Error(`the hand is not the same sideways:\n  ${cards.join()}\n  ${sideways.join()}`);
  await page.setViewportSize(portrait);
  await sleep(700);
  await playAlone(page, (p) => has(p, /^Next hand$/), 120000);
});

flow('a game alone, and the record it leaves', async ({ open, context }) => {
  const page = await open();
  await click(page, /^Play bots$/);
  // Hand after hand until somebody reaches fifty.
  for (let hand = 0; hand < 30; hand++) {
    await playAlone(page, (p) => has(p, /^Next hand$|^New game$/), 180000);
    if (await has(page, /^New game$/)) break;
    await click(page, /^Next hand$/);
    await waitFor(page, new RegExp(`^Hand ${hand + 2}`), { what: `hand ${hand + 2}` });
  }
  await waitFor(page, /^New game$/, { what: 'the game-over sheet' });
  // Nothing was at stake against bots, so the sheet says nothing about
  // ratings.
  if ((await texts(page)).some((t) => /^Rating /.test(t))) throw new Error('a game alone moved no rating, and should say so by saying nothing');
  await click(page, /^Copy record$/);
  await sleep(500);
  const record = await page.evaluate('navigator.clipboard.readText()');
  if (!/^oh1:/.test(record ?? '')) throw new Error(`the record does not look like one: ${JSON.stringify((record ?? '').slice(0, 40))}`);
  // And it is a record the tool can read: every trick, from the seed
  // and the player's own choices.
  const out = execFileSync('dart', ['run', 'tool/replay.dart', record], { cwd: join(root, 'packages', 'engine'), encoding: 'utf8' });
  if (!/^seed \d+: /m.test(out) || !/^hand 1: scores/m.test(out) || !/^final: /m.test(out)) {
    throw new Error(`replay did not read it back:\n${out.slice(0, 300)}`);
  }
  log(`      the record replays: ${out.split('\n').length} lines`);
  await click(page, /^New game$/);
  await waitFor(page, /^Hand 1/, { what: 'a new game' });
});

flow('the about page', async ({ open }) => {
  const page = await open();
  await click(page, /^Play bots$/);
  await waitFor(page, /^Menu$/, { what: 'the table' });
  await click(page, /^Menu$/);
  await waitFor(page, /^About$/, { what: 'the menu' });
  await click(page, /^About$/);
  await waitFor(page, /^Build$/, { what: 'the about page' });
  const seen = await texts(page);
  // A deployed build stamps a sha and a date; a local one carries the
  // placeholder, and either is a value against the label.
  for (const want of [/^Build$/, /^Published$/, /^(dev|[0-9a-f]{7,}|\d{4}-\d\d-\d\d)/]) {
    if (!seen.some((t) => want.test(t))) throw new Error(`the about page has nothing for ${want}\nsaw: ${seen.join(' | ')}`);
  }
  await click(page, /^Back$/);
  await waitFor(page, /^Menu$/, { what: 'the table again' });
});

flow('the live area, and a room to share', async ({ open, relay }) => {
  await relay();
  const page = await open();
  await waitFor(page, /^Play friends$/, { what: 'the home screen' });
  // Your name and your avatar are one sheet, behind the icon in the
  // corner.
  await click(page, /^Your profile$/);
  await waitFor(page, /^Rocket$/, { what: 'the profile' });
  await type(page, 'Your name', 'Ada');
  await click(page, /^Rocket$/);
  await click(page, /^Done$/);
  await waitFor(page, /^Play friends$/, { what: 'the home screen again' });
  // This device is online from the front door, before it sits
  // anywhere, and the button says so even when it is the only one.
  await waitFor(page, /^Play live, (nobody else online|\d+ online)$/, { what: 'the online count on the button', timeout: 40000 });
  await click(page, /^Play friends$/);
  await waitFor(page, /^Share the link$/, { what: 'the room', timeout: 60000 });
  // The way in is the link, and the link is in the address bar: the
  // room says who is here and nothing about its code.
  const code = new URL(page.url()).searchParams.get('room');
  if (!/^[A-Z0-9]{8}$/.test(code ?? '')) throw new Error(`no room in the address: ${page.url()}`);
  const seen = await texts(page);
  if (seen.some((t) => t.includes(code))) throw new Error(`the code is on the screen\nsaw: ${seen.join(' | ')}`);
  // A room has one thing to say and no need to say whose app it is.
  if (seen.some((t) => /^Open Hearts$/.test(t))) throw new Error('the room still carries the name of the app over it');
  if (!seen.some((t) => /^Ada \(you\)$/.test(t))) throw new Error('the room does not say which one is you');
  if (!seen.some((t) => /^rated \d+/.test(t))) throw new Error(`no rating beside a name\nsaw: ${seen.join(' | ')}`);
  // A refresh is not a way out: the address is the room, so the device
  // comes back to it.
  await page.reload();
  await waitFor(page, /^Share the link$/, { what: 'the room after a refresh', timeout: 60000 });
  if (new URL(page.url()).searchParams.get('room') !== code) throw new Error(`the refresh landed elsewhere: ${page.url()}`);
  // Leaving a room lands back on the front door, and takes the room
  // out of the address with it.
  await click(page, /^Leave$/);
  await waitFor(page, /^Play bots$/, { what: 'the home screen after leaving' });
  if (new URL(page.url()).searchParams.get('room')) throw new Error(`the room is still in the address: ${page.url()}`);
});

// ---- the runner ----------------------------------------------------------

/// Plays for the thumb until [done], through the semantics tree —
/// quick, and the same as run.mjs. The pointer has its own flow.
async function playAlone(page, done, timeout = 120000) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    if (await done(page)) return;
    await act(page);
    await sleep(250);
  }
  throw new Error(`timed out playing alone\nsaw: ${(await texts(page)).join(' | ')}`);
}

/// Warns when the built app is older than the sources it came from —
/// the failure it saves is a flow asserting something the build does
/// not have yet.
async function checkFresh() {
  const built = statSync(join(appDir, 'main.dart.js'), { throwIfNoEntry: false })?.mtimeMs ?? 0;
  const newest = execFileSync('bash', ['-c', `find ${join(root, 'app', 'lib')} ${join(root, 'app', 'web')} -newermt @${Math.round(built / 1000)} -type f | head -3`], { encoding: 'utf8' }).trim();
  if (newest) log(`the build is older than ${newest.split('\n').join(', ')} — flutter build web -o build/e2e first`);
}

async function main() {
  const only = argOf('only');
  await checkFresh();
  const app = await serveApp();
  const browser = await chromium.launch();
  let failed = 0;
  const contexts = [];
  // Only the lobby needs a relay, and it costs a couple of seconds and
  // two processes, so it is started when something asks for one.
  let relayOnce = null;
  const relay = () => (relayOnce ??= startRelay());
  const open = async ({ viewport = portrait, pointer = false } = {}) => {
    const ctx = await browser.newContext({
      viewport,
      locale: 'en-US',
      hasTouch: true,
      isMobile: true,
      deviceScaleFactor: 2,
      // The record flow reads what Copy record put there.
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    contexts.push(ctx);
    const page = await ctx.newPage();
    page.on('pageerror', (e) => log(`page error: ${e.message}`));
    await page.goto(`${app.url}/?e2e=1`);
    // For a flow that presses with the pointer, the nodes are read for
    // their labels and their geometry and take no clicks, so every
    // press goes through the app's own hit test. The rest keep them:
    // typing into a field goes through the node's own input.
    if (pointer) {
      await page.addStyleTag({ content: 'flt-semantics, flt-semantics * { pointer-events: none !important; }' });
    }
    await waitFor(page, /^Open Hearts$|^Play bots$/, { what: 'the app', timeout: 60000 });
    return page;
  };
  for (const { name, run } of flows) {
    if (only && !name.includes(only)) continue;
    const began = Date.now();
    try {
      await run({ open, app, relay });
      log(`ok    ${name} (${((Date.now() - began) / 1000).toFixed(0)}s)`);
    } catch (e) {
      failed++;
      log(`FAIL  ${name}: ${e.message}`);
    }
  }
  for (const ctx of contexts) await ctx.close();
  await browser.close();
  app.stop();
  (await relayOnce)?.stop();
  log(failed ? `FAIL: ${failed} flow${failed === 1 ? '' : 's'}` : 'PASS');
  process.exit(failed ? 1 : 0);
}

main();
