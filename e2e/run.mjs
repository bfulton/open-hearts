// Four real browsers at one table.
//
//   cd app && flutter build web -o build/e2e --base-href / --no-web-resources-cdn
//   node e2e/run.mjs            # from the repo root; needs the global Playwright
//
// The app's relays are the build's, never typed in (app/lib/net/
// relays.dart); served from localhost it looks for the local relay at
// its usual port, which is where the suite starts one.
//
// Starts the local relay and a static server for the built app, opens
// four headless Chromium contexts — four devices, four keys — and
// drives them through the app's accessibility tree: host a table, join
// it, play a hand over real WebRTC, then the departure cells that only
// a real browser can show: one closed mid-hand, one stalled on its
// turn and booted, one that leaves. Exit code is the verdict.

import { chromium } from './browser.mjs';
import {
  act,
  click,
  dismiss,
  has,
  labelOf,
  log,
  playUntil,
  serveApp,
  sleep,
  startRelay,
  texts,
  type,
  waitFor,
} from './drive.mjs';

// ---- the scenarios -------------------------------------------------------

const names = ['Ada', 'Bao', 'Cara', 'Dee'];
/// A seat badge that is not one of the four people: a bot took a seat.
const roster = /^(?!Ada:|Bao:|Cara:|Dee:)[A-Z][\w ]+: \d+ in the game, \d+ this hand/;

