// The App Store's and Google Play's pictures of the app: screenshots at
// each size the stores ask for, in each of the app's languages, into
// app/build/store/<size>/<language>/, and Google Play's feature graphic
// and icon.
// What the listings say is site/store.json; docs/how-to/update-the-store-listings.md
// says where each picture goes.
//
//   ./e2e/build.sh
//   node e2e/store_shots.mjs                          # every picture
//   node e2e/store_shots.mjs --size ipad-13 --lang de --only won
//   node e2e/store_shots.mjs --only graphics          # Google Play's feature graphic and icon
//
// Each screenshot is a moment the app is driven to as the browser suites
// drive it (drive.mjs), through its accessibility tree, in the
// language's own words (its ARB), and taken once the screen has stopped
// moving, or for the confetti of a game won, at a set moment of its
// fall. The deals are fixed (?e2e&seed=) and the player plays them by
// a few plain rules (`careful`), so every language and size gets the
// same game. The bots in them are the ones from books and legends: the
// deals were picked so that no real person's name, nor a character from
// a film of our time, is on a store's page.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { languages } from '../site/build.mjs';
import { chromium } from './browser.mjs';
import { agreedToTerms, argOf, labelOf, root, roomIn, serveApp, sleep, startRelay, still, texts, waitFor } from './drive.mjs';

const outDir = join(root, 'app', 'build', 'store');

/// The sizes the stores take (App Store Connect's "Screenshot
/// specifications", Play Console's "Add preview assets"), each as the
/// screen it is in points and the pixels to a point.
const sizes = [
  // iPhone with Dynamic Island, large: 1320 × 2868.
  { name: 'iphone-6.9', width: 440, height: 956, scale: 3 },
  // iPhone with Dynamic Island, medium, which App Store Connect requires: 1206 × 2622.
  { name: 'iphone-6.3', width: 402, height: 874, scale: 3 },
  // iPad, 13 inches, required of an app that runs on iPad: 2752 × 2064,
  // on its side, where the table has room for what has gone beside it.
  { name: 'ipad-13', width: 1376, height: 1032, scale: 2 },
  // A phone on Google Play: 9:16 at 1080 × 1920, what its promotion asks for.
  { name: 'android-phone', width: 360, height: 640, scale: 3 },
];

/// Google Play's feature graphic, in pixels.
const feature = { width: 1024, height: 500 };

// ---- the app's words -----------------------------------------------------

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/// An ICU message as a pattern: each select or plural any of its
/// branches, each placeholder anything.
function pattern(msg) {
  let i = 0;
  function body(stop) {
    let re = '';
    while (i < msg.length && !(stop && msg[i] === '}')) {
      if (msg[i] !== '{') {
        re += esc(msg[i++]);
        continue;
      }
      i++;
      const close = msg.indexOf('}', i);
      const comma = msg.indexOf(',', i);
      if (comma === -1 || comma > close) {
        i = close + 1;
        re += '(.+?)';
        continue;
      }
      i = msg.indexOf(',', comma + 1) + 1;
      const branches = [];
      for (;;) {
        while (msg[i] === ' ') i++;
        if (msg[i] === '}') {
          i++;
          break;
        }
        i = msg.indexOf('{', i) + 1;
        branches.push(body(true));
        i++;
      }
      re += `(?:${branches.join('|')})`;
    }
    return re;
  }
  return new RegExp(`^${body(false)}$`);
}

