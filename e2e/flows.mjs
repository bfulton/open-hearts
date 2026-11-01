// Every flow one device can drive, in a real browser.
//
//   ./e2e/build.sh
//   node e2e/flows.mjs                 # from the repo root
//   node e2e/flows.mjs --only "a hand alone"
//   node e2e/flows.mjs --jobs 2        # workers side by side (default 3)
//   node e2e/flows.mjs --serial        # one after another, in order
//
// run.mjs is the other half: four browsers at one table, which is the
// only way to see the live flows. This one is everything else — the
// front door, the game options, a game played out alone, the record it
// leaves, a room to share, the phone turned — and it is the only suite
// that presses anything with a real pointer rather than through the
// accessibility tree, so a tap landing in the wrong place has
// somewhere to show up.
import { AsyncResource } from 'node:async_hooks';
import { execFile, execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { gunzipSync, gzipSync } from 'node:zlib';

import { chromium } from './browser.mjs';
import { act, agreedToTerms, appDir, click, dismiss, freePort, has, labelOf, licensed, log, root, serveApp, sleep, texts, type, waitFor, waitGone, roomIn } from './drive.mjs';
import { flowRelay, runFlows } from './pool.mjs';
import { carry } from '../service/tool/suspend.mjs';

/// A tool run while flows are running: never with execFileSync, which
/// holds this whole process still — every flow's server with it — for
/// as long as the tool takes. A sealed game's fixture takes longer than
/// the app waits for an answer, so another flow's request went
/// unanswered and its page said the service could not be reached.
const run = promisify(execFile);

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
/// A flow whose devices ask to be spared motion (prefers-reduced-motion,
/// which the app honours): the folding heart and the breathing turn pill
/// hold still, and cards arrive without flying. Every flow but two: a
/// hand alone and the thumb's taps play with the motion — cards flying
/// into the fan and off it, tricks swept, the turn's pill breathing, the
/// table the same widgets alone and live — and the rest spare the
/// machine it. A page drawing motion in this headless browser is a core
/// of the machine's four for as long as it moves, and nothing else here
/// looks at it.
const stillFlow = (name, run) => flows.push({ name, run, still: true });

stillFlow('a browser whose language Intl cannot read still opens the app', async ({ open }) => {
  // Chromium on Linux with no language set says en-US@posix.
  const page = await open({ languages: ['en-US@posix'] });
  await waitFor(page, /^Open Hearts$/, { what: 'the home screen' });
  if (!(await has(page, /^Play solo$/))) throw new Error('the home screen without Play solo');
});

stillFlow('the front door', async ({ open }) => {
  const page = await open();
  await waitFor(page, /^Open Hearts$/, { what: 'the home screen' });
  const seen = await texts(page);
  // Everything before a game is on this one screen: who you are, the
  // game being asked for, and the three ways in.
  for (const want of [
    /^Open source card game, no ads$/,
    /^Menu$/,
    /^Your profile$/,
    /^Play solo$/,
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

stillFlow('the game options', async ({ open }) => {
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
  await click(page, /^Play solo$/);
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
  await click(page, /^Play solo$/);
  await waitFor(page, /^Choose 3 more to pass$/, { what: 'the pass' });
  await playAlone(page, (p) => has(p, /^Next hand$/), 120000);
  await click(page, /^Next hand$/);
  await waitFor(page, /^Hand 2/, { what: 'the second hand' });
  await click(page, /^Menu$/);
  await waitFor(page, /^Leave the table$/, { what: 'the menu' });
  await click(page, /^Leave the table$/);
  await waitFor(page, /^Play solo$/, { what: 'the home screen again' });
});

stillFlow('the rest of a hand left to Auto', async ({ open, app }) => {
  // Played by the first legal card until the table offers to play the
  // rest itself, and then left alone: the hand has to end with nobody
  // touching it. Dealt from the deal the app's own test uses
  // (app/test/autopilot_test.dart), whose first hand comes to it, so it
  // is not left to luck; as many hands as it takes, should it not.
  const page = await open({ url: '/?e2e=1&seed=156' });
  await click(page, /^Play solo$/);
  await waitFor(page, /^Choose 3 more to pass$/, { what: 'the pass' });
  const until = Date.now() + 240000;
  while (!(await has(page, /^Auto-play the rest of this hand$/))) {
    if (Date.now() > until) throw new Error(`no Auto offered\nsaw: ${(await texts(page)).join(' | ')}`);
    await dismiss(page, /^Next hand$/);
    await act(page);
    await sleep(250);
  }
  await click(page, /^Auto-play the rest of this hand$/);
  await waitFor(page, /^Next hand$|^New game$/, { what: 'the hand played out by Auto', timeout: 60000 });
  if (await has(page, /^Next hand$/)) {
    await click(page, /^Next hand$/);
    await waitFor(page, /^Choose 3 more to pass$|^Your turn$/, { what: 'the next hand' });
    if (await has(page, /^Auto-play the rest of this hand$/)) throw new Error('Auto is still up in a new hand');
  }
});

flow('a thumb, not the tree', async ({ open }) => {
  // The only flow that presses with a pointer. Every other suite here
  // clicks the semantics nodes, which never touches the app's hit
  // test, so this is where a tap landing in the wrong place shows up.
  for (const [shape, viewport] of [['portrait', portrait], ['sideways', landscape]]) {
    const page = await open({ viewport, pointer: true });
    await click(page, /^Play solo$/);
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

stillFlow('learning to play', async ({ open }) => {
  // A device new to the game: the door offers the hand that teaches it
  // (app/lib/tutorial.dart), which is dealt the same way every time.
  const page = await open({ pointer: true });
  await waitFor(page, /^New to Hearts\? Learn to play$/, { what: 'the offer on the door' });
  await click(page, /^New to Hearts\? Learn to play$/);
  await waitFor(page, /^Four players, thirteen cards each\./, { what: 'the first note' });
  // A note that tells holds the table, the player's own cards with it:
  // a card tapped under it is not chosen.
  const [first] = await handOf(page);
  await click(page, new RegExp(`^${first}$`));
  await sleep(300);
  if (!(await has(page, /^Choose 3 more to pass$/))) throw new Error(`a card was chosen under the note\nsaw: ${(await texts(page)).join(' | ')}`);
  // Next, pressed where it is drawn: the note is in a place of its own
  // under the felt, and a press there lands on it.
  await tapAt(page, /^Next$/, { dx: 20 });
  await waitFor(page, /^First, everyone passes three cards\./, { what: 'the note on the pass' });
  // The rest of the hand, each step decided on one reading of the
  // screen: a note that holds is read and Next tapped, and the player
  // moves only when the table waits on them, when nothing else moves
  // and no note comes unseen.
  const notes = {
    welcome: /^Four players, thirteen cards each\./,
    pass: /^First, everyone passes three cards\./,
    received: /^Three cards came to you from the player on your right\./,
    youLead: /^The 2 of clubs leads the first trick, and you have it\./,
    trickTaken: /^The highest card of the suit that was led takes the trick/,
    follow: /^Play a card of the suit that was led, if you have one\./,
    noSuit: /^You have no (clubs|diamonds|spades|hearts), so any card will do\./,
    heartsBroken: /^That's the first heart: hearts are broken\./,
    queen: /^The queen of spades: 13 points to whoever takes this trick\.$/,
  };
  const seen = ['welcome'];
  const until = Date.now() + 180000;
  for (;;) {
    if (Date.now() > until) throw new Error(`the hand never ended; notes ${seen.join(', ')}\nsaw: ${(await texts(page)).join(' | ')}`);
    const now = await texts(page);
    if (now.includes('Done')) break;
    const note = Object.entries(notes).find(([, re]) => now.some((t) => re.test(t)))?.[0];
    if (note && seen.at(-1) !== note) seen.push(note);
    if (now.includes('Next')) await click(page, /^Next$/);
    else if (now.includes('Pass') || now.includes('Your turn')) await act(page);
    await sleep(250);
  }
  if (seen.slice(0, 4).join() !== 'welcome,pass,received,youLead' || new Set(seen).size !== Object.keys(notes).length || seen.length !== Object.keys(notes).length) {
    throw new Error(`not every note, once each, in its place: ${seen.join(', ')}`);
  }
  // One hand, and its sheet says how a hand is scored; Done goes home.
  const sheet = await texts(page);
  if (!sheet.some((t) => /^Hearts are a point each, the queen of spades 13\./.test(t))) throw new Error(`the sheet without the score's note\nsaw: ${sheet.join(' | ')}`);
  if (sheet.includes('Next hand')) throw new Error('the taught hand offers another');
  await click(page, /^Done$/);
  await waitFor(page, /^Play solo$/, { what: 'the door again' });
  // Taken up, it is not offered again, on this visit or the next; and it
  // stays in the menu.
  if (await has(page, /^New to Hearts\? Learn to play$/)) throw new Error('the door still offers the tutorial');
  await page.reload();
  await waitFor(page, /^Play solo$/, { what: 'the door after a reload' });
  if (await has(page, /^New to Hearts\? Learn to play$/)) throw new Error('the door offers the tutorial again after a reload');
  await click(page, /^Menu$/);
  await waitFor(page, /^Learn to play$/, { what: 'the tutorial in the menu' });
  await click(page, /^Learn to play$/);
  await waitFor(page, /^Four players, thirteen cards each\./, { what: 'the tutorial from the menu' });
});

stillFlow('turning the phone mid-hand', async ({ open }) => {
  const page = await open();
  await click(page, /^Play solo$/);
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

stillFlow('a game alone, and the record it leaves', async ({ open, relay }) => {
  // A game of one hand (`target=1`, app/lib/net/address.dart): its end,
  // its record and its count are what is looked at, not its length. The
  // game needs no relay; the profile at the end asks the relays for the
  // rating, so there is one to ask.
  await relay();
  const page = await open({ url: '/?e2e=1&target=1' });
  await click(page, /^Play solo$/);
  // Hand after hand until the game is over.
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
  // A game dealt from 256 bits of the secure generator, which the record
  // names (docs/explanation/fair-deal.md).
  if (!/^oh2:[0-9a-f]{64}:/.test(record ?? '')) throw new Error(`the record does not look like one: ${JSON.stringify((record ?? '').slice(0, 80))}`);
  // And it is a record the tool can read: every trick, from the seed
  // and the player's own choices.
  const { stdout: out } = await run('dart', ['run', 'tool/replay.dart', record], { cwd: join(root, 'packages', 'engine'), encoding: 'utf8' });
  if (!/^seed [0-9a-f]{64}: /m.test(out) || !/^hand 1: scores/m.test(out) || !/^final: /m.test(out)) {
    throw new Error(`replay did not read it back:\n${out.slice(0, 300)}`);
  }
  log(`      the record replays: ${out.split('\n').length} lines`);
  await click(page, /^New game$/);
  await waitFor(page, /^Hand 1/, { what: 'a new game' });

  // And the game that was just played is on the profile. The device
  // counts its own games by playing them again from the record, so
  // this is the whole way round: played by thumb, kept, replayed,
  // counted.
  await click(page, /^Menu$/);
  await waitFor(page, /^Leave the table$/, { what: 'the menu' });
  await click(page, /^Leave the table$/);
  await waitFor(page, /^Play solo$/, { what: 'the front door' });
  await click(page, /^Your profile$/);
  await waitFor(page, /^Alone$/, { what: 'the profile page', timeout: 40000 });
  const record0 = await texts(page);
  for (const want of [/^Rating$/, /^Your games$/, /^Live$/, /^Alone$/, /^played$/, /^won$/, /^average$/, /^best$/]) {
    if (!record0.some((t) => want.test(t))) throw new Error(`no ${want} on the profile\nsaw: ${record0.join(' | ')}`);
  }
  // Nothing rated has been played here, so there is no rating to show
  // and the page says why rather than showing the number everyone
  // starts at, once the relays have answered; until then it says it is
  // still counting. (With none to answer it says that instead, which
  // offline.mjs holds it to.)
  if (record0.some((t) => /^1500$/.test(t))) throw new Error('the profile shows the rating nobody earned');
  await waitFor(page, /^Play a rated live game and you will have one$/, {
    what: 'the profile to say why there is no rating',
    timeout: 20000,
  });
});

stillFlow('the about page', async ({ open }) => {
  const page = await open();
  await click(page, /^Play solo$/);
  // The table by what only the table says: the front door has a Menu
  // too, and on a frame that comes late that is the one clicked, its
  // menu then covered by the table.
  await waitFor(page, /^Choose 3 more to pass$/, { what: 'the table' });
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

stillFlow('the live area, and a room to share', async ({ open, relay }) => {
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
  const code = roomIn(page.url());
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
  if (roomIn(page.url()) !== code) throw new Error(`the refresh landed elsewhere: ${page.url()}`);
  // Leaving a room lands back on the front door, and takes the room
  // out of the address with it.
  await click(page, /^Leave$/);
  await waitFor(page, /^Play solo$/, { what: 'the home screen after leaving' });
  if (roomIn(page.url())) throw new Error(`the room is still in the address: ${page.url()}`);
});

stillFlow('the backup codes, shown on request and copied', async ({ open }) => {
  // Copy goes through the page (app/web/copy.js) so that Safari allows
  // it; here, that the text that arrives is the codes the page shows.
  const page = await open();
  await waitFor(page, /^Play live/, { what: 'live play open', timeout: 40000 });
  await click(page, /^Menu$/);
  await waitFor(page, /^Subscription$/, { what: 'the menu' });
  await click(page, /^Subscription$/);
  await waitFor(page, /^This device$/, { what: 'the subscription page' });
  await waitFor(page, /^Show backup codes$/, { what: 'the backup codes button' });
  await click(page, /^Show backup codes$/);
  await waitFor(page, /^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/, { what: 'the codes' });
  const shown = (await texts(page)).filter((t) => /^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/.test(t));
  if (shown.length !== 5) throw new Error(`five codes, not ${shown.length}`);
  // The Copy under the list, not one beside a code: the last of them.
  const copies = await page.$$('flt-semantics[aria-label="Copy"], flt-semantics[role="button"]:text-is("Copy")');
  if (!copies.length) throw new Error('no Copy button');
  await copies[copies.length - 1].click();
  await sleep(500);
  const copied = await page.evaluate('navigator.clipboard.readText()');
  if (copied.split('\n').join(',') !== shown.join(',')) throw new Error(`copied ${JSON.stringify(copied)}, shown ${shown.join(',')}`);
});

stillFlow('a device deletes its account, asked first, and the page starts again as a new player', async ({ open, app }) => {
  // app/lib/subscribe_page.dart, _delete; service/functions/worker.mjs,
  // deleteRoute; app/lib/start_afresh.dart. The rig's open house makes
  // the device an account, as a purchase would.
  const page = await open();
  await waitFor(page, /^Play live/, { what: 'live play open', timeout: 40000 });
  const item = (key) => page.evaluate((k) => localStorage.getItem(k), key);
  const secret = await item('flutter.identity_secret');
  const { key, account } = JSON.parse(JSON.parse(await item('flutter.licence')));
  if (!app.store.rows.has(`ACCOUNT#${account}|META`)) throw new Error(`no account ${account} at the service`);
  await click(page, /^Menu$/);
  await waitFor(page, /^Subscription$/, { what: 'the menu' });
  await click(page, /^Subscription$/);
  await waitFor(page, /^This device$/, { what: 'the subscription page' });
  await click(page, /^Delete account$/);
  await waitFor(page, /^Delete your account\?$/, { what: 'the screen that asks first' });
  // Set on this load of the page, and gone with it.
  await page.evaluate(() => { window.ohBeforeDeleting = true; });
  await click(page, /^Delete account$/);
  // The page loads again, as a device that never was, and the rig's
  // open house licenses it as a new one.
  const again = async () => {
    try {
      const licence = await item('flutter.licence');
      return licence !== null && JSON.parse(JSON.parse(licence)).key !== key;
    } catch {
      return false;
    }
  };
  for (let i = 0; i < 240 && !(await again()); i++) await sleep(250);
  await waitFor(page, /^Play live|^Play solo$|^This device$/, { what: 'the app again, after the reload', timeout: 60000 });
  if (await page.evaluate(() => window.ohBeforeDeleting === true)) throw new Error('the page was not loaded again');
  if ((await item('flutter.device_started_afresh')) === null) throw new Error('not started afresh');
  if (!(await again())) throw new Error('not licensed as a new device');
  const now = await item('flutter.identity_secret');
  if (now === secret) throw new Error('the same key after the deletion');
  const rows = [...app.store.rows.keys()].filter((k) => k.includes(account) || k.includes(key));
  if (rows.length) throw new Error(`the service still holds ${rows.join(', ')}`);
  if (!app.records.kept.has(`forgotten/${account}`)) throw new Error('the account is not marked forgotten');
});

stillFlow('a page keeps its address: away to another site and back lands on it', async ({ open }) => {
  // Stripe's checkout and portal are whole pages of their own. The back
  // button from there loads the app again, and it has to come back to
  // the page that left (app/lib/pages.dart), not to the front door.
  const page = await open();
  await waitFor(page, /^Play live/, { what: 'live play open', timeout: 40000 });
  await click(page, /^Menu$/);
  await waitFor(page, /^Subscription$/, { what: 'the menu' });
  await click(page, /^Subscription$/);
  await waitFor(page, /^This device$/, { what: 'the subscription page' });
  await sleep(300);
  if (new URL(page.url()).pathname !== '/subscription') throw new Error(`the address does not name the page: ${page.url()}`);
  await page.goto('about:blank');
  await page.goBack();
  await waitFor(page, /^This device$/, { what: 'the subscription page, after coming back', timeout: 60000 });
  // And back from there is the front door.
  await page.goBack();
  await waitFor(page, /^Play solo$/, { what: 'the home screen' });
  await sleep(500);
  if (await has(page, /^This device$/)) throw new Error('still on the subscription page');
});

stillFlow('every page by its own address: opened, refreshed, and back to the front door', async ({ open, app }) => {
  // A link to a page, a refresh on it, or history landing on it opens
  // that page over the front door (app/lib/router.dart).
  const page = await open({ url: '/about?e2e=1', ready: /^Build$/ });
  await page.reload();
  await waitFor(page, /^Build$/, { what: 'the about page, after a refresh', timeout: 60000 });
  if (new URL(page.url()).searchParams.get('e2e') !== '1') throw new Error(`the session's parameters went: ${page.url()}`);
  await click(page, /^Back$/);
  await waitFor(page, /^Play solo$/, { what: 'the front door, under it' });
  if (new URL(page.url()).pathname !== '/') throw new Error(`the address did not come home: ${page.url()}`);
  // A game is reached only by playing: its address alone is the front door.
  const game = await open({ url: '/live?e2e=1' });
  await waitFor(game, /^Play solo$/, { what: 'the front door, for a game\'s address' });
  if (new URL(game.url()).pathname !== '/') throw new Error(`a game's address stayed: ${game.url()}`);
});

stillFlow('a kept game, opened by its address: checked in the browser, then shown hand by hand — and one the older library kept', async ({ open, app }) => {
  // A real record, as a player's device sends one: a sealed game of four
  // played out on the simulator (packages/table, tool/game_fixture.dart),
  // kept as the site keeps it. The browser fetches it and replays every
  // signature and every step of the deal before showing a card.
  const json = (await run('dart', ['run', 'tool/game_fixture.dart'], { cwd: join(root, 'packages', 'table'), maxBuffer: 16 << 20, encoding: 'utf8' })).stdout.trim();
  const table = JSON.parse(json).spec.id;
  app.records.kept.set(`tables/${table}.json`, gzipSync(Buffer.from(json)));
  const page = await open({ url: `/table/${table}?e2e=1`, ready: /^The game$/ });
  const began = Date.now();
  // The check runs in a worker of its own (app/worker/review_worker.dart):
  // the page's thread stays free the whole time, which a script asking
  // the page for nothing, over and over, measures. Each hand is shown as
  // its check is done.
  let slowest = 0;
  let checking = true;
  const watching = (async () => {
    while (checking) {
      const t = Date.now();
      await page.evaluate('1');
      slowest = Math.max(slowest, Date.now() - t);
      await sleep(100);
    }
  })();
  await waitFor(page, /^Hand 1  ·  Pass left$/, { what: 'the first hand, checked', timeout: 180000 });
  const first = (Date.now() - began) / 1000;
  await waitGone(page, /^Checking the rest of the game…$/, { what: 'the rest of the game, checked', timeout: 180000 });
  checking = false;
  await watching;
  log(`      first hand shown in ${first.toFixed(1)}s, the whole game checked in ${((Date.now() - began) / 1000).toFixed(1)}s; the page answered within ${slowest} ms throughout`);
  if (slowest > 1500) throw new Error(`the page was held still for ${slowest} ms while the game was checked`);
  // The tricks under it (a list builds only what is on the screen).
  // As a screen reader reads it: each trick, each card by its name and
  // who played it.
  await waitFor(page, /^Trick 1$/, { what: 'the hand\'s tricks' });
  await waitFor(page, /^\w+ of \w+, (Ada|Bao|Cy|Dee)$/, { what: 'a card, by name and player' });
  if (await has(page, /does not check out/)) throw new Error('the record did not check out');
  // And a game as the deal on arkworks 0.3 wrote it — a sealed game of
  // four (packages/table, tool/kept_records.dart, kept in its test
  // fixtures) — checked by the page with today's wasm: every proof in it
  // made by the older library, every one replayed by this one. After the
  // first is done, so that its page's stillness is measured alone.
  const packed = readFileSync(join(root, 'packages', 'table', 'test', 'fixtures', 'sealed_four.json.gz'));
  const older = JSON.parse(gunzipSync(packed).toString()).spec.id;
  app.records.kept.set(`tables/${older}.json`, packed);
  const kept = await open({ url: `/table/${older}?e2e=1`, ready: /^The game$/ });
  await waitFor(kept, /^Hand 1  ·  Pass left$/, { what: 'the older library\'s first hand, checked', timeout: 180000 });
  await waitGone(kept, /^Checking the rest of the game…$/, { what: 'the rest of the older library\'s game, checked', timeout: 180000 });
  await waitFor(kept, /^\w+ of \w+, (Ada|Bao|Cy|Dee)$/, { what: 'a card of the older library\'s game' });
  if (await has(kept, /does not check out/)) throw new Error('the older library\'s record did not check out');
  // An address that is not a table's goes to the front door.
  const nowhere = await open({ url: '/table/not-a-table?e2e=1' });
  if (new URL(nowhere.url()).pathname !== '/') throw new Error(`a bad table address stayed: ${nowhere.url()}`);
});

stillFlow('a game watched as it is played, from the link a player shares', async ({ open, relay }) => {
  // Ada alone in the pool is seated with three bots. Her menu shares the
  // table's address; whoever opens it watches the game from outside it
  // (packages/table, watch.dart): one seated player's device answers
  // them with what everyone at the table sees, and no hand.
  await relay();
  const ada = await open();
  await waitFor(ada, /^Play live/, { what: 'live play open', timeout: 40000 });
  await click(ada, /^Your profile$/);
  await waitFor(ada, /^Rocket$/, { what: 'the profile' });
  await type(ada, 'Your name', 'Ada');
  await click(ada, /^Done$/);
  await waitFor(ada, /^Play live/, { what: 'the home screen again' });
  await click(ada, /^Play live/);
  await waitFor(ada, /^1 of 1 here  ·  rated$/, { what: 'Ada alone with three bots', timeout: 60000 });
  await click(ada, /^Menu$/);
  await waitFor(ada, /^Share a link to watch$/, { what: 'the table\'s menu' });
  await click(ada, /^Share a link to watch$/);
  await sleep(500);
  const link = await ada.evaluate('navigator.clipboard.readText()');
  if (!/\/table\/[0-9a-f]{32}$/.test(new URL(link).pathname)) throw new Error(`not a table's link: ${link}`);

  const watcher = await open({ url: `${link}?e2e=1`, ready: /^The game$/ });
  await waitFor(watcher, /^Live$/, { what: 'the game, live', timeout: 60000 });
  // Ada plays on; the watcher sees the cards land, by name and player.
  const until = Date.now() + 240000;
  while (Date.now() < until && !(await has(watcher, /^\w+ of \w+, \S/))) {
    await act(ada);
    await sleep(300);
  }
  if (!(await has(watcher, /^\w+ of \w+, \S/))) throw new Error(`no card seen from outside\nAda saw: ${(await texts(ada)).join(' | ')}\nthe watcher saw: ${(await texts(watcher)).join(' | ')}`);
  await waitFor(watcher, /^Trick 1$/, { what: 'the first trick' });
  // Nothing of anybody's hand: a hand would be thirteen cards with no
  // player to them, and every card here has one.
  const bare = (await texts(watcher)).filter((t) => /^\w+ of \w+$/.test(t));
  if (bare.length) throw new Error(`cards with nobody's play to them, seen from outside: ${bare.join(', ')}`);
});

stillFlow('an empty pool: waiting for a person past the ten seconds, then bots after all', async ({ open, relay }) => {
  // Alone in the pool, Ada chooses to wait for a person: the round
  // after ten seconds does not seat her with bots, the screen counts
  // her wait out of five minutes, and the forty seconds after which a
  // device nobody hears gives up (stopWaiting) do not end it. Then she
  // takes bots, and is seated at the next round, not sent back to the
  // door because her wait for a person is over.
  await relay();
  const ada = await open();
  await waitFor(ada, /^Play live/, { what: 'live play open', timeout: 40000 });
  await click(ada, /^Your profile$/);
  await waitFor(ada, /^Rocket$/, { what: 'the profile' });
  await type(ada, 'Your name', 'Ada');
  await click(ada, /^Done$/);
  await waitFor(ada, /^Play live/, { what: 'the home screen again' });
  await click(ada, /^Play live/);
  await waitFor(ada, /^Finding players$/);
  await click(ada, /^Wait for a person$/);
  await waitFor(ada, /^Waiting for a person$/);
  await waitFor(ada, /^0:\d\d of 5:00 — then bots fill the empty seats$/, { what: 'the wait counted out of five minutes' });
  // The count is only on the screen while she is still waiting for a
  // person: at 0:45 she has outlasted both.
  await waitFor(ada, /^0:4[5-9] of 5:00 — then bots fill the empty seats$/, { what: 'still waiting at 0:45', timeout: 60000 });
  await click(ada, /^Play now with bots$/);
  await waitFor(ada, /^1 of 1 here  ·  rated$/, { what: 'Ada with three bots, as she asked', timeout: 30000 });
});

stillFlow('a live game played to its end, then looked at from its end', async ({ open, relay }) => {
  // Ada alone in the pool, with three bots, plays a game by the first
  // legal card: a game of one hand (`target=1`, app/lib/net/address.dart),
  // since its end is the point. At its end the sheet offers the whole
  // game: the account has got up from the table, and the service has
  // heard so before it is asked, so it is shown — not turned away as a
  // game the account is still playing (net/game_records.dart,
  // net/in_use.dart).
  await relay();
  const ada = await open({ url: '/?e2e=1&target=1' });
  await waitFor(ada, /^Play live/, { what: 'live play open', timeout: 40000 });
  await click(ada, /^Your profile$/);
  await waitFor(ada, /^Rocket$/, { what: 'the profile' });
  await type(ada, 'Your name', 'Ada');
  await click(ada, /^Done$/);
  await waitFor(ada, /^Play live/, { what: 'the home screen again' });
  await click(ada, /^Play live/);
  await waitFor(ada, /^1 of 1 here  ·  rated$/, { what: 'Ada alone with three bots', timeout: 60000 });
  const until = Date.now() + 1200000;
  while (!(await has(ada, /^See the whole game$/))) {
    if (Date.now() > until) throw new Error(`no end to the game\nsaw: ${(await texts(ada)).join(' | ')}`);
    if (await has(ada, /^Auto-play the rest of this hand$/)) await dismiss(ada, /^Auto-play the rest of this hand$/);
    await dismiss(ada, /^On with it$/);
    await act(ada);
    await sleep(300);
  }
  await click(ada, /^See the whole game$/);
  await waitFor(ada, /^The game$/, { what: 'the game\'s page' });
  // Its first hand shown — the first, unless a busy machine had the
  // table give one up undealt (packages/table, undealt_hand_test.dart),
  // which has nothing to show.
  await waitFor(ada, /^Hand \d+  ·  /, { what: 'the game, shown from its end', timeout: 180000 });
  if (await has(ada, /This is your own game/)) throw new Error('the game was turned away as one still being played');
});

stillFlow('a reaction at a live table: one player sends 👍, and the other sees it by her seat', async ({ open, app, relay }) => {
  // Two people at a friends' table, two bots with them. Ada presses the
  // speech bubble beside her badge and picks Nice; it goes on the
  // table's tag, signed by her device, and Bao's screen shows it beside
  // Ada's badge for a moment (packages/table, reactions.dart).
  await relay();
  const ada = await open();
  const bao = await open();
  for (const [page, name] of [[ada, 'Ada'], [bao, 'Bao']]) {
    await waitFor(page, /^Play friends$/, { what: 'the home screen' });
    await click(page, /^Your profile$/);
    await waitFor(page, /^Rocket$/, { what: 'the profile' });
    await type(page, 'Your name', name);
    await click(page, /^Done$/);
    await waitFor(page, /^Play live/, { what: 'live play open', timeout: 40000 });
  }
  await click(ada, /^Play friends$/);
  await waitFor(ada, /^Share the link$/, { what: 'the room', timeout: 60000 });
  const code = roomIn(ada.url());
  await bao.goto(app.at(`/room/${code}?e2e=1`));
  // The room starts ten seconds after the last arrival.
  for (const page of [ada, bao]) await waitFor(page, /^2 of 2 here/, { what: 'the live table', timeout: 90000 });

  // Nobody at the table but its players has the button; Ada's opens the
  // six, and her pick goes.
  await waitFor(ada, /^React$/, { what: 'the speech bubble beside Ada\'s badge' });
  // A relay keeps no reaction: it goes to whoever is subscribed when it
  // is said (packages/table, reactions.dart), and a screen showing the
  // table may not have its subscription in place yet on a busy machine
  // (on CI, Bao's screen was still on the deal's first step, with only
  // its own part of it, five seconds after she reacted). Bao's screen
  // hears the table and its reactions on one subscription
  // (relay_transport.dart), and its hand is dealt only once it has heard
  // Ada's steps of the deal: with its cards showing, a reaction said now
  // reaches it.
  await waitFor(bao, cardName, { what: 'Bao\'s hand, dealt', timeout: 120000 });
  // The six emoji come with the app (app/fonts/README.md): drawing them
  // fetches no font, from Google's servers or anywhere else, so they
  // are there the moment the picker opens and a bubble shows.
  const fontsFetched = [];
  for (const page of [ada, bao]) page.on('request', (r) => /fonts\.gstatic\.com|notocoloremoji/i.test(r.url()) && fontsFetched.push(r.url()));
  await click(ada, /^React$/);
  await waitFor(ada, /^Good game$/, { what: 'the reactions to pick from' });
  await click(ada, /^Nice$/);
  // On Bao's screen, beside Ada's badge: nearer it than any other
  // seat's. Looked for from the moment it is said, and measured as soon
  // as it shows, in the one look: it is there for three seconds, and a
  // busy machine can spend them on Ada's screen first, or between two
  // looks.
  const onBao = (async () => {
    for (const until = Date.now() + 5000; Date.now() < until; await sleep(100)) {
      const r = await rectOf(bao, /^Ada: Nice$/).catch(() => null);
      if (r) return r;
    }
    return null;
  })();
  await waitFor(ada, /^You: Nice$/, { what: 'Ada\'s own reaction, in the button\'s place', timeout: 5000 });
  const bubble = await onBao;
  if (fontsFetched.length) throw new Error(`the reactions fetched fonts: ${fontsFetched.join(', ')}`);
  if (!bubble) throw new Error(`no reaction on Bao's screen within 5 s of its saying\nBao saw: ${(await texts(bao)).join(' | ')}`);
  const centre = (r) => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });
  const away = (r) => Math.hypot(centre(r).x - centre(bubble).x, centre(r).y - centre(bubble).y);
  const badges = (await texts(bao)).filter((t) => /^[^:]+: \d+ in the game/.test(t));
  const nearest = (await Promise.all(badges.map(async (b) => ({ b, d: away(await rectOf(bao, new RegExp(`^${b.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`))) })))).sort((p, q) => p.d - q.d)[0];
  if (!nearest || !nearest.b.startsWith('Ada:')) throw new Error(`the reaction is nearest ${nearest?.b ?? 'nothing'}, not Ada's badge\nBao saw: ${(await texts(bao)).join(' | ')}`);
  // Gone again in a few seconds, on both screens.
  await waitGone(bao, /^Ada: Nice$/, { what: 'the reaction gone', timeout: 8000 });
  await waitFor(ada, /^React$/, { what: 'the button back', timeout: 8000 });
});

stillFlow('a reload mid-hand comes back to the seat, and the hand plays on', async ({ open, relay }) => {
  // The page keeps what it signed and its deal secret as it plays
  // (app/lib/net/seat_store.dart); reloaded, it goes straight back to
  // the table, is caught up by it, and plays the hand out in its own
  // seat (packages/table, journal.dart).
  await relay();
  const ada = await open();
  await waitFor(ada, /^Play live/, { what: 'live play open', timeout: 40000 });
  await click(ada, /^Your profile$/);
  await waitFor(ada, /^Rocket$/, { what: 'the profile' });
  await type(ada, 'Your name', 'Ada');
  await click(ada, /^Done$/);
  await waitFor(ada, /^Play live/, { what: 'the home screen again' });
  await click(ada, /^Play live/);
  await waitFor(ada, /^1 of 1 here  ·  rated$/, { what: 'Ada alone with three bots', timeout: 60000 });
  // Into the play: a few of her own cards down.
  let played = 0;
  const until = Date.now() + 240000;
  while (Date.now() < until && played < 3) {
    const before = (await texts(ada)).filter((t) => /^\w+ of \w+$/.test(t)).length;
    await act(ada);
    await sleep(400);
    if ((await has(ada, /^Your (turn|lead)$/)) === false && before > 0) {
      const after = (await texts(ada)).filter((t) => /^\w+ of \w+$/.test(t)).length;
      if (after < before && !(await has(ada, /^Pass$/))) played++;
    }
  }
  const hand = (await texts(ada)).find((t) => /^Hand \d/.test(t));
  if (!hand) throw new Error(`not at the table: ${(await texts(ada)).join(' | ')}`);
  log(`      reloading in "${hand}"`);
  await ada.reload();
  // Back at the table by itself, the seat still hers.
  await waitFor(ada, /^Hand \d/, { what: 'back at the table after the reload', timeout: 60000 });
  if (await has(ada, /bot (took|has) your seat|took over your seat/i)) throw new Error('a bot has the seat');
  // And plays on: to the next hand, or the end.
  const next = `Hand ${Number(hand.match(/^Hand (\d+)/)[1]) + 1}`;
  const end = Date.now() + 300000;
  while (Date.now() < end && !(await has(ada, new RegExp(`^${next} `))) && !(await has(ada, /^Home$/))) {
    await act(ada);
    await sleep(300);
  }
  if (!(await has(ada, new RegExp(`^${next} `))) && !(await has(ada, /^Home$/))) {
    throw new Error(`the hand did not play out after the reload: ${(await texts(ada)).join(' | ')}`);
  }
});

stillFlow('a second device, brought in by the code the first one shows', async ({ open }) => {
  // A subscription is a person's, not a device's (docs/explanation/service.md).
  // The first device shows a code; the second arrives carrying it, and
  // ends up on the same subscription rather than one of its own — which
  // is the thing worth proving here, since the rig's open house would
  // licence any device that simply asked.
  const first = await open();
  await waitFor(first, /^Play live/, { what: 'live play open on the first device', timeout: 40000 });
  await click(first, /^Menu$/);
  await waitFor(first, /^Subscription$/, { what: 'the menu' });
  await click(first, /^Subscription$/);
  await waitFor(first, /^Add a device$/, { what: 'the subscription page' });
  await waitFor(first, /^This device$/, { what: 'this device on the list' });
  await click(first, /^Add a device$/);
  await waitFor(first, /^A code to scan$/, { what: 'the code' });

  // The link the code travels in, off the clipboard: no camera here,
  // and none in the app either — the QR is for a phone's own.
  await click(first, /^Send the link instead$/);
  await sleep(500);
  const link = await first.evaluate('navigator.clipboard.readText()');
  if (!/[?&]claim=[0-9a-f]+/.test(link)) throw new Error(`no code in the link: ${link}`);
  if (new URL(link).pathname !== '/' || new URL(link).hash) throw new Error(`the link carries a page with it: ${link}`);

  // A second device, opening it.
  // Asked before anything is spent, since a link is anybody's to send:
  // the question is the first thing it shows, over the front door.
  const second = await open({ url: link, ready: /^Join this subscription\?$/ });
  await click(second, /^Join$/);
  await waitFor(second, /^Play live/, { what: 'live play open on the second device', timeout: 40000 });
  // The code is spent, so it leaves the address — after it has been
  // spent, which is a moment later than the door opening: the rig's
  // open house licenses any device that asks, so this screen was never
  // waiting on the claim to be let in.
  for (let guard = 0; guard < 40 && new URL(second.url()).searchParams.get('claim'); guard++) await sleep(250);
  if (new URL(second.url()).searchParams.get('claim')) throw new Error(`the code is still in the address: ${second.url()}`);

  // And the first device's subscription now carries both of them. The
  // page reads the list when it opens, so it is opened again.
  // A reload keeps the page it was on (app/lib/pages.dart).
  await first.reload();
  await waitFor(first, /^2 of 5$/, { what: 'both devices on the subscription, after a reload', timeout: 40000 });
});

stillFlow('one device at a time: the newest opened wins, and the other takes it back — asked first when it is at a table', async ({ open, relay }) => {
  // An account plays on one device at a time (docs/explanation/service.md). The
  // second device comes into the first one's account by its code, and
  // opening it is taking the account up: the first steps back, off the
  // relays, and says so. Taken back, the second does. And a device at a
  // table is asked about before its game is lost.
  await relay();
  const first = await open();
  await waitFor(first, /^Play live/, { what: 'live play open on the first device', timeout: 40000 });
  await click(first, /^Your profile$/);
  await waitFor(first, /^Rocket$/, { what: 'the profile' });
  await type(first, 'Your name', 'Ada');
  await click(first, /^Done$/);
  await waitFor(first, /^Menu$/, { what: 'the home screen again' });
  await click(first, /^Menu$/);
  await waitFor(first, /^Subscription$/, { what: 'the menu' });
  await click(first, /^Subscription$/);
  await waitFor(first, /^Add a device$/, { what: 'the subscription page' });
  await click(first, /^Add a device$/);
  await waitFor(first, /^A code to scan$/, { what: 'the code' });
  await click(first, /^Send the link instead$/);
  await sleep(500);
  const link = await first.evaluate('navigator.clipboard.readText()');
  await click(first, /^Back$/);
  await waitFor(first, /^Play solo$/, { what: 'the front door' });

  const second = await open({ url: link, ready: /^Join this subscription\?$/ });
  await click(second, /^Join$/);
  // Opened, and in the account: it takes the account up, and the first
  // hears so and steps back.
  await waitFor(first, /^Open Hearts is now open on another device$/, { what: 'the first device stepping back', timeout: 40000 });
  await waitFor(second, /^Play live/, { what: 'live play open on the second device', timeout: 40000 });
  if (await has(second, /^Open Hearts is now open on another device$/)) throw new Error('both devices say the other is in use');

  // Taken back on the first.
  await click(first, /^Use it here$/);
  await waitGone(first, /^Open Hearts is now open on another device$/, { what: 'the first device in use again', timeout: 20000 });
  await waitFor(second, /^Open Hearts is now open on another device$/, { what: 'the second device stepping back', timeout: 40000 });

  // The first sits down at a table; the second, asked to take the
  // account, says the game would be lost, and on the word does it.
  await waitFor(first, /^Play live/, { what: 'live play on the first device', timeout: 40000 });
  await click(first, /^Play live/);
  await waitFor(first, /^1 of 1 here  ·  rated$/, { what: 'Ada at a table with three bots', timeout: 60000 });
  await click(second, /^Use it here$/);
  await waitFor(second, /^You're in a game on another device$/, { what: 'the question first', timeout: 20000 });
  await waitFor(second, /^Continue here\? That game will be lost\.$/, { what: 'and what it costs' });
  if (await has(first, /^Open Hearts is now open on another device$/)) throw new Error('the first device stepped back before anybody said so');
  await click(second, /^Continue here$/);
  await waitFor(first, /^Open Hearts is now open on another device$/, { what: 'the first device leaving its table', timeout: 40000 });
  await waitGone(second, /^You're in a game on another device$/, { what: 'the second device in use', timeout: 20000 });
  if (await has(first, /^1 of 1 here/)) throw new Error('the first device is still at its table');
});

stillFlow('suspended by the operator: live play shut, the subscribe page says why and sells nothing; let back, open again', async ({ open, app, relay }) => {
  // The operator's tool orders it as it does in production
  // (service/tool/suspend.mjs, carry): an order written into the store,
  // and the service asked over HTTP to carry it out. The rig has no
  // relay objects to cut the device off at (household.mjs, revokerOf),
  // so the device hears it from the service, as one the relay's word
  // missed does: here, at its next licence check.
  await relay();
  // The rig's store is its worker's, and the flows before this one left
  // their devices in it: this device is the one it licenses now.
  const devices = () => [...app.store.rows.keys()].filter((k) => /^KEY#[0-9a-f]{64}\|ENTITLEMENT$/.test(k));
  const before = new Set(devices());
  const device = await open();
  await licensed(device);
  const rows = devices().filter((k) => !before.has(k));
  if (rows.length !== 1) throw new Error(`one device licensed, not ${rows.length}`);
  const { account } = await app.store.get(...rows[0].split('|'));
  const order = async (act) => {
    const done = await carry(app.store, account, act, {}, { origin: app.preview, tries: 1, wait: 0 });
    if (done.status !== 200) throw new Error(`${act}: the service said ${done.status} ${JSON.stringify(done.body)}`);
  };

  await order('suspend');
  await device.reload();
  await waitFor(device, /^Play solo$/, { what: 'the front door', timeout: 60000 });
  await waitFor(device, /^Subscribe$/, { what: 'live play no longer open', timeout: 30000 });
  if (await has(device, /^Play live/)) throw new Error('live play is still open on a suspended device');
  await click(device, /^Subscribe$/);
  await waitFor(device, /^Suspended from live play$/, { what: 'the subscribe page saying so', timeout: 20000 });
  await waitFor(device, /^This account is suspended from live play under the terms of use\./, { what: 'and how to ask why' });
  if (await has(device, /^By subscribing, you agree to the Terms of use\.$/)) throw new Error('a suspended account is offered a subscription');

  // Let back: the page, reloaded where it was, holds a licence again.
  await order('lift');
  await device.reload();
  await waitFor(device, /^Open on this device, to /, { what: 'the licence back', timeout: 60000 });
  if (await has(device, /^Suspended from live play$/)) throw new Error('still said to be suspended');
});

/// What the profile page shows: the name in its field — which the
/// field's input holds once it has the focus — and whether the rocket
/// is the icon chosen.
async function profileShown(page) {
  const input = page.locator('flt-semantics[aria-label="Your name"] input, input[aria-label="Your name"]').first();
  await input.click();
  await sleep(300);
  const name = await input.inputValue();
  const rocket = await page.evaluate(`(() => {
    const labelOf = ${labelOf};
    const node = [...document.querySelectorAll('flt-semantics')].find((e) => labelOf(e) === 'Rocket');
    return node ? node.getAttribute('aria-current') ?? node.getAttribute('aria-selected') : null;
  })()`);
  return { name, rocket };
}

stillFlow('the profile is the account\'s: changed on one device, the other shows it at its next start', async ({ open, relay }) => {
  // The name and how you look are the account's (docs/explanation/service.md):
  // kept by the service with the account, written from the device in
  // use, and read by the others when they start. Two devices of one
  // account, brought together as the device-at-a-time flow brings them.
  await relay();
  const first = await open();
  await waitFor(first, /^Play live/, { what: 'live play open on the first device', timeout: 40000 });
  await click(first, /^Menu$/);
  await waitFor(first, /^Subscription$/, { what: 'the menu' });
  await click(first, /^Subscription$/);
  await waitFor(first, /^Add a device$/, { what: 'the subscription page' });
  await click(first, /^Add a device$/);
  await waitFor(first, /^A code to scan$/, { what: 'the code' });
  await click(first, /^Send the link instead$/);
  await sleep(500);
  const link = await first.evaluate('navigator.clipboard.readText()');
  await click(first, /^Back$/);
  await waitFor(first, /^Play solo$/, { what: 'the front door' });

  const second = await open({ url: link, ready: /^Join this subscription\?$/ });
  await click(second, /^Join$/);
  await waitFor(first, /^Open Hearts is now open on another device$/, { what: 'the second device in use', timeout: 40000 });
  await waitFor(second, /^Play live/, { what: 'live play open on the second device', timeout: 40000 });

  // Changed on the second, the device in use.
  await click(second, /^Your profile$/);
  await waitFor(second, /^Rocket$/, { what: 'the profile on the second device' });
  await type(second, 'Your name', 'Bao');
  await click(second, /^Rocket$/);
  await click(second, /^Done$/);
  await waitFor(second, /^Play solo$/, { what: 'the second device\'s front door' });

  // The first starts again: it takes the account up, reads its profile,
  // and shows it. The read may land after the page is opened, so it is
  // opened until it shows the account's — closed unchanged in between,
  // which writes nothing.
  await first.reload();
  await waitFor(first, /^Play live/, { what: 'live play open on the first device again', timeout: 40000 });
  let name = null;
  let rocket = null;
  for (let tries = 0; tries < 20; tries++) {
    await click(first, /^Your profile$/);
    await waitFor(first, /^Rocket$/, { what: 'the profile on the first device' });
    await sleep(500);
    ({ name, rocket } = await profileShown(first));
    await click(first, /^Done$/);
    await waitFor(first, /^Play solo$/, { what: 'the first device\'s front door' });
    if (name === 'Bao' && rocket === 'true') break;
    await sleep(1000);
  }
  if (name !== 'Bao') throw new Error(`the first device's name is ${JSON.stringify(name)}, not the account's (rocket ${rocket})`);
  if (rocket !== 'true') throw new Error(`the first device's icon is not the account's rocket (selected: ${rocket})`);
  // Nothing the first device did since put the old profile back: the
  // second, at its own next start, still has its own change.
  await second.reload();
  await waitFor(second, /^Play live/, { what: 'live play open on the second device again', timeout: 40000 });
  await click(second, /^Your profile$/);
  await waitFor(second, /^Rocket$/, { what: 'the profile on the second device again' });
  await sleep(500);
  const still = (await profileShown(second)).name;
  if (still !== 'Bao') throw new Error(`the second device's name became ${JSON.stringify(still)}`);
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
  if (newest) log(`the build is older than ${newest.split('\n').join(', ')} — ./e2e/build.sh first`);
}

async function main() {
  await checkFresh();
  const failed = await runFlows({
    flows,
    // A worker's rig: its own server and handlers, its own browser, and
    // a port of its own for a relay, which the pages are told from the
    // start. The relay itself is a flow's, as its devices are (pool.mjs,
    // flowRelay): a flow whose app talks to one says so, `await
    // relay()`, and has one; a flow that does not has none, whatever ran
    // before it on the worker.
    setUp: async ({ tag, say }) => {
      const relayPort = await freePort();
      // A tenth of a table's beats (app/lib/net/address.dart): the same
      // hands, without the minute a bot's thinking takes over each.
      const app = await serveApp({ relayPort, pace: 0.1 });
      const browser = await chromium.launch();
      return { app, browser, relay: flowRelay({ port: relayPort, tag, say }) };
    },
    runFlow: async ({ run, still = false }, { app, browser, relay: { relay, done } }) => {
      // A flow's devices are that flow's: they go when it does. Left open
      // they stay online — announcing themselves, folding their hearts,
      // holding sockets — and the next flow runs against a relay with a
      // crowd on it and a machine with nothing left to give.
      const contexts = [];
      const open = async ({ viewport = portrait, pointer = false, url = null, ready = /^Open Hearts$|^Play solo$/, languages = null } = {}) => {
        const ctx = await browser.newContext({
          viewport,
          locale: 'en-US',
          hasTouch: true,
          isMobile: true,
          // A phone's two pixels to the point where the table moves; one
          // where it holds still, which is a quarter of the drawing.
          deviceScaleFactor: still ? 1 : 2,
          reducedMotion: still ? 'reduce' : 'no-preference',
          // The record flow reads what Copy record put there.
          permissions: ['clipboard-read', 'clipboard-write'],
        });
        contexts.push(ctx);
        await agreedToTerms(ctx);
        // The browser's languages as it says them, before anything of the
        // page's runs, for a flow about a language a context's locale
        // cannot be set to.
        if (languages) {
          await ctx.addInitScript((list) => {
            Object.defineProperty(navigator, 'languages', { get: () => list, configurable: true });
            Object.defineProperty(navigator, 'language', { get: () => list[0], configurable: true });
          }, languages);
        }
        const page = await ctx.newPage();
        page.on('pageerror', AsyncResource.bind((e) => log(`page error: ${e.message}\n${(e.stack || '').slice(0, 900)}`)));
        await page.goto(app.at(url ?? '/?e2e=1'));
        // For a flow that presses with the pointer, the nodes are read for
        // their labels and their geometry and take no clicks, so every
        // press goes through the app's own hit test. The rest keep them:
        // typing into a field goes through the node's own input.
        if (pointer) {
          await page.addStyleTag({ content: 'flt-semantics, flt-semantics * { pointer-events: none !important; }' });
        }
        await waitFor(page, ready, { what: 'the app', timeout: 60000 });
        // At the front door, licensed: every flow here plays on the rig's
        // open house (drive.mjs, licensed).
        if (url === null || /^\/\?/.test(url)) await licensed(page);
        return page;
      };
      try {
        await run({ open, app, relay });
      } finally {
        for (const ctx of contexts) await ctx.close();
        await done();
      }
    },
    tearDown: async ({ app, browser }) => {
      await browser.close();
      app.stop();
    },
  });
  log(failed ? `FAIL: ${failed} flow${failed === 1 ? '' : 's'}` : 'PASS');
  process.exit(failed ? 1 : 0);
}

main();
