// `oh preview …`: what previews of the app play live with
// (docs/how-to/deploy.md#play-live-on-a-preview). A preview is a
// deployment of its own: the previews' store, the preview relay
// (service/do/wrangler.toml, [env.preview]), and secrets of its own,
// none of them production's, since a preview runs whatever branch was
// deployed to it. Nobody buys anything on a preview: the operator
// invites the people who play there.

import { randomBytes } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { Failed, relayWrangler, root, wranglerVersion } from './env.mjs';
import { pages } from '../infra/cloudflare.mjs';
import { accountFor, makeBackups } from '../service/functions/accounts.mjs';
import { dayAfter } from '../service/functions/rows.mjs';

const configFile = (ctx) => ctx.configFile ?? join(root, 'config/openhearts.json');

const member = (o) => `{ ${Object.entries(o).map(([k, v]) => `${JSON.stringify(k)}: ${JSON.stringify(v)}`).join(', ')} }`;

/// [text], config/openhearts.json, with preview's [field] — its
/// serviceKey, or its houseKey — made [key] and everything else in it
/// as it was written: the member made beside production's serviceKey if
/// there is none.
export function withPreviewKey(text, key, field = 'serviceKey') {
  const at = text.indexOf('"preview":');
  if (at >= 0) {
    const open = text.indexOf('{', at);
    let i = open;
    for (let depth = 0; i < text.length; i++) {
      if (text[i] === '{') depth++;
      else if (text[i] === '}' && --depth === 0) break;
    }
    const preview = { ...JSON.parse(text.slice(open, i + 1)), [field]: key };
    return `${text.slice(0, at)}"preview": ${member(preview)}${text.slice(i + 1)}`;
  }
  const line = /^( *)"serviceKey": "[0-9a-f]*",\n/m.exec(text);
  if (!line) throw new Failed('config/openhearts.json has no "serviceKey" to put the previews\' beside');
  const end = line.index + line[0].length;
  return `${text.slice(0, end)}${line[1]}"preview": ${member({ [field]: key })},\n${text.slice(end)}`;
}

/// [text], config/openhearts.json, with production's houseKey made
/// [key], where it is or beside serviceKey, and everything else in it as
/// it was written.
export function withHouseKey(text, key) {
  const had = /^( *)"houseKey": (?:"[0-9a-f]*"|null),\n/m.exec(text);
  if (had) return `${text.slice(0, had.index)}${had[1]}"houseKey": ${JSON.stringify(key)},\n${text.slice(had.index + had[0].length)}`;
  const line = /^( *)"serviceKey": "[0-9a-f]*",\n/m.exec(text);
  if (!line) throw new Failed('config/openhearts.json has no "serviceKey" to put the house\'s beside');
  const end = line.index + line[0].length;
  return `${text.slice(0, end)}${line[1]}"houseKey": ${JSON.stringify(key)},\n${text.slice(end)}`;
}

/// The pair service_key.dart --json said, {key, secret}, or null. What it
/// says holds the secret: it is read here and said to nobody.
function pairIn(out) {
  for (const line of out.split('\n').reverse()) {
    try {
      const { key, secret } = JSON.parse(line);
      if (/^[0-9a-f]{64}$/.test(key) && /^[0-9a-f]{64}$/.test(secret)) return { key, secret };
    } catch {
      // Not the pair: what dart run says as it builds.
    }
  }
  return null;
}

/// A new key pair, made by service_key.dart and said to nobody: {key,
/// secret}. Failed when none was made.
async function mintPair(ctx) {
  const made = await ctx.capture('dart', ['run', 'bin/service_key.dart', '--json'], { cwd: join(root, 'service') });
  const pair = made.code === 0 ? pairIn(made.out) : null;
  if (!pair) throw new Failed(`bin/service_key.dart made no key pair (it exited ${made.code}; it needs Dart, and dart pub get in service/)`);
  return pair;
}

/// [value] put as a wrangler secret with [args], from [cwd], on stdin:
/// said to nobody.
async function putSecret(ctx, args, cwd, value, what) {
  const version = await wranglerVersion();
  const code = await ctx.run('npx', ['--yes', `wrangler@${version}`, ...args], { cwd, input: value });
  if (code !== 0) throw new Failed(`wrangler said ${code} setting ${what}`);
  ctx.log(`set ${what}`);
}