async function main() {
  const relay = await startRelay();
  const app = await serveApp();
  log(`relay ${relay.url}, app ${app.url}`);
  const browser = await chromium.launch();
  const contexts = [];
  const pages = [];
  let failed = false;
  try {
    for (let i = 0; i < 4; i++) {
      const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'en-US' });
      const page = await ctx.newPage();
      page.on('pageerror', (e) => log(`page ${names[i]} error: ${e.message}\n${(e.stack || '').slice(0, 600)}`));
      page.on('console', (m) => {
        const t = m.text();
        // Errors, and the table's and the duty's own traces about the jury.
        const verbose = /$^/;
        if (m.type() === 'error' || verbose.test(t) || /^duty: (?!.*emit )/.test(t) || /^table: .*(jury|juror|verdict|appeal|nobody online|summon)/.test(t)) log(`page ${names[i]}: ${t}`);
      });
      await page.goto(`${app.url}/?e2e=1`);
      contexts.push(ctx);
      pages.push(page);
    }
    // Everyone names themselves on the front door, which is the whole
    // of the lobby now.
    for (const [i, page] of pages.entries()) {
      await waitFor(page, /^Play friends$/, { what: 'the home screen' });
      await type(page, 'Your name', names[i]);
    }
    // Every device is online from the front door, and each one sees
    // the other three: presence over the relay, before anyone sits
    // down, counted on the button itself.
    for (const page of pages) await waitFor(page, /^Play live, 4 online$/, { what: 'everyone online', timeout: 40000 });
    log('four online at the front door');

    // Cell 0: matchmaking. Three ask for an unrated game — the options
    // are rated until someone says otherwise, so they say so — and are
    // seated together with a bot at the round after ten seconds; the
    // fourth presses as it stands and, alone in the rated pool, gets
    // three bots.
    for (const page of pages.slice(0, 3)) {
      await click(page, /^Game options$/);
      await waitFor(page, /^Unrated$/, { what: 'the options sheet' });
      await click(page, /^Unrated$/);
      await click(page, /^Done$/);
      await waitFor(page, /^50 points · unrated$/, { what: 'an unrated game asked for' });
      await click(page, /^Play live/);
    }
    await click(pages[3], /^Play live/);
    for (const page of pages) await waitFor(page, /^Finding players$/);
    for (const page of pages.slice(0, 3)) await waitFor(page, /^3 of 3 here  ·  unrated$/, { what: 'the unrated table', timeout: 40000 });
    await waitFor(pages[3], /^1 of 1 here  ·  rated$/, { what: 'the rated table', timeout: 40000 });
    log('matched: three together, one with bots');
    await playUntil(pages, (p) => has(p, /^On with it$/), { timeout: 180000 });
    log('a matched hand played on every screen');
    // Back to the front door for the rest: leave by the menu. The score
    // sheet goes on its own after a few seconds, so it may be gone by
    // the time a page is reached.
    for (const page of pages) {
      await dismiss(page, /^On with it$/);
      await click(page, /^Menu$/);
      await waitFor(page, /^Leave the table$/, { what: 'the menu' });
      await click(page, /^Leave the table$/);
      await waitFor(page, /^Play friends$/, { what: 'the home screen again' });
    }

    // Ada picks an avatar first: the picker opens from her icon by the
    // name, an icon is chosen, and Done keeps it.
    await click(pages[0], /^Your avatar$/);
    await waitFor(pages[0], /^Rocket$/, { what: 'the avatar picker' });
    await click(pages[0], /^Rocket$/);
    await click(pages[0], /^Done$/);
    await waitFor(pages[0], /^Play friends$/);
    // Ada goes in with no code, so a new one is drawn: the room names
    // itself by it. Nobody hosts; whoever is at a code is the table.
    await click(pages[0], /^Play friends$/);
    await waitFor(pages[0], /^Share the link$/, { what: 'the room' });
    const code = (await texts(pages[0])).map((t) => /^Table ([A-Z0-9]{4})$/.exec(t)?.[1]).find(Boolean);
    if (!code) throw new Error('no room code shown');
    log(`room ${code}`);
    // Nobody types a code: the others arrive by the shared link — the
    // app's own address with the code — and, with a name already, land
    // straight in the room.
    for (let i = 1; i < 4; i++) {
      await pages[i].goto(`${app.url}/?e2e=1&room=${code}`);
      await waitFor(pages[i], new RegExp(`^Table ${code}$`), { what: 'the room, by its link', timeout: 60000 });
    }
    // Four in: whoever leads starts on its own.
    for (const page of pages) await waitFor(page, /^4 of 4 here  ·  unrated$/, { what: 'the live table', timeout: 40000 });
    log('all four at the table');

    // Cell 1: a whole hand over WebRTC.
    await playUntil(pages, (p) => has(p, /^On with it$/), { timeout: 180000 });
    log('hand 1 played on every screen');
    // The sheet goes on its own after a few seconds, and the screens
    // reach the end of a hand a few seconds apart, so one may be gone
    // by the time all four have shown it.
    for (const page of pages) {
      await dismiss(page, /^On with it$/);
    }
    for (const page of pages) await waitFor(page, /^Hand 2/, { what: 'hand 2' });

    // Cell 2: Dee's browser goes, mid-hand. The others see three, and a
    // bot in her seat once her turn comes and the silence is answered —
    // two minutes of it.
    await contexts[3].close();
    log('Dee closed her browser');
    const others = pages.slice(0, 3);
    await playUntil(others, (p) => has(p, /^3 of 4 here/), { timeout: 150000 });
    await playUntil(others, async (p) => (await texts(p)).some((t) => roster.test(t)), { timeout: 150000 });
    log('a bot took Dee\'s seat');

    // Cell 3: Cara stops acting. On her turn the clock runs; at fifteen
    // seconds the others get the Boot button, and one press does it.
    await playUntil(others, (p, i) => i === 2 || has(p, /^Boot Cara$/), { timeout: 120000, idle: [2] });
    await click(pages[0], /^Boot Cara$/);
    log('Ada pressed Boot');
    await playUntil([pages[0], pages[1]], (p) => has(p, /^2 of 4 here/), { timeout: 60000 });
    await waitFor(pages[2], /^A bot took your seat$/, { what: "Cara's replacement notice", timeout: 30000 });
    log('Cara booted, and told');

    // Cell 5: two people left, and Bao's browser goes off his turn. Ada
    // alone is no majority of two and claims nothing; her next play
    // waits on a vote that will never come, and the table asks the
    // jury — the service's juror of last resort, called for when this
    // table found nobody else online. It rules once Bao has been
    // silent two minutes: Ada's play stands, and at Bao's own turn his
    // seat goes to a bot. Ada finishes the hand with three bots.
    await contexts[1].close();
    log("Bao's browser closed off his turn");
    await playUntil([pages[0]], (p) => has(p, /^Asking the jury$/), { timeout: 150000 });
    log('Ada is asking the jury');
    await playUntil([pages[0]], (p) => has(p, /^1 of 4 here/), { timeout: 300000 });
    log('the jury ruled; Ada alone with three bots');
    // The hand ends when the header moves on to the next one — a sheet
    // that comes and goes is not the thing to wait for — or the game
    // ends, which a game to fifty can do here.
    const before = (await texts(pages[0])).find((t) => /^Hand \d/.test(t));
    const next = `Hand ${Number(before.match(/^Hand (\d+)/)[1]) + 1}`;
    await playUntil([pages[0]], async (p) => (await has(p, new RegExp(`^${next} `))) || (await has(p, /^Home$/)), { timeout: 180000 });
    log(`Ada finished the hand that began as "${before}"`);

    log('PASS');
  } catch (e) {
    failed = true;
    log('FAIL', e.message);
  } finally {
    await browser.close();
    app.stop();
    relay.stop();
  }
  process.exit(failed ? 1 : 0);
}

main();
