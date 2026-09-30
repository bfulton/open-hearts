// Four real browsers at one table.
//
//   ./e2e/build.sh
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

/// The app, driven, with the room told to wait for all four.
///
/// A room starts ten seconds after the last arrival, which is right
/// for people and wrong for this: four whole apps opening on one
/// machine can take longer than that between them, and the room then
/// starts short while the last of them is still loading. Four in a
/// room is a table at once whatever the wait, so a longer one costs
/// nothing here and takes the machine's speed out of the question
/// (app/lib/net/address.dart).
const driven = 'e2e=1&roomWait=45';
/// A seat badge that is not one of the four people: a bot took a seat.
const roster = /^(?!Ada:|Bao:|Cara:|Dee:)[A-Z][\w ]+: \d+ in the game, \d+ this hand/;

/// Whether hand [n] is over on a page: its score sheet is up, or the
/// sheet has been and gone and the header is on the next hand. Not the
/// sheet alone: it goes by itself after six seconds, and one pass over
/// four pages can take longer than that — on a hosted runner's two
/// cores, up to half a minute — so a page whose sheet came and went
/// between two looks would never count, though its hand was over.
const handOver = (n) => {
  const next = new RegExp(`^Hand ${n + 1} `);
  return async (p) => (await texts(p)).some((t) => t === 'On with it' || next.test(t));
};

/// How long a whole hand may take. Four browsers, a relay and a bench
/// of jurors on a hosted runner's two cores took 172 and 173 s over the
/// first cell's on two runs, and runners differ: one ran the table's
/// suite 1.7 times slower than another (ci.yml), which makes that
/// hand nearly five minutes.
const aHand = 480000;

