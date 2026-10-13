// The app with the network taken away, a piece at a time.
//
//   ./e2e/build.sh
//   node e2e/offline.mjs                    # from the repo root
//   node e2e/offline.mjs --only "airplane"
//   node e2e/offline.mjs --serial          # one after another (default: three workers)
//
// Solo play needs nothing but the device, and everything else needs
// somebody: the relays for a live game and the ratings, the site's
// worker for a licence, the shop and the devices on a subscription.
// Each flow here takes one of those away — the whole network, the
// relays, the worker — or leaves it there and never answering, and
// holds the app to two things. Playing alone still works. And every
// wait ends, within a time this suite writes down, in words on the
// screen rather than in a spinner that turns for ever.
//
// A screenshot of where each flow ended is left in app/build/offline/,
// for looking at what a person would see.
import { AsyncResource } from 'node:async_hooks';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

import { chromium } from './browser.mjs';
import { act, click, freePort, has, labelOf, licensed, log, root, serveApp, sleep, texts, type, waitFor } from './drive.mjs';
import { flowRelay, runFlows } from './pool.mjs';

const phone = { width: 390, height: 844 };
const shots = join(root, 'app', 'build', 'offline');

/// What the door says when a live game cannot be had for want of a
/// relay: the same words whether none answered or the device has no
/// network to ask them on.
const noRelay = /^No relay answered\. Check the connection and try again\.$/;
const noService = /^Could not reach the service\. Try again in a moment\.$/;

/// Waits for [re] and answers how long it took, in seconds: the time to
/// a message is the thing being measured, so it is said as well as
/// held to [seconds].
async function within(page, re, seconds, what) {
  const began = Date.now();
  await waitFor(page, re, { timeout: seconds * 1000, what: `${what} within ${seconds} s` });
  const took = (Date.now() - began) / 1000;
  log(`      ${what}: ${took.toFixed(1)} s`);
  return took;
}

/// Waits for [re] to be on the screen twice over: the same
/// words said of two things — the list, and a code asked for after it.
async function twice(page, re, seconds, what) {
  const began = Date.now();
  const until = began + seconds * 1000;
  while (Date.now() < until) {
    if ((await texts(page)).filter((t) => re.test(t)).length >= 2) {
      log(`      ${what}: ${((Date.now() - began) / 1000).toFixed(1)} s`);
      return;
    }
    await sleep(250);
  }
  throw new Error(`timed out waiting for ${what} within ${seconds} s\nsaw: ${(await texts(page)).join(' | ')}`);
}

/// Holds for [seconds] that [re] never shows: a pill nobody asked for,
/// a spinner's line.
async function never(page, re, seconds, what) {
  const until = Date.now() + seconds * 1000;
  while (Date.now() < until) {
    if (await has(page, re)) throw new Error(`${what}\nsaw: ${(await texts(page)).join(' | ')}`);
    await sleep(250);
  }
}

/// A screenshot of the moment, beside the one each flow ends on.
const look = (page, what) => page.screenshot({ path: join(shots, `${what}.png`) }).catch(() => {});

/// Waits for [re] to leave the screen, and answers how long it took.
async function gone(page, re, seconds, what) {
  const began = Date.now();
  const until = began + seconds * 1000;
  while (Date.now() < until) {
    if (!(await has(page, re))) {
      log(`      ${what}: ${((Date.now() - began) / 1000).toFixed(1)} s`);
      return;
    }
    await sleep(250);
  }
  throw new Error(`timed out waiting for ${what} within ${seconds} s\nsaw: ${(await texts(page)).join(' | ')}`);
}

/// Whether the node labelled [re] can be pressed: a way in that is
/// being opened is disabled, and one that has given up is not.
const pressable = (page, re) =>
  page.evaluate(`((src) => {
    const labelOf = ${labelOf};
    const re = new RegExp(src);
    const e = [...document.querySelectorAll('flt-semantics')].find((e) => re.test(labelOf(e)));
    return !!e && e.getAttribute('aria-disabled') !== 'true';
  })(${JSON.stringify(re.source)})`);

async function name(page) {
  await click(page, /^Your profile$/);
  await waitFor(page, /^Rocket$/, { what: 'the profile' });
  await type(page, 'Your name', 'Ada');
  await click(page, /^Done$/);
  await waitFor(page, /^Play solo$/, { what: 'the door again' });
}

/// Back to the door from a page over it.
async function home(page) {
  for (let i = 0; i < 6 && !(await has(page, /^Play solo$/)); i++) {
    if (await has(page, /^Done$/)) await click(page, /^Done$/);
    else if (await has(page, /^Back$/)) await click(page, /^Back$/);
    await sleep(600);
  }
  await waitFor(page, /^Play solo$/, { what: 'the door' });
}