/// [msg] with its selects chosen and its placeholders filled from [args].
function fill(msg, args) {
  let out = '';
  let i = 0;
  while (i < msg.length) {
    if (msg[i] !== '{') {
      out += msg[i++];
      continue;
    }
    const close = msg.indexOf('}', i);
    const comma = msg.indexOf(',', i);
    if (comma === -1 || comma > close) {
      out += args[msg.slice(i + 1, close).trim()];
      i = close + 1;
      continue;
    }
    const name = msg.slice(i + 1, comma).trim();
    let j = msg.indexOf(',', comma + 1) + 1;
    let chosen = null;
    let other = null;
    for (;;) {
      while (msg[j] === ' ') j++;
      if (msg[j] === '}') {
        j++;
        break;
      }
      const open = msg.indexOf('{', j);
      const key = msg.slice(j, open).trim();
      let depth = 1;
      let k = open + 1;
      for (; depth; k++) depth += msg[k] === '{' ? 1 : msg[k] === '}' ? -1 : 0;
      if (key === args[name]) chosen = msg.slice(open + 1, k - 1);
      if (key === 'other') other = msg.slice(open + 1, k - 1);
      j = k;
    }
    out += fill(chosen ?? other, args);
    i = j;
  }
  return out;
}

const ranks = ['2', '3', '4', '5', '6', '7', '8', '9', '10', 'jack', 'queen', 'king', 'ace'];
const suits = ['clubs', 'diamonds', 'spades', 'hearts'];

/// A language's words, as the app says them (app/lib/l10n), and every
/// card's name in it, to its rank and suit: as a hand's card is named
/// (cardName), and as a line about the table names it, which in German
/// is another word ("den Kreuz-Buben"; l10n.dart, cardInSentence).
function wordsOf(code) {
  const arb = JSON.parse(readFileSync(join(root, 'app', 'lib', 'l10n', `app_${code}.arb`), 'utf8'));
  const cards = new Map();
  const inSentence = new Map();
  for (const suit of suits) {
    for (const [r, rank] of ranks.entries()) {
      cards.set(fill(arb.cardName, { rank, suit, number: rank }), { rank: r + 2, suit });
      inSentence.set(fill(arb.cardWithArticle, { rank, suit, number: rank }), { rank: r + 2, suit });
    }
  }
  return { arb, cards, inSentence, led: pattern(arb.seatLed), played: pattern(arb.seatPlayed), choose: pattern(arb.choosePass) };
}

// ---- playing -------------------------------------------------------------

/// Every semantics node, with what a player goes by.
const nodesOf = (page) =>
  page.evaluate(`[...document.querySelectorAll('flt-semantics')].map((e, i) => ({
    i,
    label: (${labelOf})(e),
    role: e.getAttribute('role'),
    disabled: e.getAttribute('aria-disabled') === 'true',
    // A card chosen for the pass is a button marked current.
    selected: e.getAttribute('aria-selected') === 'true' || e.getAttribute('aria-current') === 'true',
  }))`);
const press = (page, i) => page.evaluate((i) => document.querySelectorAll('flt-semantics')[i].click(), i);

/// Presses the first node labelled [label], if there is one.
async function pressLabel(page, label) {
  const node = (await nodesOf(page)).find((n) => n.label === label && !n.disabled);
  if (node) await press(page, node.i);
  return Boolean(node);
}

/// What is on the table: each card a seat has played to the trick, and
/// whether it led. A lead is looked for first: in German it is a play
/// with a word after it ("spielte … aus").
function trickOf(words, labels) {
  const trick = [];
  for (const label of labels) {
    const led = words.led.exec(label);
    const line = led ?? words.played.exec(label);
    const card = line && words.inSentence.get(line.at(-1));
    if (card) trick.push({ ...card, led: Boolean(led) });
  }
  return trick;
}

/// Presses node [n] and waits until the screen shows the press took, as
/// [took] reads it. A press that lands as the screen is being redrawn
/// can be lost, and a move made again later, on another trick, is
/// another game.
async function pressAndSee(page, n, took) {
  await press(page, n.i);
  for (const until = Date.now() + 3000; Date.now() < until; ) {
    await sleep(60);
    if (took(await nodesOf(page))) return true;
  }
  return false;
}