/// `oh preview secrets`: the secrets previews keep for themselves, made
/// new and shown to nobody. The service key pair previews sign with:
/// its secret set on the Pages project's preview environment as
/// OH_SERVICE_SECRET, its public half written to config/openhearts.json
/// as preview.serviceKey, to commit, since every preview build and the
/// preview relay are made with it. And the previews' house: its secret
/// set on the preview relay as OH_HOUSE_SECRET, its public half written
/// as preview.houseKey, the house every preview's sealed table names.
export async function secrets(ctx, { flags }) {
  const relay = (await relayWrangler('preview')).name;
  const project = pages.project;
  ctx.log('would make new secrets for previews, none of them production\'s, and show them to nobody:');
  ctx.log(`  a service key pair: its secret as OH_SERVICE_SECRET on ${project}'s preview environment, its public half in config/openhearts.json as preview.serviceKey`);
  ctx.log(`  the house's key pair: its secret as OH_HOUSE_SECRET on ${relay}, its public half in config/openhearts.json as preview.houseKey`);
  ctx.log('a preview built before keeps the keys it was built with: deploy the preview relay and each preview again afterwards');
  if (!flags.apply) {
    ctx.log('nothing changed; --apply makes them');
    return;
  }
  const service = await mintPair(ctx);
  const house = await mintPair(ctx);
  await putSecret(ctx, ['pages', 'secret', 'put', 'OH_SERVICE_SECRET', '--project-name', project, '--env', 'preview'], root, service.secret, `OH_SERVICE_SECRET on ${project} (preview)`);
  const path = configFile(ctx);
  await writeFile(path, withPreviewKey(await readFile(path, 'utf8'), service.key));
  ctx.log(`config/openhearts.json: preview.serviceKey is ${service.key}; commit it`);
  await putSecret(ctx, ['secret', 'put', 'OH_HOUSE_SECRET', '--env', 'preview'], join(root, 'service/do'), house.secret, `OH_HOUSE_SECRET on ${relay}`);
  await writeFile(path, withPreviewKey(await readFile(path, 'utf8'), house.key, 'houseKey'));
  ctx.log(`config/openhearts.json: preview.houseKey is ${house.key}; commit it`);
  ctx.log('then ./oh deploy relay --preview --apply, and ./oh deploy site --label <label> --apply for each preview');
}

/// `oh house key`: the house's key pair for production, made new and its
/// secret shown to nobody: set on the relay worker as OH_HOUSE_SECRET,
/// where the house's container is started with it (service/do/bench.mjs),
/// and its public half written to config/openhearts.json as houseKey, to
/// commit — the house every sealed table names, and the key the relay
/// takes results from. A table started under the old key is the old
/// house's, which no longer runs: make it before the referee's first
/// deploy, or when the house's secret has to change, with no table
/// playing.
export async function houseKey(ctx, { flags }) {
  ctx.log('would make the house a new key pair and show its secret to nobody:');
  ctx.log('  its secret as OH_HOUSE_SECRET on the relay worker, its public half in config/openhearts.json as houseKey');
  ctx.log('a table started under the house\'s old key is one no house serves any more: do it with no table playing');
  if (!flags.apply) {
    ctx.log('nothing changed; --apply makes it');
    return;
  }
  const pair = await mintPair(ctx);
  await putSecret(ctx, ['secret', 'put', 'OH_HOUSE_SECRET'], join(root, 'service/do'), pair.secret, 'OH_HOUSE_SECRET on the relay worker');
  const path = configFile(ctx);
  await writeFile(path, withHouseKey(await readFile(path, 'utf8'), pair.key));
  ctx.log(`config/openhearts.json: houseKey is ${pair.key}; commit it, then deploy the relay and the site from it`);
}

/// How long an invitation lasts: a year, after which its account plays
/// on previews no more, as one whose subscription ran out.
export const INVITED_DAYS = 365;

/// `oh preview invite`: an account on the previews' store, for somebody
/// to play live on previews with, nobody's purchase (accounts.mjs,
/// paidUp) and good for [INVITED_DAYS]; and one of its backup codes,
/// which is the invitation: entered on a device of any preview, under
/// Activate subscription, it brings that device into the account. The
/// code is printed, as no other oh command prints one: it is for the
/// operator to hand on, and opens nothing of production's.
export async function invite(ctx, { flags }) {
  ctx.log(`would make an account on the previews' store that plays live on previews for ${INVITED_DAYS} days, and print one of its backup codes for a device to enter under Activate subscription`);
  if (!flags.apply) {
    ctx.log('nothing changed; --apply makes it');
    return;
  }
  const store = await ctx.previewStore();
  const now = ctx.now();
  const subscription = `invited-${randomBytes(8).toString('hex')}`;
  const renews_at = dayAfter(now, INVITED_DAYS);
  await store.put(`SUB#${subscription}`, 'META', { source: 'invited', txn_ref: null, renews_at, cancelled_at: null });
  const account = await accountFor(store, subscription, { make: true, now });
  const { codes } = await makeBackups(store, account, { now });
  ctx.log(`invited: account ${account}, playing live on previews until ${renews_at}`);
  ctx.log(`its code: ${codes[0].code}`);
  ctx.log('On a device, open a preview\'s /play/, then Activate subscription, and enter it. The account has four more codes, shown on any of its devices.');
}