/// The Subscription page, behind the menu, where a subscriber's devices are.
async function livePlayPage(page) {
  await click(page, /^Menu$/);
  await waitFor(page, /^Subscription$/, { what: 'the menu' });
  await click(page, /^Subscription$/);
  await waitFor(page, /^Your devices$/, { what: 'the Subscription page' });
}

/// A whole hand against the bots, played through the tree.
async function aHand(page, seconds = 180) {
  const began = Date.now();
  await click(page, /^Play solo$/);
  const until = Date.now() + seconds * 1000;
  while (Date.now() < until) {
    if (await has(page, /^Next hand$|^New game$/)) {
      log(`      a whole hand alone: ${((Date.now() - began) / 1000).toFixed(0)} s`);
      return;
    }
    await act(page);
    await sleep(250);
  }
  throw new Error(`the hand alone did not finish\nsaw: ${(await texts(page)).join(' | ')}`);
}

/// Waits for the service worker to have kept the app (app/web/
/// offline_worker.js): the page, the code, and the renderer.
async function kept(page) {
  const until = Date.now() + 30000;
  let files = [];
  while (Date.now() < until) {
    files = await page
      .evaluate(`(async () => (await (await caches.open('open-hearts')).keys()).map((r) => new URL(r.url).pathname))()`)
      .catch(() => []);
    if (['/', '/main.dart.js', '/deal.wasm'].every((f) => files.includes(f)) && files.some((f) => /canvaskit\.wasm$/.test(f))) {
      return files;
    }
    await sleep(250);
  }
  throw new Error(`the app was not kept for a load with no network: ${files.join(', ') || 'nothing'}`);
}

// ---- the flows -----------------------------------------------------------

const flows = [];
const flow = (name, run) => flows.push({ name, run });

flow('opened with no network, once it has been opened with one', async ({ app, context, open }) => {
  // Airplane mode on a train: the app was opened yesterday, and is
  // opened again now, with nothing to load it from but what it kept.
  const first = await open();
  log(`      kept: ${(await kept(first)).length} files`);
  await first.close();
  await context.setOffline(true);
  const page = await context.newPage();
  const began = Date.now();
  await page.goto(app.at('/?e2e=1'));
  await waitFor(page, /^Play solo$/, { timeout: 20000, what: 'the door, from what was kept' });
  log(`      the door, offline from a cold start: ${((Date.now() - began) / 1000).toFixed(1)} s`);
  await aHand(page);
  return page;
});

flow('airplane mode: every way in says what it can do, at once', async ({ context, open, relay }) => {
  await relay();
  const page = await open();
  await name(page);
  await waitFor(page, /^Play live, /, { timeout: 40000, what: 'online, and counted' });
  await context.setOffline(true);
  // How many are online is not known with no network to hear them on.
  await within(page, /^Play live$/, 5, 'the count off the button');
  for (const way of [/^Play live$/, /^Play friends$/]) {
    await click(page, way);
    await within(page, noRelay, 3, `${way.source.slice(1, -1)}: no relay`);
    if (!(await pressable(page, way))) throw new Error(`${way}: still being opened`);
    if (await has(page, /^Finding players$|^Share the link$/)) throw new Error(`${way}: a wait opened anyway`);
  }
  // The rating is the relays' to say; the games played alone are not.
  await click(page, /^Your profile$/);
  await within(page, /^The relays did not answer, so it cannot be shown just now$/, 3, 'the profile, no rating');
  if (!(await has(page, /^Alone$/))) throw new Error('the profile lost the games played alone');
  await home(page);
  // The devices on the subscription are the service's to list.
  await livePlayPage(page);
  await within(page, noService, 3, 'the devices: no service');
  if (await has(page, /^…$/)) throw new Error('the list is still "coming"');
  await click(page, /^Add a device$/);
  await twice(page, noService, 3, 'a code: no service');
  await home(page);
  await aHand(page);
  // And back: the network returns, and so does live play.
  await context.setOffline(false);
  await click(page, /^Menu$/);
  await waitFor(page, /^Leave the table$/, { what: 'the menu' });
  await click(page, /^Leave the table$/);
  await waitFor(page, /^Play solo$/, { what: 'the door' });
  await click(page, /^Play live/);
  await within(page, /^Finding players$/, 45, 'online again: in the pool');
  await click(page, /^Cancel$/);
  return page;
});