/// One move by a few plain rules, if the table waits on this player:
/// pass the queen of spades and the high spades and hearts; lead low;
/// follow under the card winning the trick, or high when last to a
/// trick with nothing in it; with none of the suit led, shed the queen,
/// then hearts, then the highest card. Each move is made on a screen
/// read twice alike, never on one still changing, and seen to take
/// before the next; and none on a screen [unless] holds of, the moment
/// a picture is waiting for. Returns whether it moved.
async function careful(page, words, { unless = () => false } = {}) {
  // Read for what a move is made by: the hand, the cards on the table and
  // what the table asks. A live table changes the rest by the second (a
  // turn's clock, and in a driven build its account of the connection,
  // live_page.dart), which on a busy machine no two readings agree on.
  const key = (ns) =>
    ns
      .filter((n) => (n.role === 'button' && words.cards.has(n.label)) || [words.led, words.played, words.choose].some((p) => p.test(n.label)) || n.label === words.arb.yourTurn || n.label === words.arb.passButton)
      .map((n) => `${n.label} ${n.disabled} ${n.selected}`)
      .join('\n');
  const first = await nodesOf(page);
  await sleep(100);
  const nodes = await nodesOf(page);
  if (key(first) !== key(nodes)) return false;
  const labels = nodes.map((n) => n.label);
  if (unless(labels)) return false;
  const hand = nodes.filter((n) => n.role === 'button' && words.cards.has(n.label)).map((n) => ({ ...n, ...words.cards.get(n.label) }));
  const queen = (c) => c.suit === 'spades' && c.rank === 12;
  // Cards of a rank are told apart by suit, in one order whatever the
  // language: a hand is not laid out the same in every one, and a move
  // that went by where a card is drawn would be another game.
  const order = (a, b) => a.rank - b.rank || suits.indexOf(a.suit) - suits.indexOf(b.suit);
  const low = (cards) => cards.reduce((a, b) => (order(b, a) < 0 ? b : a));
  const high = (cards) => cards.reduce((a, b) => (order(b, a) > 0 ? b : a));
  if (labels.includes(words.arb.passButton)) {
    const asked = labels.map((t) => words.choose.exec(t)).find(Boolean);
    if (!asked) return pressLabel(page, words.arb.passButton);
    const danger = (c) => (c.suit === 'spades' && c.rank >= 12 ? 100 + c.rank : c.suit === 'hearts' ? 50 + c.rank : c.rank);
    const [pick] = hand.filter((c) => !c.selected && !c.disabled).sort((a, b) => danger(b) - danger(a) || order(b, a));
    return Boolean(pick) && pressAndSee(page, pick, (ns) => ns.some((n) => n.label === pick.label && n.role === 'button' && n.selected));
  }
  if (!labels.includes(words.arb.yourTurn)) return false;
  const legal = hand.filter((c) => !c.disabled);
  if (!legal.length) return false;
  const trick = trickOf(words, labels);
  const lead = trick.find((c) => c.led);
  let pick;
  if (!lead) {
    const plain = legal.filter((c) => c.suit === 'clubs' || c.suit === 'diamonds');
    const spades = legal.filter((c) => c.suit === 'spades' && c.rank < 12);
    pick = low(plain.length ? plain : spades.length ? spades : legal);
  } else {
    const follow = legal.filter((c) => c.suit === lead.suit);
    if (follow.length) {
      const winning = high(trick.filter((c) => c.suit === lead.suit));
      const under = follow.filter((c) => c.rank < winning.rank);
      const points = trick.some((c) => c.suit === 'hearts' || queen(c));
      const safe = follow.filter((c) => !queen(c));
      if (under.length) pick = high(under);
      else if (trick.length === 3 && !points) pick = high(safe.length ? safe : follow);
      else pick = low(follow);
    } else {
      const hearts = legal.filter((c) => c.suit === 'hearts');
      pick = legal.find(queen) ?? (hearts.length ? high(hearts) : high(legal));
    }
  }
  // Played: the card has left the hand.
  return pressAndSee(page, pick, (ns) => !ns.some((n) => n.label === pick.label && n.role === 'button'));
}

