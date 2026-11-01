// `oh deploy …` and `oh verify`: the relay worker and the site put into
// production, relay first, and production checked afterwards
// (docs/how-to/deploy.md), deleting the site's old deployments on the
// way. Publishing a change to the terms is a deploy of the site too
// (docs/how-to/change-the-terms.md). What has to hold before anything reaches
// production is in gate.mjs, which deploy.sh and the relay's build step
// run themselves, so that deploying without oh is held to it too.

import { rm } from 'node:fs/promises';
import { join } from 'node:path';

import { Failed, Usage, WRANGLER, cloudflareOnly, need, relayHost, relayWrangler, root, wranglerVersion } from './env.mjs';
import { releaseProblems } from './gate.mjs';
import { MODULE_ALIAS, MODULE_DIR, fetchModule, pinsOf } from './photodna.mjs';
import { termsProblems, untold } from './terms.mjs';
import { told, versionOf } from '../site/ledger.mjs';
import { pages } from '../infra/cloudflare.mjs';
import { stripe as stripeDefinition } from '../infra/stripe.mjs';
import { checkoutFields } from '../service/functions/stripe.mjs';

/// The programs a relay deploy builds with: its custom build
/// (service/bench/build.sh) compiles the house and the native libraries,
/// and Wrangler builds the house's image with Docker.
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
  if (!(await ctx.config()).houseKey) gone.push('the house\'s key in config/openhearts.json, houseKey, without which no sealed table is refereed and no result taken (./oh house key --apply)');
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
  try {
    const withModule = (await fetchModule(ctx, dir)) !== null;
    await deployRelay(ctx, 'relay', { flags: withModule ? ['--alias', MODULE_ALIAS] : [] });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/// `wrangler deploy` of a relay worker from service/do, [env] naming
/// which (`--env preview`, or nothing for production's) and [flags] the
/// rest; [what] it is called in what is said. Wrangler, and the build
/// it runs, are given only Cloudflare's credentials. Wrangler uploads the
/// worker, live at once, before it builds the house's image and pushes
/// it, so an image that failed to build would leave the new worker
/// beside the old house. So the deploy is built first with --dry-run,
/// which runs the custom build and builds the image but uploads
/// nothing; and should the deploy fail after its upload all the same
/// (the image's push, say), the version that served before is put back.
async function deployRelay(ctx, what, { env = [], flags = [] } = {}) {
  const options = { cwd: join(root, 'service/do'), env: cloudflareOnly(ctx.env) };
  const wrangler = (...args) => [...args, ...env];
  const built = await ctx.run(WRANGLER, wrangler('deploy', '--dry-run', ...flags), options);
  if (built !== 0) throw new Failed(`${what}: not deployed: its build or the house's image failed (wrangler deploy --dry-run exited ${built}), and nothing was uploaded`);
  const before = await serving(ctx, wrangler('deployments', 'status', '--json'), options);
  const code = await ctx.run(WRANGLER, wrangler('deploy', ...flags), options);
  if (code === 0) return;
  const after = await serving(ctx, wrangler('deployments', 'status', '--json'), options);
  if (!before || !after) throw new Failed(`${what}: wrangler deploy exited ${code}, and which version serves can't be told: see wrangler deployments status${env.length ? ` ${env.join(' ')}` : ''}, from service/do`);
  if (after === before) throw new Failed(`${what}: wrangler deploy exited ${code}; ${before} still serves`);
  const back = await ctx.run(WRANGLER, wrangler('rollback', before, '--message', `${what}: its deploy failed after the upload`, '--yes'), options);
  if (back !== 0) throw new Failed(`${what}: wrangler deploy exited ${code} with ${after} live, and putting ${before} back failed too (wrangler rollback exited ${back})`);
  throw new Failed(`${what}: wrangler deploy exited ${code} with ${after} live; ${before}, which served before, serves again`);
}

/// The version serving all of a worker's traffic, from what [args]
/// (wrangler deployments status --json) said; null when that can't be
/// told, or the traffic is split.
async function serving(ctx, args, options) {
  const { code, out } = await ctx.capture(WRANGLER, args, options);
  if (code !== 0) return null;
  let status;
  try {
    // What npm and Wrangler say on stderr comes with it.
    status = JSON.parse(out.slice(out.indexOf('{'), out.lastIndexOf('}') + 1));
  } catch (e) {
    if (e instanceof SyntaxError) return null;
    throw e;
  }
  return (status?.versions ?? []).find((v) => v?.percentage === 100)?.version_id ?? null;
}

/// The preview relay (wrangler.toml, [env.preview]), from whatever is
/// checked out, as a preview of the site is: it reaches nothing of
/// production's, and checks no picture, so it is built without the
/// PhotoDNA module. Its devices are held to the key previews have, and
/// its tables to the house previews have, which config/openhearts.json
/// names (preview.serviceKey, preview.houseKey).
async function previewRelay(ctx, { flags }) {
  const version = await wranglerVersion();
  const name = (await relayWrangler('preview')).name;
  ctx.log(`the preview relay (${name}, service/do [env.preview]) from ${await head(ctx)}, with wrangler ${version}`);
  const gone = await missing(ctx, RELAY_NEEDS);
  for (const g of gone) ctx.log(`  not ready: needs ${g}`);
  const { serviceKey: key, houseKey: house } = (await ctx.config()).preview ?? {};
  if (!key) ctx.log('  not ready: config/openhearts.json has no preview.serviceKey, so the preview relay would carry nobody (./oh preview secrets --apply)');
  if (!house) ctx.log('  not ready: config/openhearts.json has no preview.houseKey, so the preview relay would referee no sealed table (./oh preview secrets --apply)');
  const ready = !gone.length && !!key && !!house;
  if (!flags.apply) {
    ctx.log(ready ? 'nothing deployed; --apply deploys it' : 'nothing deployed');
    return;
  }
  if (!ready) throw new Failed('preview relay: not deployed (see above)');
  await deployRelay(ctx, 'preview relay', { env: ['--env', 'preview'] });
}

export async function site(ctx, { flags }) {
  const label = flags.label ?? ((await branch(ctx)) === 'main' ? 'main' : 'dev');
  ctx.log(`the site, the app and the service's handlers from ${await head(ctx)}, to ${label === 'main' ? 'production' : `the preview ${label}`}`);
  const publishing = label === 'main' ? (await termsProblems(ctx)).publishing : [];
  for (const { document, entry } of publishing) {
    ctx.log(`  publishes the ${document} of ${versionOf(entry)}, a ${entry.change} change${told(entry) ? ': every device is shown it, and no one is emailed it until you say (./oh terms notify --apply)' : ''}`);
    if (entry.change === 'price') ctx.log(`  then make Stripe's price match the terms (./oh infra --only stripe --apply): until it does, the shop does not sell`);
  }
  if (label === 'main') ctx.log(`  first deletes old deployments: oh deploy prune lists the ones that would go`);
  const ready = label !== 'main' || (await cleared(ctx, 'site', flags.apply));
  if (!flags.apply) {
    ctx.log(ready ? 'nothing deployed; --apply deploys it' : 'nothing deployed');
    return;
  }
  // Only a production deploy sweeps. It runs from reviewed code on main;
  // a preview deploy runs whatever is checked out, so it must not delete
  // production's deployments. The sweep runs before publishing, while the
  // deployment being replaced is still live and so still kept: it stays
  // there to roll back to. A failed sweep leaves extra deployments behind,
  // which harms nothing, so it does not stop the deploy.
  if (label === 'main') {
    try {
      await sweep(ctx, { apply: true });
    } catch (e) {
      ctx.warn(`could not delete old deployments: ${e?.message ?? e}. Deploying anyway; ./oh deploy prune --apply tries again.`);
    }
  }
  const code = await ctx.run(join(root, 'deploy.sh'), [label], { env: cloudflareOnly(ctx.env) });
  if (code !== 0) throw new Failed(`site: deploy.sh exited ${code}`);
  if (publishing.some(({ entry }) => told(entry))) ctx.log('published: now email web subscribers what changed (./oh terms notify --apply)');
}

/// Production, in the order that keeps devices playing: the relay, then
/// the site (docs/how-to/deploy.md). A key rotation goes the other way
/// round, by hand (docs/how-to/rotate-the-service-key.md).
export async function all(ctx, said) {
  await relay(ctx, said);
  await site(ctx, { ...said, flags: { ...said.flags, label: 'main' } });
}

export async function prune(ctx, { flags }) {
  const keep = flags.keep ?? String(PREVIEWS_KEPT);
  if (!/^\d+$/.test(keep)) throw new Usage('--keep takes a number');
  await sweep(ctx, { keep: Number(keep), apply: flags.apply });
}

// ---- sweeping up old deployments ---------------------------------------
// Cloudflare keeps every upload of the site as a deployment until it is
// deleted. A production deploy deletes the old ones first, and
// `oh deploy prune` does the same on its own (docs/how-to/deploy.md).

/// How many deployments of each kind a sweep keeps: the newest
/// [PREVIEWS_KEPT] previews and the newest [PRODUCTION_KEPT] production
/// deployments. It also keeps the newest that many that succeeded, so
/// failed uploads never push out the deployments a rollback needs.
export const PREVIEWS_KEPT = 5;
export const PRODUCTION_KEPT = 3;

/// Cloudflare lists deployments [LISTED] to a page. A sweep reads at most
/// [LISTED_PAGES] pages; anything older waits for the next sweep.
const LISTED = 25;
const LISTED_PAGES = 100;

/// Whether Cloudflare finished publishing [d]. Only such a deployment can
/// be rolled back to.
const succeeded = (d) => d.latest_stage?.name === 'deploy' && d.latest_stage?.status === 'success';

/// The deployments a sweep deletes, newest first. For each kind (previews,
/// and production), it keeps the newest [keep] (always [PRODUCTION_KEPT]
/// for production), and the newest that many that succeeded, and deletes
/// the rest. It never deletes a deployment with an alias: that is one that
/// is live, either production's on its domains or the newest of a preview
/// branch on its branch's address. (Cloudflare refuses to delete an
/// aliased preview unless forced, and a sweep never forces.)
///
/// Throws Failed if a deployment has no readable date: the dates decide
/// which are newest, and a deletion cannot be undone.
export function sweepable(deployments, keep = PREVIEWS_KEPT) {
  const madeAt = (d) => Date.parse(d.created_on);
  const undated = deployments.find((d) => Number.isNaN(madeAt(d)));
  if (undated) throw new Failed(`Cloudflare listed deployment ${undated.id} without a readable date (${JSON.stringify(undated.created_on ?? null)}), so nothing was deleted`);
  const newest = [...deployments].sort((a, b) => madeAt(b) - madeAt(a));
  const seen = { production: 0, preview: 0 };
  const seenSucceeded = { production: 0, preview: 0 };
  const doomed = [];
  for (const d of newest) {
    const kind = d.environment === 'production' ? 'production' : 'preview';
    const limit = kind === 'production' ? PRODUCTION_KEPT : keep;
    seen[kind] += 1;
    if (succeeded(d)) seenSucceeded[kind] += 1;
    const kept = seen[kind] <= limit || (succeeded(d) && seenSucceeded[kind] <= limit) || d.aliases?.length > 0;
    if (!kept) doomed.push(d);
  }
  return doomed;
}

/// Calls the Pages project's deployments API ([method] on [path]) and
/// returns the answer's JSON. Throws Failed unless Cloudflare answered
/// and said it succeeded.
async function deploymentsApi(ctx, method, path = '') {
  const [token, account] = need(ctx.env, 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID');
  const url = `https://api.cloudflare.com/client/v4/accounts/${account}/pages/projects/${pages.project}/deployments${path}`;
  let res;
  try {
    res = await ctx.fetch(url, { method, headers: { Authorization: `Bearer ${token}` } });
  } catch (e) {
    throw new Failed(`Cloudflare did not answer ${method} deployments${path}: ${e?.message ?? e}`);
  }
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.success) throw new Failed(`Cloudflare said ${res.status} to ${method} deployments${path}: ${body ? JSON.stringify(body.errors ?? body) : 'not JSON'}`);
  return body;
}

/// Every deployment of the Pages project, each once.
async function listDeployments(ctx) {
  const found = new Map();
  for (let page = 1; page <= LISTED_PAGES; page++) {
    const path = `?per_page=${LISTED}&page=${page}`;
    const listed = (await deploymentsApi(ctx, 'GET', path)).result;
    // An answer without a list is a failure, not an empty project:
    // taking it for one would report that there was nothing to delete.
    if (!Array.isArray(listed)) throw new Failed(`Cloudflare's answer to GET deployments${path} has no list of deployments: ${JSON.stringify(listed ?? null)}`);
    // A deployment made while we page through shifts the rest down by
    // one, so the last of one page can come again as the first of the
    // next. Keyed by id, it is counted once.
    for (const d of listed) found.set(d.id, d);
    if (listed.length < LISTED) break;
  }
  return [...found.values()];
}

/// One line describing [d]: its id, when it was made, and its branch.
function deploymentLine(d) {
  const made = String(d.created_on).slice(0, 16).replace('T', ' ');
  return `${String(d.id).slice(0, 8)}  ${made}  ${d.deployment_trigger?.metadata?.branch ?? '?'} (${d.environment}${succeeded(d) ? '' : ', failed'})`;
}

/// Deletes the deployments [sweepable] picks and reports each one. Every
/// deletion is tried; Failed afterwards if any did not go. Without
/// [apply], it only lists what it would delete.
async function sweep(ctx, { keep = PREVIEWS_KEPT, apply = false } = {}) {
  const listed = await listDeployments(ctx);
  const doomed = sweepable(listed, keep);
  const kept = `Kept: of the previews, the newest ${keep} and the newest ${keep} that succeeded; of production's, the newest ${PRODUCTION_KEPT} and the newest ${PRODUCTION_KEPT} that succeeded; and every live one.`;
  if (!doomed.length) {
    ctx.log(`nothing to delete among ${listed.length} deployment(s). ${kept}`);
    return;
  }
  if (!apply) {
    for (const d of doomed) ctx.log(`would delete ${deploymentLine(d)}`);
    ctx.log(`would delete ${doomed.length} of ${listed.length} deployment(s); --apply deletes them. ${kept}`);
    return;
  }
  const failed = [];
  for (const d of doomed) {
    try {
      await deploymentsApi(ctx, 'DELETE', `/${encodeURIComponent(d.id)}`);
      ctx.log(`deleted ${deploymentLine(d)}`);
    } catch (e) {
      ctx.log(`not deleted ${deploymentLine(d)}: ${e.message}`);
      failed.push(d);
    }
  }
  if (failed.length) throw new Failed(`deleted ${doomed.length - failed.length} of ${doomed.length} old deployment(s); ${failed.length} could not be deleted (above)`);
  ctx.log(`deleted ${doomed.length} of ${listed.length} deployment(s). ${kept}`);
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
    // Clean is nothing to change and nothing to fix by hand: infra's
    // last line is "0 change(s), 0 by hand; …", observability's
    // "0 change(s); …".
    const last = out.trim().split('\n').at(-1) ?? '';
    check(code === 0 && /^0 change\(s\)(, 0 by hand)?;/.test(last), `${script}: ${last}`);
  }
  if (failures.length) throw new Failed(`${failures.length} check(s) failed`);
}
