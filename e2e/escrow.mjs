// One browser, three bot seats, and the juror holding one of them
// taken off the air.
//
//   ./e2e/build.sh
//   node e2e/escrow.mjs         # from the repo root; needs the global Playwright
//
// The cell the sealed escrow was built for, and the one no simulator
// can stand in for: a real browser, a real relay, real jurors in their
// own processes, and a bot seat whose secret nobody at the table has.
// A juror holds each bot seat and plays it; when that juror goes, the
// jurors that are left release their pieces to each other, rebuild the
// seat between them, and play it out. The person at the table cannot
// read any of it — a bot seat's release is sealed to the custodians —
// so what she sees is the seat going and the hand finishing.
//
// One browser, because the jury has to be known: a jury is drawn from
// whoever is online, and one seated person is not eligible for her own
// table, so the jury is exactly the bench of jurors of last resort
// (drive.mjs starts them one to a process). Which of them holds which
// seat is drawn, and the deal says so.

import { chromium } from './browser.mjs';
import { act, click, has, log, serveApp, sleep, startRelay, texts, type, waitFor } from './drive.mjs';

const driven = 'e2e=1';

/// Waits for a line matching `what` to turn up in `lines` — an array
/// some process or page is writing to as the suite watches, or a
/// function answering with one — and answers with the line. The page
/// is played on meanwhile: a table waiting for a person to move says
/// nothing at all.
async function traced(lines, what, { what: name, page, timeout = 120000 } = {}) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    const line = (typeof lines === 'function' ? lines() : lines).find((l) => what.test(l));
    if (line) return line;
    if (page && !page.isClosed()) await act(page);
    await sleep(300);
  }
  throw new Error(`timed out waiting for ${name ?? what}${page ? `\nsaw: ${(await texts(page)).join(' | ')}` : ''}`);
}

async function main() {
  const relay = await startRelay();
  const app = await serveApp();
  log(`relay ${relay.url}, app ${app.url}`);
  const browser = await chromium.launch();
  let failed = false;
  try {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'en-US' });
    const page = await ctx.newPage();
    // Every line the table writes, kept whether or not it is logged:
    // this suite reads what the browser saw, which is more than is
    // worth printing as it goes by.
    const said = [];
    page.on('pageerror', (e) => log(`page error: ${e.message}\n${(e.stack || '').slice(0, 600)}`));
    page.on('console', (m) => {
      const t = m.text();
      if (t.startsWith('table: ')) said.push(t);
      if (m.type() === 'error' || /^table: .*(jury|juror|escrow|piece|verdict)/.test(t)) log(`page: ${t}`);
    });
    await page.goto(`${app.url}/?${driven}`);
    await waitFor(page, /^Play friends$/, { what: 'the home screen' });
    await click(page, /^Your profile$/);
    await waitFor(page, /^Rocket$/, { what: 'the profile' });
    await type(page, 'Your name', 'Ada');
    await click(page, /^Done$/);
    await waitFor(page, /^Play friends$/, { what: 'the home screen again' });

    // Alone in the pool, so the round after ten seconds seats her with
    // three bots. The options are rated until somebody says otherwise,
    // and nobody does.
    await click(page, /^Play live/);
    await waitFor(page, /^Finding players$/);
    await waitFor(page, /^1 of 1 here  ·  rated$/, { what: 'Ada alone with three bots', timeout: 60000 });
    log('Ada alone with three bots');

    // Which juror holds which bot seat, as the deal fixed it. Said by
    // every side, so her own device is where to read it.
    const held = await traced(said, /the jury holds bot (seat .*)$/, { what: 'the bot seats held', page, timeout: 180000 });
    const seats = [...held.matchAll(/seat (\d+) \((\w{8})\)/g)].map((m) => ({ seat: Number(m[1]), key: m[2] }));
    if (seats.length !== 3) throw new Error(`three bot seats held by the jury, not ${seats.length}: ${held}`);
    log(held.slice(held.indexOf('the jury holds')));

    // Once the hand is dealt, not before: a holder that goes while a
    // deal turn of its seat is still open takes the whole hand with
    // it, which is a different cell (packages/table,
    // test/undealt_hand_test.dart).
    await traced(said, /dealt hand \d+/, { what: 'the hand dealt', page, timeout: 180000 });
    const bench = await Promise.all(relay.bench.map(async (j) => ({ ...j, key: await j.key })));
    const gone = seats.find((s) => bench.some((j) => j.key === s.key));
    if (!gone) throw new Error(`no juror of the bench holds a seat: ${held} against ${bench.map((j) => j.key)}`);
    bench.find((j) => j.key === gone.key).kill();
    log(`the juror holding seat ${gone.seat} (${gone.key}) was taken off the air`);

    // She judges it quiet and gives the seat to the escrow; the jurors
    // that are left do the rest between themselves.
    await traced(said, new RegExp(`bot seat ${gone.seat}: its juror .* has gone quiet; to the escrow`),
        { what: 'the seat given to the escrow', page, timeout: 180000 });
    log(`seat ${gone.seat} went to the escrow`);
    const standing = bench.filter((j) => j.key !== gone.key);
    const since = () => standing.flatMap((j) => j.said);
    await traced(since, /emit release/, { what: 'a piece of the escrow released', page, timeout: 180000 });
    await traced(since, new RegExp(`seat ${gone.seat}'s hand is open, from .* piece and another`),
        { what: 'the seat rebuilt from two pieces', page, timeout: 180000 });
    log(`seat ${gone.seat} was rebuilt from two pieces of the escrow`);

    // And the hand it was holding is played to its end on it.
    const was = (await texts(page)).find((t) => /^Hand \d/.test(t));
    const after = `Hand ${Number(was.match(/^Hand (\d+)/)[1]) + 1}`;
    const until = Date.now() + 300000;
    while (Date.now() < until) {
      await act(page);
      if ((await has(page, new RegExp(`^${after} `))) || (await has(page, /^Home$/))) break;
      await sleep(300);
    }
    if (!(await has(page, new RegExp(`^${after} `))) && !(await has(page, /^Home$/))) {
      throw new Error(`the hand did not finish: ${(await texts(page)).join(' | ')}`);
    }
    log(`Ada finished "${was}" with a seat nobody at the table could see`);

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