/// Plays on [page] until [done] holds of its labels, pressing on past
/// each hand's sheet; [also] is given the labels first, to do a thing
/// of its own.
async function playUntil(page, words, done, { timeout = 240000, also = null } = {}) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    const labels = await texts(page);
    if (done(labels)) return labels;
    if (also && (await also(labels))) continue;
    if (labels.includes(words.arb.nextHand)) await pressLabel(page, words.arb.nextHand);
    // Never past the moment: it waits on this player's move, so it stays
    // until the next look, which takes it.
    else await careful(page, words, { unless: done });
    await sleep(150);
  }
  throw new Error(`the moment never came\nsaw: ${(await texts(page)).join(' | ')}`);
}

const cardsOnTable = (words, labels) => trickOf(words, labels).length;
const handSize = (words, labels) => labels.filter((t) => words.cards.has(t)).length;

// ---- the moments ---------------------------------------------------------

/// The deals, picked for what each shows.
const deals = { play: 46, pass: 36, won: 3 };

/// How far into its fall the won game's confetti is pictured, in
/// milliseconds from the frame its sheet came in.
const confettiAt = 1200;

/// Each screenshot: its name, in the order a store shows them, and how
/// the app is brought to it on [page] in a context of [size]'s.
const shots = [
  {
    name: 'play',
    // A trick under way, this seat last to it, a few tricks into the hand.
    async take({ open, words }) {
      const page = await open(`seed=${deals.play}`);
      await pressLabel(page, words.arb.playSolo);
      await playUntil(page, words, (l) => l.includes(words.arb.yourTurn) && cardsOnTable(words, l) === 3 && handSize(words, l) <= 10);
      return still(page, 'the trick');
    },
  },
  {
    name: 'live',
    // Four people at a table of their own, from a room's link.
    async take({ live }) {
      return live();
    },
  },
  {
    name: 'learn',
    // The hand that teaches, at its note on a trick taken.
    async take({ open, words }) {
      const page = await open('', { fresh: true });
      await waitFor(page, new RegExp(`^${esc(words.arb.learnToPlayOffer)}$`), { what: 'the offer', timeout: 60000 });
      await pressLabel(page, words.arb.learnToPlayOffer);
      const note = new RegExp(`^${esc(words.arb.tutorialTrickTaken.split(/[.:]/)[0])}`);
      await playUntil(page, words, (l) => l.some((t) => note.test(t)), {
        // Every other note is read and let go.
        also: async (l) => l.includes(words.arb.tutorialNext) && pressLabel(page, words.arb.tutorialNext),
      });
      return still(page, 'the note');
    },
  },
  {
    name: 'won',
    // A game won, its sheet in confetti.
    async take({ open, words }) {
      const page = await open(`seed=${deals.won}&pace=0.1`, { clock: true });
      await pressLabel(page, words.arb.playSolo);
      // The confetti falls for under three seconds from the frame the
      // sheet comes in (ui/confetti.dart, confettiFalls), too quick to be
      // caught by looking: a busy machine sees the sheet late and takes a
      // second over a picture. So at each hand's last card the page's
      // clock is held, the card played, and the page moved on a frame at
      // a time until a sheet comes in. At the game's, a fixed time on
      // into the shower, which is seeded, so the picture is the same in
      // every language and size. The hands are played with motion
      // reduced, as every picture is, and move only from the last card:
      // on a busy machine Playwright's clock falls behind by however late
      // each of the page's timers runs, so a table always moving would
      // play its game many times slower.
      const last = (l) => l.includes(words.arb.yourTurn) && handSize(words, l) === 1;
      for (;;) {
        await playUntil(page, words, last, { timeout: 480000 });
        // The table waits on this player, so the half second the clock
        // jumps to be held moves nothing.
        await page.clock.pauseAt(await page.evaluate(() => Date.now() + 500));
        await page.emulateMedia({ reducedMotion: 'no-preference' });
        const [card] = (await nodesOf(page)).filter((n) => n.role === 'button' && words.cards.has(n.label));
        await press(page, card.i);
        let labels = [];
        for (let frames = 0; !labels.includes(words.arb.newGame) && !labels.includes(words.arb.nextHand); frames++) {
          if (frames > 1000) throw new Error(`no sheet after the last card\nsaw: ${labels.join(' | ')}`);
          await page.clock.runFor(16);
          labels = await texts(page);
        }
        if (labels.includes(words.arb.newGame)) {
          if (!labels.includes(words.arb.youWin)) throw new Error(`deal ${deals.won} is not won\nsaw: ${labels.join(' | ')}`);
          await page.clock.runFor(confettiAt);
          return page.screenshot();
        }
        await page.emulateMedia({ reducedMotion: 'reduce' });
        await page.clock.resume();
      }
    },
  },
  {
    name: 'pass',
    // Three cards chosen for the pass, and the button to send them.
    async take({ open, words }) {
      const page = await open(`seed=${deals.pass}`);
      await pressLabel(page, words.arb.playSolo);
      const chosen = new RegExp(`^${esc(words.arb.passButton)}$`);
      await playUntil(page, words, (l) => !l.some((t) => words.choose.test(t)) && l.some((t) => chosen.test(t)), {
        // Choosing only: the pass itself is not pressed.
        also: async (l) => l.some((t) => words.choose.test(t)) && careful(page, words),
      });
      return still(page, 'the pass');
    },
  },
];