flow('the network gone while finding players', async ({ context, open, relay }) => {
  await relay();
  const page = await open();
  await name(page);
  await waitFor(page, /^Play live, /, { timeout: 40000, what: 'online, and counted' });
  await click(page, /^Play live/);
  await waitFor(page, /^Finding players$/, { timeout: 45000, what: 'the pool' });
  await context.setOffline(true);
  // Said under the wait at once, which otherwise looks like a pool with
  // nobody else in it.
  await within(page, noRelay, 3, 'said under the wait');
  if (!(await has(page, /^Finding players$/))) throw new Error('the wait was given up before its deadline');
  await look(page, 'finding-players-offline');
  // Bots take every seat still empty at ten seconds, but even the
  // seating this device hosts itself comes back to it off a relay: with
  // none, the wait must still end.
  await gone(page, /^Finding players$/, 50, 'the pool given up');
  await waitFor(page, noRelay, { timeout: 1000, what: 'why, at the door' });
  if (!(await pressable(page, /^Play live/))) throw new Error('Play live is still being opened');
  return page;
});

flow('the network gone in a room', async ({ context, open, relay }) => {
  await relay();
  const page = await open();
  await name(page);
  await waitFor(page, /^Play live, /, { timeout: 40000, what: 'online, and counted' });
  await click(page, /^Play friends$/);
  await waitFor(page, /^Share the link$/, { timeout: 60000, what: 'the room' });
  await context.setOffline(true);
  // A room waits for the link to be opened, for as long as it takes, so
  // it does not give up; but it says why nobody can arrive, rather than
  // looking like a room everyone else has left.
  await within(page, noRelay, 3, 'said in the room');
  if (!(await has(page, /^Share the link$/))) throw new Error('the room went');
  await look(page, 'a-room-offline');
  await context.setOffline(false);
  await gone(page, noRelay, 5, 'unsaid, with the network back');
  await click(page, /^Leave$/);
  await waitFor(page, /^Play solo$/, { what: 'the door' });
  return page;
});

flow('the relays there and silent', async ({ context, open }) => {
  // Every socket opens and nothing ever comes back: a relay that has
  // hung, or a network that lets the handshake through and no more.
  await context.routeWebSocket(/.*/, () => {});
  const page = await open();
  await name(page);
  await click(page, /^Your profile$/);
  await within(page, /^Counting up your games…$/, 3, 'the profile, asking');
  await within(page, /^The relays did not answer, so it cannot be shown just now$/, 15, 'the profile, no answer');
  await home(page);
  await click(page, /^Play live/);
  await within(page, /^Still looking for a relay…$/, 12, 'Play live: said to be slow');
  await within(page, noRelay, 40, 'Play live: given up');
  if (!(await pressable(page, /^Play live/))) throw new Error('Play live is still being opened');
  // Playing alone never asked them anything.
  await aHand(page);
  return page;
});

// What the shop says depends on how it failed: a worker that answered
// at all answered that the shop is shut, which is what a deployment
// with no keys says (docs/explanation/service.md); one that did not was out of
// reach.
const shopShut = /^The shop is not open yet\.$/;
const shopGone = /^Could not reach the shop\. Try again in a moment\.$/;
for (const [how, answer, shop] of [
  ['refused', (route) => route.abort('connectionrefused'), shopGone],
  ['answering 503', (route) => route.fulfill({ status: 503, body: 'down' }), shopShut],
  ['never answering', () => {}, shopGone],
]) {
  flow(`the site's worker ${how}`, async ({ app, context, open }) => {
    const fast = how !== 'never answering';
    // Licensed while the worker was there, as a subscriber is.
    const first = await open();
    await waitFor(first, /^Play live/, { timeout: 40000, what: 'a licence from the worker' });
    await first.close();
    await context.route('**/api/**', answer);
    const page = await open();
    await waitFor(page, /^Play live/, { what: 'live play still open on the licence the device holds' });
    await livePlayPage(page);
    await within(page, noService, fast ? 3 : 13, 'the devices');
    await click(page, /^Add a device$/);
    await twice(page, noService, fast ? 3 : 13, 'a code');
    // Somebody arriving with a code another device showed.
    const arriving = await context.newPage();
    await arriving.goto(app.at('/?e2e=1&claim=0a1b2c3d'));
    // Asked before anything is spent: a link is anybody's to send.
    await waitFor(arriving, /^Join this subscription\?$/, { timeout: 60000, what: 'the question before a code is spent' });
    await click(arriving, /^Join$/);
    await within(arriving, noService, fast ? 20 : 30, 'a code arrived with');
    // And a device with no licence, at the shop.
    const stranger = await open({ fresh: true, route: ['**/api/**', answer] });
    await click(stranger, /^Subscribe$/);
    await waitFor(stranger, /^By subscribing, you agree to the Terms of use\.$/, { what: 'the shop' });
    await sleep(600); // the door's own Subscribe, still in the tree while the page slides over it
    await click(stranger, /^Subscribe$/);
    await within(stranger, shop, fast ? 3 : 15, 'the shop');
    return page;
  });
}

