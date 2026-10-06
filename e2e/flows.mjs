// Every flow one device can drive, in a real browser.
//
//   ./e2e/build.sh
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
import { gzipSync } from 'node:zlib';

import { chromium } from './browser.mjs';
import { act, appDir, argOf, click, dismiss, has, labelOf, log, root, serveApp, sleep, startRelay, texts, type, waitFor, waitGone, roomIn, records } from './drive.mjs';

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
    /^Open source Hearts card game, no ads$/,
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

flow('turning the phone mid-hand', async ({ open }) => {
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

flow('a game alone, and the record it leaves', async ({ open, context }) => {
  const page = await open();
  await click(page, /^Play solo$/);
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
  // A game dealt from 256 bits of the secure generator, which the record
  // names (docs/03-fair-deal.md).
  if (!/^oh2:[0-9a-f]{64}:/.test(record ?? '')) throw new Error(`the record does not look like one: ${JSON.stringify((record ?? '').slice(0, 80))}`);
  // And it is a record the tool can read: every trick, from the seed
  // and the player's own choices.
  const out = execFileSync('dart', ['run', 'tool/replay.dart', record], { cwd: join(root, 'packages', 'engine'), encoding: 'utf8' });
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
  // and the page says which rather than showing the number everyone
  // starts at — once the relays have answered, or the wait for them
  // has ended: this flow starts none, and until then the page says it
  // is still counting.
  if (record0.some((t) => /^1500$/.test(t))) throw new Error('the profile shows the rating nobody earned');
  await waitFor(page, /Play a rated live game|relays did not answer/, {
    what: 'the profile to say why there is no rating',
    timeout: 20000,
  });
});

flow('the about page', async ({ open }) => {
  const page = await open();
  await click(page, /^Play solo$/);
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

flow('the backup codes, shown on request and copied', async ({ open }) => {
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

flow('a page keeps its address: away to another site and back lands on it', async ({ open }) => {
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

flow('every page by its own address: opened, refreshed, and back to the front door', async ({ open, app }) => {
  // A link to a page, a refresh on it, or history landing on it opens
  // that page over the front door (app/lib/router.dart).
  const page = await open({ url: `${app.url}/about?e2e=1`, ready: /^Build$/ });
  await page.reload();
  await waitFor(page, /^Build$/, { what: 'the about page, after a refresh', timeout: 60000 });
  if (new URL(page.url()).searchParams.get('e2e') !== '1') throw new Error(`the session's parameters went: ${page.url()}`);
  await click(page, /^Back$/);
  await waitFor(page, /^Play solo$/, { what: 'the front door, under it' });
  if (new URL(page.url()).pathname !== '/') throw new Error(`the address did not come home: ${page.url()}`);
  // A game is reached only by playing: its address alone is the front door.
  const game = await open({ url: `${app.url}/live?e2e=1` });
  await waitFor(game, /^Play solo$/, { what: 'the front door, for a game\'s address' });
  if (new URL(game.url()).pathname !== '/') throw new Error(`a game's address stayed: ${game.url()}`);
});

flow('a kept game, opened by its address: checked in the browser, then shown hand by hand', async ({ open, app }) => {
  // A real record, as a player's device sends one: a sealed game of four
  // played out on the simulator (packages/table, tool/game_fixture.dart),
  // kept as the site keeps it. The browser fetches it and replays every
  // signature and every step of the deal before showing a card.
  const json = execFileSync('dart', ['run', 'tool/game_fixture.dart'], { cwd: join(root, 'packages', 'table'), maxBuffer: 16 << 20 }).toString().trim();
  const table = JSON.parse(json).spec.id;
  records.kept.set(`tables/${table}.json`, gzipSync(Buffer.from(json)));
  const page = await open({ url: `${app.url}/table/${table}?e2e=1`, ready: /^The game$/ });
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
  // An address that is not a table's goes to the front door.
  const nowhere = await open({ url: `${app.url}/table/not-a-table?e2e=1` });
  if (new URL(nowhere.url()).pathname !== '/') throw new Error(`a bad table address stayed: ${nowhere.url()}`);
});

flow('a game watched as it is played, from the link a player shares', async ({ open, relay }) => {
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

flow('a reload mid-hand comes back to the seat, and the hand plays on', async ({ open, relay }) => {
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

flow('a second device, brought in by the code the first one shows', async ({ open }) => {
  // A subscription is a person's, not a device's (docs/06-service.md).
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

flow('one device at a time: the newest opened wins, and the other takes it back — asked first when it is at a table', async ({ open, relay }) => {
  // An account plays on one device at a time (docs/06-service.md). The
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
  const only = argOf('only');
  await checkFresh();
  const app = await serveApp();
  const browser = await chromium.launch();
  let failed = 0;
  // A flow's devices are that flow's: they go when it does. Left open
  // they stay online — announcing themselves, folding their hearts,
  // holding sockets — and the next flow runs against a relay with a
  // crowd on it and a machine with nothing left to give.
  let contexts = [];
  // Only the lobby needs a relay, and it costs a couple of seconds and
  // two processes, so it is started when something asks for one.
  let relayOnce = null;
  const relay = () => (relayOnce ??= startRelay());
  const open = async ({ viewport = portrait, pointer = false, url = null, ready = /^Open Hearts$|^Play solo$/ } = {}) => {
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
    page.on('pageerror', (e) => log(`page error: ${e.message}\n${(e.stack || '').slice(0, 900)}`));
    await page.goto(url ?? `${app.url}/?e2e=1`);
    // For a flow that presses with the pointer, the nodes are read for
    // their labels and their geometry and take no clicks, so every
    // press goes through the app's own hit test. The rest keep them:
    // typing into a field goes through the node's own input.
    if (pointer) {
      await page.addStyleTag({ content: 'flt-semantics, flt-semantics * { pointer-events: none !important; }' });
    }
    await waitFor(page, ready, { what: 'the app', timeout: 60000 });
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
    for (const ctx of contexts) await ctx.close();
    contexts = [];
  }
  await browser.close();
  app.stop();
  (await relayOnce)?.stop();
  log(failed ? `FAIL: ${failed} flow${failed === 1 ? '' : 's'}` : 'PASS');
  process.exit(failed ? 1 : 0);
}

main();