async function main() {
  const relay = await startRelay();
  const app = await serveApp();
  log(`relay ${relay.url}, app ${app.url}`);
  const browser = await chromium.launch();
  const contexts = [];
  const pages = [];
  // What each device has lately said to itself. A run that passes
  // wants the narrow filter below and nothing more; a run that stalls
  // is unreadable without the table's own account of why, and by then
  // it is too late to turn logging on. So it is kept, trimmed and
  // bounded, and printed for whoever is still stuck when something
  // times out.
  const traces = [];
  // How long each device's page was held at a time while it played:
  // every task of 50 ms or more on its thread, by the browser's own
  // count, from the front door on — loading the app is one long task
  // and says nothing about the table. A frame is 16; a tap waits out
  // whatever task is running when it lands.
  const held = [];
  let playing = false;
  let failed = false;
  try {
    for (let i = 0; i < 4; i++) {
      const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'en-US' });
      const tasks = [];
      held.push(tasks);
      await ctx.exposeBinding('ohLongTask', (_, ms) => playing && tasks.push(ms));
      await ctx.addInitScript(() => {
        try {
          new PerformanceObserver((list) => {
            for (const e of list.getEntries()) window.ohLongTask(Math.round(e.duration));
          }).observe({ type: 'longtask', buffered: true });
        } catch (_) {}
      });
      const page = await ctx.newPage();
      page.on('pageerror', (e) => log(`page ${names[i]} error: ${e.message}\n${(e.stack || '').slice(0, 600)}`));
      // A device's table and its jury duty are two clients in one tab
      // and they are kept apart, because a duty following somebody
      // else's table says a line a trick and would push the table's
      // own account of why it stopped out of a shared list.
      const said = { table: { first: [], last: [] }, duty: { first: [], last: [] } };
      traces.push(said);
      page.on('console', (m) => {
        const t = m.text();
        const which = t.startsWith('table: ') ? 'table' : t.startsWith('duty: ') ? 'duty' : null;
        if (which && !/ emit (serve|heartbeat) /.test(t)) {
          // Not the heartbeats. A client that has stopped says
          // nothing else, so a ring that keeps them keeps five
          // hundred copies of "still here" and throws away the last
          // thing it did — which is the only line that matters.
          //
          // Without the bodies either: a deal step carries kilobytes
          // of proof, and none of it says why a table stopped.
          const line = t.length > 240 ? `${t.slice(0, 240)}…` : t;
          // Both ends, not the last of it. A client that never moved
          // is explained by its opening — the jury it heard, the deal
          // it built — and a ring that keeps only the end throws that
          // away and leaves a thousand identical lines saying it is
          // still asking. So the first of what a client said is kept
          // whole and the rest rolls.
          const said_ = said[which];
          if (said_.first.length < 250) said_.first.push(line);
          else {
            said_.last.push(line);
            if (said_.last.length > 500) said_.last.splice(0, said_.last.length - 500);
          }
        }
        // Errors, the table's and the duty's own traces about the
        // jury, and the mesh: who this device dials and whether the
        // channel came up, which is how a table that has fallen back
        // to the relay lane shows itself.
        const verbose = /$^/;
        if (m.type() === 'error' || verbose.test(t) || /^mesh: /.test(t) || /^duty: (?!.*emit )/.test(t) || /^table: .*(jury|juror|verdict|appeal|nobody online|summon)/.test(t)) log(`page ${names[i]}: ${t}`);
      });
      await page.goto(`${app.url}/?${driven}`);
      contexts.push(ctx);
      pages.push(page);
    }
    // Everyone names themselves in their profile, behind the icon in
    // the corner of the front door: the name and the avatar are one
    // sheet, and the door carries neither.
    for (const [i, page] of pages.entries()) {
      await waitFor(page, /^Play friends$/, { what: 'the home screen' });
      await click(page, /^Your profile$/);
      await waitFor(page, /^Rocket$/, { what: 'the profile' });
      await type(page, 'Your name', names[i]);
      await click(page, /^Done$/);
      await waitFor(page, /^Play friends$/, { what: 'the home screen again' });
    }
    // Every device is online from the front door, and each one sees
    // the other three: presence over the relay, before anyone sits
    // down, counted on the button itself.
    for (const page of pages) await waitFor(page, /^Play live, 4 online$/, { what: 'everyone online', timeout: 40000 });
    log('four online at the front door');
    playing = true;

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
    await playUntil(pages, handOver(1), { timeout: aHand });
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

    // Ada picks an avatar first: her profile opens from the icon in the
    // corner, an icon is chosen, and Done keeps it.
    await click(pages[0], /^Your profile$/);
    await waitFor(pages[0], /^Rocket$/, { what: 'the profile' });
    await click(pages[0], /^Rocket$/);
    await click(pages[0], /^Done$/);
    await waitFor(pages[0], /^Play friends$/);
    // Ada goes in with no code, so a new one is drawn. Nobody hosts;
    // whoever is at a code is the table. The code is on no screen —
    // the room's link is in the address bar, which is where a person
    // copies it from and where this reads it.
    await click(pages[0], /^Play friends$/);
    await waitFor(pages[0], /^Share the link$/, { what: 'the room' });
    const code = new URL(pages[0].url()).searchParams.get('room');
    if (!/^[A-Z0-9]{8}$/.test(code ?? '')) throw new Error(`no room in the address: ${pages[0].url()}`);
    log(`room ${code}`);
    // Nobody types a code: the others arrive by the shared link — the
    // app's own address with the code — and, with a name already, land
    // straight in the room.
    //
    // One after another, as three people sent a link actually do.
    // Not all at once: a room has no host, so four devices arriving on
    // the same second can each be sure of a different three of
    // themselves, two of them lead, and the room comes apart into two
    // tables under one code — which the table id is there to keep
    // apart (docs/04-live-play.md) but which is not a table of four.
    //
    // They have as long as they need to get there: the room is waiting
    // for a fourth rather than counting down (`driven`, above). By the
    // time the last is looked at that fourth arrival may already have
    // started the table, so either screen is arriving.
    for (let i = 1; i < 4; i++) {
      await pages[i].goto(`${app.url}/?${driven}&room=${code}`);
      await waitFor(pages[i], /^Share the link$|^\d of 4 here/, { what: `the room, by its link (${names[i]})`, timeout: 60000 });
    }
    // Four in a room is a table at once, whoever leads.
    for (const page of pages) await waitFor(page, /^4 of 4 here  ·  unrated$/, { what: 'the live table', timeout: 40000 });
    log('all four at the table');

    // Cell 1: a whole hand over WebRTC.
    await playUntil(pages, handOver(1), { timeout: aHand });
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
    // Her turn can be most of a trick away, and on two cores the whole
    // of it took 69 s.
    await playUntil(others, (p, i) => i === 2 || has(p, /^Boot Cara$/), { timeout: 180000, idle: [2] });
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
    // The ruling is Bao's badge going to a bot, and nothing sooner. Not
    // "1 of 4 here", which counts who is connected and says so the
    // moment his browser closes, two minutes before the jury rules. All
    // four badges on the screen and none of them his, so a moment with
    // no badges drawn is not taken for one without Bao.
    await playUntil([pages[0]], async (p) => {
      const badges = (await texts(p)).filter((t) => /^[A-Z][\w ]*: \d+ in the game/.test(t));
      return badges.length === 4 && !badges.some((t) => t.startsWith('Bao: '));
    }, { timeout: 300000 });
    log('the jury ruled; Ada alone with three bots');
    // The hand ends when the header moves on to the next one — a sheet
    // that comes and goes is not the thing to wait for — or the game
    // ends, which a game to fifty can do here.
    const before = (await texts(pages[0])).find((t) => /^Hand \d/.test(t));
    const next = `Hand ${Number(before.match(/^Hand (\d+)/)[1]) + 1}`;
    await playUntil([pages[0]], async (p) => (await has(p, new RegExp(`^${next} `))) || (await has(p, /^Home$/)), { timeout: aHand });
    log(`Ada finished the hand that began as "${before}"`);

    log('PASS');
  } catch (e) {
    failed = true;
    log('FAIL', e.message);
    // And what the devices that are still there were saying as it
    // stopped. The one that timed out is the one to read, but a table
    // stalls in pairs — somebody is waiting on somebody — so they all
    // go in.
    for (const [i, page] of pages.entries()) {
      if (page.isClosed()) continue;
      for (const which of ['table', 'duty']) {
        const keep = traces[i]?.[which] ?? { first: [], last: [] };
        if (!keep.first.length) continue;
        const whose = `${names[i]}'s ${which === 'table' ? 'own table' : 'jury duty'}`;
        log(`--- the first of ${whose} ---`);
        for (const l of keep.first) log(`    ${l}`);
        if (keep.last.length) {
          log(`--- the last of ${whose} ---`);
          for (const l of keep.last.slice(-70)) log(`    ${l}`);
        }
      }
    }
  } finally {
    for (const [i, tasks] of held.entries()) {
      const total = tasks.reduce((a, b) => a + b, 0);
      const worst = tasks.length ? Math.max(...tasks) : 0;
      const over = (ms) => tasks.filter((t) => t >= ms).length;
      log(`${names[i]}'s page, playing, held 50 ms or more ${tasks.length} times, ${(total / 1000).toFixed(1)} s in all; ` +
        `200 ms or more ${over(200)} times, 500 or more ${over(500)}; the longest ${worst} ms`);
    }
    await browser.close();
    app.stop();
    relay.stop();
  }
  process.exit(failed ? 1 : 0);
}

main();
