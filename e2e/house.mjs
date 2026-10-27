// The house: taken off the air mid-hand and back, and a person's seat
// opened from its escrow when they go.
//
//   ./e2e/build.sh
//   node e2e/house.mjs          # from the repo root; needs the global Playwright
//
// The cells no simulator can stand in for: a real browser, the relay the
// Cloudflare object runs, and the house as a process of its own that can
// be stopped (drive.mjs, startRelay).
//
// 1. One person and three bots, and the house stopped once the person
//    is first asked for a card. Nobody else can play a bot seat's cards.
//    The relay wants the house back and the rig starts it again, as the
//    deployed object starts its container; it reads the log from the
//    start, makes the bot seats' secrets again from its own, and goes on
//    within the table's grace (packages/table, timing.dart,
//    houseGraceMs). The hand finishes.
// 2. Two people and two bots, and one of them leaving mid-hand. Their
//    seat is opened from the escrow — the house's piece and the other
//    person's, both said in the log (docs/explanation/fair-deal.md) —
//    and played out by every side. The hand finishes, and is not given
//    up.

import { chromium } from './browser.mjs';
import { act, agreedToTerms, click, has, licensed, log, playUntil, serveApp, sleep, startRelay, texts, type, waitFor } from './drive.mjs';

const driven = 'e2e=1';

/// Whether hand [n] is over on [page]: the header on the next one, or
/// the game's end.
const past = (n) => async (page) => (await has(page, new RegExp(`^Hand ${n + 1} `))) || (await has(page, /^Home$/));

/// The hand the header shows, counted from one.
async function handOn(page) {
  const header = (await texts(page)).find((t) => /^Hand \d+ /.test(t));
  return header ? Number(header.match(/^Hand (\d+) /)[1]) : null;
}

async function main() {
  const relay = await startRelay({ pace: 0.1 });
  // A tenth of a table's beats (app/lib/net/address.dart). The table's
  // clocks are the standard's: the house is waited for as long as it is
  // in production, which is what the first cell times.
  const app = await serveApp({ relayPort: relay.port, pace: 0.1 });
  log(`relay ${relay.url}, app ${app.url}`);
  const browser = await chromium.launch();
  let failed = false;
  /// A device of its own, named [name], at the front door: every line
  /// its table writes kept in [said] (lobby.dart, trace).
  const device = async (name) => {
    // Spared motion, as in run.mjs: the table's own account is what is
    // looked at.
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'en-US', reducedMotion: 'reduce' });
    await agreedToTerms(ctx);
    const page = await ctx.newPage();
    const said = [];
    page.on('pageerror', (e) => log(`${name}: page error: ${e.message}\n${(e.stack || '').slice(0, 600)}`));
    page.on('console', (m) => {
      const t = m.text();
      if (t.startsWith('table: ')) said.push(t);
      if (m.type() === 'error' || /^table: (seat \d+ \w+ at #|hand \d+ given up|the house let)/.test(t)) log(`${name}: ${t}`);
    });
    await page.goto(app.at(`/?${driven}`));
    await licensed(page);
    await waitFor(page, /^Play friends$/, { what: `${name}'s home screen` });
    await click(page, /^Your profile$/);
    await waitFor(page, /^Rocket$/, { what: 'the profile' });
    await type(page, 'Your name', name);
    await click(page, /^Done$/);
    await waitFor(page, /^Play friends$/, { what: `${name}'s home screen again` });
    return { ctx, page, said };
  };
  try {
    // Cell 1: the house off the air mid-hand, and back.
    const ada = await device('Ada');
    // Alone in the pool, so the round after ten seconds seats her with
    // three bots. The options are rated until somebody says otherwise,
    // and nobody does.
    await click(ada.page, /^Play live/);
    await waitFor(ada.page, /^1 of 1 here  ·  rated$/, { what: 'Ada alone with three bots', timeout: 60000 });
    // Played up to her first card: the deal done, the passes in, a
    // card or more of the bots' on the felt.
    const until = Date.now() + 240000;
    while (Date.now() < until && !(await has(ada.page, /^Your (turn|lead)$/))) {
      await act(ada.page);
      await sleep(300);
    }
    if (!(await has(ada.page, /^Your (turn|lead)$/))) throw new Error(`Ada was never asked for a card: ${(await texts(ada.page)).join(' | ')}`);
    const woken = () => relay.house.said.filter((l) => / woken$/.test(l)).length;
    const before = woken();
    await relay.house.stop();
    log('the house taken off the air, Ada asked for a card');
    // Her card, and the bots after it are the house's to play: the
    // relay sees the house gone from the log and wants it, and it is
    // started and woken again.
    await playUntil([ada.page], async () => woken() > before, { timeout: 120000 });
    log('the house started and woken again');
    await playUntil([ada.page], async (p) => {
      if (await has(p, /^Connection failure$/)) throw new Error(`the game ended with the house away:\n${ada.said.slice(-30).join('\n')}`);
      return past(1)(p);
    }, { timeout: 300000 });
    log('the hand finished, the house back from the log');
    await ada.ctx.close();

    // Cell 2: a person leaving mid-hand, their seat opened from the
    // escrow and played out.
    const [bao, cy] = [await device('Bao'), await device('Cy')];
    for (const { page } of [bao, cy]) {
      await click(page, /^Game options$/);
      await waitFor(page, /^Unrated$/, { what: 'the options sheet' });
      await click(page, /^Unrated$/);
      await click(page, /^Done$/);
      await waitFor(page, /^50 points · unrated$/, { what: 'an unrated game asked for' });
      await click(page, /^Play live/);
    }
    for (const { page } of [bao, cy]) await waitFor(page, /^2 of 2 here  ·  unrated$/, { what: 'Bao and Cy at one table', timeout: 60000 });
    log('Bao and Cy at one table with two bots');
    // Into the play: two of Cy's cards on the felt.
    let cards = 0;
    const into = Date.now() + 240000;
    while (Date.now() < into && cards < 2) {
      await act(bao.page);
      if ((await act(cy.page))?.startsWith('played')) cards++;
      await sleep(300);
    }
    if (cards < 2) throw new Error(`Cy played ${cards} cards: ${(await texts(cy.page)).join(' | ')}`);
    const hand = await handOn(cy.page);
    await click(bao.page, /^Menu$/);
    await waitFor(bao.page, /^Leave the table$/, { what: 'the menu' });
    await click(bao.page, /^Leave the table$/);
    await waitFor(bao.page, /^Leave the table\?$/, { what: 'the question' });
    await click(bao.page, /^Leave$/);
    await waitFor(bao.page, /^Play friends$/, { what: 'Bao at the door' });
    log(`Bao left in hand ${hand}`);
    await playUntil([cy.page], past(hand), { timeout: 300000 });
    const left = cy.said.find((l) => /^table: seat \d+ left at #/.test(l));
    if (!left) throw new Error(`Cy's table never said Bao left:\n${cy.said.slice(-30).join('\n')}`);
    const givenUp = cy.said.find((l) => /^table: hand \d+ given up/.test(l));
    if (givenUp) throw new Error(`the hand was given up rather than played out: ${givenUp}`);
    log(`Cy finished hand ${hand}, Bao's seat played out from the escrow (${left.slice('table: '.length)})`);

    log('PASS');
  } catch (e) {
    failed = true;
    log('FAIL', e.message);
    log(`--- the house ---\n${relay.house.said.slice(-40).join('\n')}`);
  } finally {
    await browser.close();
    app.stop();
    await relay.stop();
  }
  process.exit(failed ? 1 : 0);
}

main();
