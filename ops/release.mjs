// `oh deploy …` and `oh verify`: the relay worker and the site put into
// production, relay first, and production checked afterwards
// (docs/how-to/deploy.md). Publishing a change to the terms is a deploy
// of the site too (docs/how-to/change-the-terms.md). What has to hold before anything reaches
// production is in gate.mjs, which deploy.sh and the relay's build step
// run themselves, so that deploying without oh is held to it too.

import { rm } from 'node:fs/promises';
import { join } from 'node:path';

import { Failed, Usage, relayHost, relayWrangler, root, wranglerVersion } from './env.mjs';
import { releaseProblems } from './gate.mjs';
import { MODULE_ALIAS, MODULE_DIR, fetchModule, pinsOf } from './photodna.mjs';
import { termsProblems, untold } from './terms.mjs';
import { told, versionOf } from '../site/ledger.mjs';
import { stripe as stripeDefinition } from '../infra/stripe.mjs';
import { checkoutFields } from '../service/functions/stripe.mjs';

/// The programs a relay deploy builds with: its custom build
/// (service/bench/build.sh) compiles the juror and the native libraries,
/// and Wrangler builds the backup jurors' image with Docker.
const RELAY_NEEDS = [
  ['docker', ['info'], 'Docker, running (start dockerd)'],
  ['dart', ['--version'], 'Dart (the Flutter SDK’s bin on PATH)'],
  ['cargo', ['--version'], 'Cargo (Rust)'],
];

async function missing(ctx, needs) {
  const gone = [];
  for (const [command, args, what] of needs) {
    if ((await ctx.capture(command, args)).code !== 0) gone.push(what);
  }
  return gone;
}

/// Says what stands in the way of a production release; Failed when
/// something does and [apply] is set.
async function cleared(ctx, target, apply) {
  const problems = await releaseProblems(ctx, target);
  for (const p of problems) ctx.log(`  not ready: ${p}`);
  if (problems.length && apply) throw new Failed(`${target}: not deployed (${problems.length} problem(s) above)`);
  return problems.length === 0;
}