flow('the update check, with nothing to say', async ({ context, open }) => {
  // A deployed build asks for build-info.json and shows a pill when a
  // newer one is up. One that cannot ask says nothing, and nothing turns.
  await context.route('**/build-info.json*', (route) => route.fulfill({ status: 200, body: '{"build":"abc1234","date":"2026-10-01"}' }));
  const newer = await open({ query: 'e2e=1&updatecheck' });
  await within(newer, /^New build available$/, 10, 'the pill, when a newer build is up');
  for (const [how, answer] of [['offline', (route) => route.abort('internetdisconnected')], ['never answering', () => {}]]) {
    const page = await open({ fresh: true, query: 'e2e=1&updatecheck', route: ['**/build-info.json*', answer] });
    await never(page, /^New build available$/, 5, `${how}: a pill all the same`);
    log(`      ${how}: no pill, nothing waiting`);
  }
  return newer;
});

flow('the network gone at a live table', async ({ context, open, relay }) => {
  await relay();
  const page = await open();
  await name(page);
  await waitFor(page, /^Play live, /, { timeout: 40000, what: 'online, and counted' });
  await click(page, /^Play live/);
  await waitFor(page, /^Choose 3 more to pass$|^Your (turn|lead)$/, { timeout: 120000, what: 'a hand dealt' });
  for (let i = 0; i < 8; i++) {
    await act(page);
    await sleep(400);
  }
  await context.setOffline(true);
  // The jurors holding the bot seats cannot be heard, the table pauses
  // for them and says so, and with none to be had it ends, unscored.
  const began = Date.now();
  const until = began + 90000;
  while (Date.now() < until && !(await has(page, /^Connection failure$/))) {
    await act(page);
    await sleep(500);
  }
  await waitFor(page, /^Connection failure$/, { timeout: 1000, what: 'the table to end' });
  log(`      the table ended, and said why: ${((Date.now() - began) / 1000).toFixed(0)} s`);
  await click(page, /^Home$/);
  await waitFor(page, /^Play solo$/, { what: 'the door' });
  return page;
});

// ---- the runner ----------------------------------------------------------

async function main() {
  mkdirSync(shots, { recursive: true });
  const failed = await runFlows({
    flows,
    // A worker's rig, as in flows.mjs: its own server and browser, and
    // a port for the relay of each flow that asks for one.
    setUp: async ({ tag, say }) => {
      const relayPort = await freePort();
      // A tenth of a table's beats (app/lib/net/address.dart), and the
      // operator's word that a table stopped for jurors it cannot hear
      // ends sooner (docs/explanation/service.md; the least each may be,
      // packages/table, timing.dart). The device's own waits — on the
      // relays, the service, the shop — are the build's, which is what
      // this suite times.
      const app = await serveApp({ relayPort, tag, pace: 0.1, config: { table: { jurorSilenceMs: 10000, quorumLostMs: 10000 } } });
      const browser = await chromium.launch();
      return { app, browser, relay: flowRelay({ port: relayPort, tag, say }) };
    },
    runFlow: async ({ name: title, run }, { app, browser, relay: { relay, done } }) => {
      // A flow's devices are that flow's, as in flows.mjs; and each is a
      // device of its own — its own keys, its own kept copy of the app.
      const contexts = [];
      const newContext = async () => {
        // Spared motion, as in run.mjs, at one pixel to the point: what is
        // looked at here is the words a wait ends in, and flows.mjs plays
        // with the motion on a phone's two.
        const ctx = await browser.newContext({ viewport: phone, locale: 'en-US', hasTouch: true, isMobile: true, deviceScaleFactor: 1, reducedMotion: 'reduce' });
        contexts.push(ctx);
        return ctx;
      };
      const context = await newContext();
      const open = async ({ fresh = false, query = 'e2e=1', route = null } = {}) => {
        const ctx = fresh ? await newContext() : context;
        if (route) await ctx.route(...route);
        const page = await ctx.newPage();
        page.on('pageerror', AsyncResource.bind((e) => log(`page error: ${e.message}`)));
        await page.goto(app.at(`/?${query}`));
        await waitFor(page, /^Play solo$/, { what: 'the app', timeout: 60000 });
        // Licensed, where the service is there to license it (drive.mjs,
        // licensed); a flow that takes the service away asks for none.
        if (!route) await licensed(page);
        return page;
      };
      const file = join(shots, `${title.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').toLowerCase()}.png`);
      try {
        const page = await run({ app, context, open, relay });
        await page?.screenshot({ path: file }).catch(() => {});
      } catch (e) {
        const last = contexts.flatMap((c) => c.pages()).at(-1);
        await last?.screenshot({ path: file }).catch(() => {});
        throw e;
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
  log(`screenshots in ${shots}`);
  process.exit(failed ? 1 : 0);
}

main();