// ---- the feature graphic -------------------------------------------------

/// Google Play's feature graphic in [code]: the site's share image
/// (site/public/og.png) at the store's shape, in the language's words
/// from the site (site/strings).
function featureHtml(code) {
  const site = JSON.parse(readFileSync(join(root, 'site', 'strings', `${code}.json`), 'utf8')).home;
  const lead = site.description.split('.')[0];
  // Not "Free": Google Play asks that a feature graphic say nothing of
  // price (Play Console Help, "Add preview assets"), which its page shows.
  const points = [site.alone.noAds, site.more.open.title].join(' · ');
  return `<!doctype html><html lang="${code}"><meta charset="utf-8"><style>
    html, body { margin: 0; width: ${feature.width}px; height: ${feature.height}px; }
    body {
      background: radial-gradient(120% 110% at 50% 0%, #14513C 0%, #0E3B2E 45%, #06231A 100%);
      font-family: 'DejaVu Sans', 'Helvetica Neue', Arial, sans-serif;
      display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center;
    }
    .suits { font-size: 46px; letter-spacing: 34px; margin-left: 34px; line-height: 1; }
    .suits .light { color: #8FA89C; } .suits .red { color: #C2392F; }
    h1 { font-size: 112px; font-weight: 800; margin: 20px 0 6px; letter-spacing: -1px; line-height: 1; }
    h1 .open { color: #E9F0EC; } h1 .hearts { color: #F0766B; }
    p { margin: 0; }
    .lead { color: #9FB6AA; font-size: 30px; }
    .points { color: #E4B363; font-size: 25px; font-weight: 700; letter-spacing: 3px; text-transform: uppercase; margin-top: 26px; }
  </style><body>
    <div class="suits"><span class="light">♣</span><span class="red">♦</span><span class="light">♠</span><span class="red">♥</span></div>
    <h1><span class="open">Open</span> <span class="hearts">Hearts</span></h1>
    <p class="lead">${lead}.</p>
    <p class="points">${points}</p>
  </body></html>`;
}

// ---- checks --------------------------------------------------------------

/// A PNG's width, height and colour type, from its header.
function pngHeader(bytes) {
  if (bytes.readUInt32BE(12) !== 0x49484452) throw new Error('not a PNG');
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), depth: bytes[24], colour: bytes[25] };
}