export async function relay(ctx, { flags }) {
  if (flags.preview) return previewRelay(ctx, { flags });
  const version = await wranglerVersion();
  ctx.log(`the relay worker (service/do) from ${await head(ctx)}, with wrangler ${version}`);
  const gone = await missing(ctx, RELAY_NEEDS);
  for (const g of gone) ctx.log(`  not ready: needs ${g}`);
  const ready = (await cleared(ctx, 'relay', flags.apply)) && !gone.length;
  const pinned = pinsOf(await ctx.config());
  ctx.log(pinned ? `  with the PhotoDNA module config/openhearts.json pins, from the private bucket (${Object.keys(pinned).length} files)` : '  without a PhotoDNA module: config/openhearts.json pins none, so the relay asks PhotoDNA nothing');
  if (!flags.apply) {
    ctx.log(ready ? 'nothing deployed; --apply deploys it' : 'nothing deployed');
    return;
  }
  if (gone.length) throw new Failed(`relay: needs ${gone.join(', ')}`);
  // Fetched now, into the folder git ignores, built in the stand-in's
  // place (service/do/photodna_off.mjs), and on this computer only
  // while it is built.
  const dir = ctx.moduleDir ?? MODULE_DIR;
  await rm(dir, { recursive: true, force: true });
  let code;
  try {
    const withModule = (await fetchModule(ctx, dir)) !== null;
    code = await ctx.run('npx', ['--yes', `wrangler@${version}`, 'deploy', ...(withModule ? ['--alias', MODULE_ALIAS] : [])], { cwd: join(root, 'service/do') });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
  if (code !== 0) throw new Failed(`relay: wrangler deploy exited ${code}`);
}

/// The preview relay (wrangler.toml, [env.preview]), from whatever is
/// checked out, as a preview of the site is: it reaches nothing of
/// production's, and checks no picture, so it is built without the
/// PhotoDNA module. Its devices are held to the key previews have, which
/// config/openhearts.json names (preview.serviceKey).
async function previewRelay(ctx, { flags }) {
  const version = await wranglerVersion();
  const name = (await relayWrangler('preview')).name;
  ctx.log(`the preview relay (${name}, service/do [env.preview]) from ${await head(ctx)}, with wrangler ${version}`);
  const gone = await missing(ctx, RELAY_NEEDS);
  for (const g of gone) ctx.log(`  not ready: needs ${g}`);
  const key = (await ctx.config()).preview?.serviceKey;
  if (!key) ctx.log('  not ready: config/openhearts.json has no preview.serviceKey, so the preview relay would carry nobody (./oh preview secrets --apply)');
  const ready = !gone.length && !!key;
  if (!flags.apply) {
    ctx.log(ready ? 'nothing deployed; --apply deploys it' : 'nothing deployed');
    return;
  }
  if (!ready) throw new Failed('preview relay: not deployed (see above)');
  const code = await ctx.run('npx', ['--yes', `wrangler@${version}`, 'deploy', '--env', 'preview'], { cwd: join(root, 'service/do') });
  if (code !== 0) throw new Failed(`preview relay: wrangler deploy exited ${code}`);
}

export async function site(ctx, { flags }) {
  const label = flags.label ?? ((await branch(ctx)) === 'main' ? 'main' : 'dev');
  ctx.log(`the site, the app and the service's handlers from ${await head(ctx)}, to ${label === 'main' ? 'production' : `the preview ${label}`}`);
  const publishing = label === 'main' ? (await termsProblems(ctx)).publishing : [];
  for (const { document, entry } of publishing) {
    ctx.log(`  publishes the ${document} of ${versionOf(entry)}, a ${entry.change} change${told(entry) ? ': every device is shown it, and no one is emailed it until you say (./oh terms notify --apply)' : ''}`);
    if (entry.change === 'price') ctx.log(`  then make Stripe's price match the terms (./oh infra --only stripe --apply): until it does, the shop does not sell`);
  }
  const ready = label !== 'main' || (await cleared(ctx, 'site', flags.apply));
  if (!flags.apply) {
    ctx.log(ready ? 'nothing deployed; --apply deploys it' : 'nothing deployed');
    return;
  }
  const code = await ctx.run(join(root, 'deploy.sh'), [label]);
  if (code !== 0) throw new Failed(`site: deploy.sh exited ${code}`);
  if (publishing.some(({ entry }) => told(entry))) ctx.log('published: now email web subscribers what changed (./oh terms notify --apply)');
}

/// Production, in the order that keeps devices playing: the relay, then
/// the site (docs/how-to/deploy.md). A key rotation goes the other way
/// round, by hand (docs/how-to/rotate-the-service-key.md).
export async function all(ctx, said) {
  if (said.flags.label && said.flags.label !== 'main') throw new Usage('deploy all is production; a preview is deploy site --label <name>');
  await relay(ctx, said);
  await site(ctx, { ...said, flags: { ...said.flags, label: 'main' } });
}

export async function prune(ctx, { flags }) {
  const keep = flags.keep ?? '5';
  if (!/^\d+$/.test(keep)) throw new Usage('--keep takes a number');
  const code = await ctx.run(join(root, 'deploy.sh'), ['--prune', keep, ...(flags.apply ? [] : ['-n'])]);
  if (code !== 0) throw new Failed(`prune: deploy.sh exited ${code}`);
}

async function head(ctx) {
  const { out } = await ctx.capture('git', ['rev-parse', '--short', 'HEAD']);
  return out.trim() || 'an unknown commit';
}

async function branch(ctx) {
  return (await ctx.capture('git', ['rev-parse', '--abbrev-ref', 'HEAD'])).out.trim();
}

/// The device key a proving checkout is made for: no device's, so that
/// nothing could be bound to it even if it were paid.
export const NO_DEVICE = '0'.repeat(64);

/// Whether [stripe] makes a Managed Payments checkout for the price the
/// service sells, with every field the service asks for
/// (service/functions/stripe.mjs, checkoutFields): made, and expired at
/// once. Throws with Stripe's words when it does not.
export async function sellsThroughLink(stripe, origin) {
  const lookup = stripeDefinition.price.lookupKey;
  const price = (await stripe.get(`/prices?${new URLSearchParams({ 'lookup_keys[]': lookup, active: 'true', limit: '1' })}`)).data?.[0];
  if (!price?.id) throw new Failed(`no active price holds the lookup key ${lookup}`);
  const session = await stripe.post('/checkout/sessions', checkoutFields(NO_DEVICE, price.id, `${origin}/play/`, `${origin}/play/`, 'en'));
  await stripe.post(`/checkout/sessions/${encodeURIComponent(session.id)}/expire`);
  return true;
}

/// Production, checked as a deploy is checked: the build that is live,
/// the service's health, the relay, the order route, a checkout Link
/// will sell, every web subscriber told of a published change that
/// matters to them, and the accounts against their definitions. Every
/// check says ok or why not; Failed if any did not pass.
export async function verify(ctx) {
  const config = await ctx.config();
  const origin = config.appOrigin;
  const failures = [];
  const check = (ok, line) => {
    ctx.log(`${ok ? 'ok    ' : 'FAILED'} ${line}`);
    if (!ok) failures.push(line);
  };
  const get = async (url, init) => {
    try {
      const res = await ctx.fetch(url, init);
      return { status: res.status, text: await res.text() };
    } catch (e) {
      return { status: 0, text: String(e?.message ?? e) };
    }
  };

  const built = await get(`${origin}/build-info.json`);
  let live = null;
  try {
    live = JSON.parse(built.text);
  } catch {
    // Not JSON: said below.
  }
  const main = (await ctx.capture('git', ['rev-parse', '--short', 'origin/main'])).out.trim();
  check(built.status === 200 && live?.build === main, `the live build is ${live?.build ?? `unreadable (${built.status})`}; origin/main is ${main || 'unknown'}`);
  const health = await get(`${origin}/api/health`);
  check(health.status === 200 && /"ok":true/.test(health.text), `the service's health: ${health.status} ${health.text.slice(0, 120)}`);
  const relayRoot = await get(`https://${await relayHost()}/`);
  check(relayRoot.status === 200, `the relay answers: ${relayRoot.status}`);
  const order = await get(`${origin}/api/order`);
  check(order.status === 405, `the order route turns a GET away: ${order.status}`);
  // Every web subscription is sold by Link (Managed Payments), which
  // Stripe has to have approved and the Dashboard to have turned on, and
  // which no API reports: so a checkout is made as the service makes
  // one, and expired at once, before anybody could pay with it.
  if (!ctx.env.STRIPE_API_KEY) ctx.log('skipped a checkout through Link: needs STRIPE_API_KEY');
  else {
    try {
      check(await sellsThroughLink(ctx.stripe(), origin), 'a checkout is sold through Link (Managed Payments), and expired unpaid');
    } catch (e) {
      check(false, `a checkout through Link (Managed Payments): ${e?.message ?? e}`);
    }
  }
  const tellers = ['CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID', 'STRIPE_API_KEY'].filter((n) => !ctx.env[n]);
  if (tellers.length) ctx.log(`skipped the notices of changes to the terms: needs ${tellers.join(' and ')}`);
  else {
    try {
      for (const { document, entry, subscriptions, left } of await untold(ctx)) {
        check(!left.length, `the ${document} of ${versionOf(entry)}: ${subscriptions.length - left.length} of ${subscriptions.length} web subscription(s) told${left.length ? ' (./oh terms notify --apply)' : ''}`);
      }
    } catch (e) {
      check(false, `the notices of changes to the terms: ${e?.message ?? e}`);
    }
  }
  for (const [script, needs] of [
    ['infra/apply.mjs', ['CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID', 'STRIPE_API_KEY']],
    ['observability/apply.mjs', ['NEW_RELIC_API_KEY', 'NEW_RELIC_ACCOUNT_ID', 'NEW_RELIC_REGION']],
  ]) {
    const absent = needs.filter((n) => !ctx.env[n]);
    if (absent.length) {
      ctx.log(`skipped ${script}: needs ${absent.join(' and ')}`);
      continue;
    }
    const { code, out } = await ctx.capture('node', [join(root, script)], { env: ctx.env });
    const last = out.trim().split('\n').at(-1) ?? '';
    check(code === 0 && /^0 change\(s\)/.test(last), `${script}: ${last}`);
  }
  if (failures.length) throw new Failed(`${failures.length} check(s) failed`);
}