/// [bytes], once its header says it is [width] × [height] and 8-bit RGB
/// (colour type 2): the stores take screenshots and the feature graphic
/// with no alpha channel. Google Play's icon is the one picture asked
/// for with one ([alpha], colour type 6), and at most a megabyte.
function checked(bytes, width, height, what, { alpha = false } = {}) {
  const h = pngHeader(bytes);
  const colour = alpha ? 6 : 2;
  if (h.width !== width || h.height !== height) throw new Error(`${what}: ${h.width} × ${h.height}, not ${width} × ${height}`);
  if (h.colour !== colour || h.depth !== 8) throw new Error(`${what}: colour type ${h.colour}, depth ${h.depth}, not 8-bit ${alpha ? 'RGBA' : 'RGB'}`);
  if (alpha && bytes.length > 1024 * 1024) throw new Error(`${what}: ${bytes.length} bytes, over a megabyte`);
  return bytes;
}

// ---- running -------------------------------------------------------------

const only = argOf('only');
const chosenSizes = sizes.filter((s) => !argOf('size') || s.name === argOf('size'));
const chosenLanguages = languages.filter((l) => !argOf('lang') || l.code === argOf('lang'));
const chosenShots = shots.filter((s) => !only || s.name === only);

const relay = await startRelay();
// The longest grace the operator may set before a turn's clock shows
// (packages/table, timing.dart): a clock counting down by the second
// never lets the live table's screen come to rest, and is no part of
// the picture.
const app = await serveApp({ relayPort: relay.port, config: { table: { graceMs: 60000 } } });
const browser = await chromium.launch();
try {
  for (const size of chosenShots.length ? chosenSizes : []) {
    for (const language of chosenLanguages) {
      const words = wordsOf(language.code);
      const dir = join(outDir, size.name, language.code);
      mkdirSync(dir, { recursive: true });
      const contexts = [];
      /// A device of [size]'s, in [language], at the front door with [query].
      // The player looks the same in every picture: a device's own colour
      // is drawn from its key, which is new each time.
      const open = async (query, { fresh = false, clock = false, lang = language.code, name = null, avatar = { icon: 'sailing', color: 2 }, pictured = true } = {}) => {
        const ctx = await browser.newContext({
          // A device not in the picture is drawn small, to spare the machine.
          viewport: pictured ? { width: size.width, height: size.height } : { width: 390, height: 844 },
          deviceScaleFactor: pictured ? size.scale : 1,
          isMobile: true,
          hasTouch: true,
          locale: languages.find((l) => l.code === lang).lang,
          // Held still, so that a screen comes to rest.
          reducedMotion: 'reduce',
        });
        contexts.push(ctx);
        // A clock a shot can hold (Playwright's), which runs as any clock
        // does until it is held.
        if (clock) await ctx.clock.install();
        await agreedToTerms(ctx);
        // A device that has played alone is not offered the hand that
        // teaches: only the one picture of it is.
        if (!fresh) await ctx.addInitScript(() => localStorage.setItem('flutter.tutorial_opened', 'true'));
        if (name) await ctx.addInitScript((n) => localStorage.setItem('flutter.identity_name', JSON.stringify(n)), name);
        if (avatar) await ctx.addInitScript((a) => localStorage.setItem('flutter.identity_avatar', JSON.stringify(JSON.stringify(a))), avatar);
        const page = await ctx.newPage();
        await page.goto(app.at(`/?e2e=1&lang=${lang}&roomWait=45${query ? `&${query}` : ''}`));
        await waitFor(page, new RegExp(`^${esc(wordsOf(lang).arb.playSolo)}$`), { what: 'the front door', timeout: 60000 });
        return page;
      };
      /// Four at a table from a room's link: this language's device, and
      /// three others, each named and with an avatar of their own.
      const live = async () => {
        const people = [
          ['Ada', { icon: 'sailing', color: 2 }],
          ['Bao', { icon: 'coffee', color: 5 }],
          ['Cara', { icon: 'flower', color: 7 }],
          ['Dee', { icon: 'bike', color: 0 }],
        ];
        const pages = [];
        for (const [i, [name, avatar]] of people.entries()) {
          pages.push(await open('', { name, avatar, lang: i === 0 ? language.code : 'en', pictured: i === 0 }));
        }
        await pressLabel(pages[0], words.arb.playFriends);
        await waitFor(pages[0], new RegExp(`^${esc(words.arb.shareTheLink)}$`), { what: 'the room', timeout: 60000 });
        const code = roomIn(pages[0].url());
        for (const page of pages.slice(1)) await page.goto(app.at(`/room/${code}?e2e=1&lang=en&roomWait=45`));
        const english = wordsOf('en');
        // A live deal is the table's own, never the same twice: this
        // device's turn, with two cards before it and most of its hand
        // still in it, at the first trick that has them.
        const ready = (labels) =>
          labels.includes(words.arb.yourTurn) && cardsOnTable(words, labels) >= 2 && handSize(words, labels) >= 8;
        const until = Date.now() + 600000;
        while (Date.now() < until) {
          if (ready(await texts(pages[0]))) return still(pages[0], 'the live table');
          await careful(pages[0], words, { unless: ready });
          for (const page of pages.slice(1)) await careful(page, english);
          await sleep(200);
        }
        throw new Error(`no live trick\nsaw: ${(await texts(pages[0])).join(' | ')}`);
      };
      for (const [n, shot] of shots.entries()) {
        if (!chosenShots.includes(shot)) continue;
        const what = `${size.name} ${language.code} ${shot.name}`;
        try {
          const bytes = await shot.take({ open, live, words });
          const file = join(dir, `${n + 1}-${shot.name}.png`);
          writeFileSync(file, checked(bytes, size.width * size.scale, size.height * size.scale, what));
          console.log(`${what} → ${file}`);
        } finally {
          for (const ctx of contexts.splice(0)) await ctx.close();
        }
      }
    }
  }
  // Google Play's graphics, which are no size of screen: with every
  // picture, or asked for alone.
  if (only === 'graphics' || (!only && !argOf('size'))) {
    for (const language of chosenLanguages) {
      const ctx = await browser.newContext({ viewport: feature, deviceScaleFactor: 1 });
      const page = await ctx.newPage();
      await page.setContent(featureHtml(language.code));
      const dir = join(outDir, 'feature-graphic');
      mkdirSync(dir, { recursive: true });
      const file = join(dir, `${language.code}.png`);
      writeFileSync(file, checked(await page.screenshot(), feature.width, feature.height, `feature graphic ${language.code}`));
      console.log(`feature graphic ${language.code} → ${file}`);
      await ctx.close();
    }
    // Its icon, 512 pixels square with an alpha channel: the App Store's
    // own, the whole square, which Google Play rounds itself. Drawn on a
    // canvas, whose PNG keeps the channel; a screenshot of an opaque page
    // leaves it out.
    const icon = readFileSync(join(root, 'app', 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset', 'Icon-App-1024x1024@1x.png'));
    const page = await browser.newPage();
    const png = await page.evaluate(async (src) => {
      const image = new Image();
      image.src = src;
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 512;
      const g = canvas.getContext('2d');
      g.imageSmoothingQuality = 'high';
      g.drawImage(image, 0, 0, 512, 512);
      return canvas.toDataURL('image/png');
    }, `data:image/png;base64,${icon.toString('base64')}`);
    const file = join(outDir, 'google-play-icon.png');
    writeFileSync(file, checked(Buffer.from(png.split(',')[1], 'base64'), 512, 512, 'Google Play icon', { alpha: true }));
    console.log(`Google Play icon → ${file}`);
    await page.close();
  }
} finally {
  await browser.close();
  app.stop();
  await relay.stop();
}
