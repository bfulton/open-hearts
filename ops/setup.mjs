// `oh infra`, `oh config …`, `oh key mint`, `oh secret set` and `oh
// phone …`: what the deployment is made of, set as its definitions and
// its operator say (docs/how-to/apply-infrastructure.md,
// docs/how-to/change-remote-config.md,
// docs/how-to/rotate-the-service-key.md,
// docs/how-to/cut-a-phone-release.md).

import { readFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { join, resolve } from 'node:path';

import { Failed, Usage, root, wranglerVersion } from './env.mjs';
import { pages, relay } from '../infra/cloudflare.mjs';
import { configOf } from '../service/functions/config.mjs';
import { serviceSettingsOf } from '../service/functions/settings.mjs';
import { objectLimitsOf } from '../service/do/relay.mjs';
import { KNOWN_ROW, knownSettingsOf } from '../service/do/checkers.mjs';

export async function infra(ctx, { flags }) {
  const only = flags.only ?? null;
  if (only && !['cloudflare', 'stripe', 'newrelic'].includes(only)) throw new Usage('--only takes cloudflare, stripe or newrelic');
  const apply = flags.apply ? ['--apply'] : [];
  let failed = 0;
  if (only !== 'newrelic') {
    const code = await ctx.run('node', [join(root, 'infra/apply.mjs'), ...apply, ...(only ? ['--only', only] : [])]);
    if (code !== 0) failed++;
  }
  if (!only || only === 'newrelic') {
    const code = await ctx.run('node', [join(root, 'observability/apply.mjs'), ...apply]);
    if (code !== 0) failed++;
  }
  if (failed) throw new Failed(`${failed} of the definitions did not apply cleanly`);
}

/// The rows the deployment reads at run time, each with the check the
/// service puts it through before it believes a field of it.
const ROWS = {
  app: { key: ['config', 'app'], check: configOf, reader: 'every device, through /api/config' },
  service: { key: ['config', 'service'], check: serviceSettingsOf, reader: 'the Pages worker and the Household object' },
  relay: { key: ['config', 'relay'], check: objectLimitsOf, reader: 'the relay\'s presence object, when it is built' },
  known: { key: KNOWN_ROW, check: knownSettingsOf, reader: 'the relay\'s KnownPictures object and its daily run' },
};

function rowOf(name) {
  const row = ROWS[name];
  if (!row) throw new Usage(`no row ${name}: app, service, relay or known`);
  return row;
}

export async function configGet(ctx, { args }) {
  const row = rowOf(args.row);
  const value = await (await ctx.store()).get(...row.key);
  ctx.log(value === null ? `no ${row.key.join('|')} row: every field is at its default` : JSON.stringify(value, null, 2));
}

/// The fields of [raw] the service would not believe at all: each one,
/// set to something other than its default, that the check leaves at
/// its default. A misspelt field is one of them.
export function rejected(check, raw) {
  const kept = check(raw);
  const defaults = check({});
  return Object.keys(raw).filter((field) => !isDeepStrictEqual(raw[field], defaults[field]) && isDeepStrictEqual(kept[field], defaults[field]));
}

/// The fields the service would take, but not quite as written: a
/// default filled in, a language it does not know dropped. Each with
/// what it would be taken as.
export function reshaped(check, raw) {
  const kept = check(raw);
  const refused = new Set(rejected(check, raw));
  return Object.keys(raw)
    .filter((field) => !refused.has(field) && !isDeepStrictEqual(kept[field], raw[field]))
    .map((field) => [field, kept[field]]);
}

export async function configSet(ctx, { args, flags }) {
  const row = rowOf(args.row);
  let raw;
  try {
    raw = JSON.parse(await readFile(resolve(args.file), 'utf8'));
  } catch (e) {
    throw new Usage(`${args.file} is not a JSON file: ${e.message}`);
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Usage(`${args.file} is not a JSON object`);
  const refused = rejected(row.check, raw);
  for (const field of refused) ctx.log(`  ${field}: fails its check, so ${row.reader} would keep its default`);
  for (const [field, as] of reshaped(row.check, raw)) ctx.log(`  ${field}: taken as ${JSON.stringify(as)}`);
  if (refused.length) throw new Failed(`${refused.length} field(s) would not take; nothing written`);
  ctx.log(`would replace ${row.key.join('|')}, read by ${row.reader}, with ${args.file}: ${Object.keys(raw).join(', ') || 'no fields'}; any field left out goes back to its default`);
  if (!flags.apply) {
    ctx.log('nothing changed; --apply writes it');
    return;
  }
  await (await ctx.store()).put(...row.key, raw);
  ctx.log(`wrote ${row.key.join('|')}`);
}

export async function configClear(ctx, { args, flags }) {
  const row = rowOf(args.row);
  ctx.log(`would delete ${row.key.join('|')}, so that ${row.reader} goes back to every default`);
  if (!flags.apply) {
    ctx.log('nothing changed; --apply deletes it');
    return;
  }
  await (await ctx.store()).del(...row.key);
  ctx.log(`deleted ${row.key.join('|')}`);
}

/// A new service key pair, printed once and kept nowhere
/// (service/bin/service_key.dart).
export async function keyMint(ctx) {
  const code = await ctx.run('dart', ['run', 'bin/service_key.dart'], { cwd: join(root, 'service') });
  if (code !== 0) throw new Failed(`service_key.dart exited ${code}`);
}

/// Where each secret lives, as infra/cloudflare.mjs names them: on the
/// Pages project (in each of its environments that has it) or on the
/// relay worker.
function placesOf(name) {
  const places = [];
  for (const [env, def] of Object.entries(pages.environments)) {
    if (def.secrets?.includes(name)) places.push({ where: `Pages (${env})`, args: ['pages', 'secret', 'put', name, '--project-name', pages.project ?? 'open-hearts', ...(env === 'production' ? [] : ['--env', env])], cwd: root });
  }
  // Its optional secrets too, such as a checker's credentials, which are
  // set once they are issued.
  if (relay.secrets?.includes(name) || relay.optionalSecrets?.includes(name)) places.push({ where: 'the relay worker', args: ['secret', 'put', name], cwd: join(root, 'service/do') });
  return places;
}

/// What is typed, not shown: a secret read from the terminal without
/// echoing it, or whatever is piped in.
async function secretFromInput(stdin = process.stdin, stderr = process.stderr) {
  if (!stdin.isTTY) {
    let text = '';
    for await (const chunk of stdin) text += chunk;
    return text.replace(/\r?\n$/, '');
  }
  stderr.write('value (not shown): ');
  stdin.setRawMode(true);
  stdin.resume();
  let text = '';
  for await (const chunk of stdin) {
    for (const ch of chunk.toString('utf8')) {
      if (ch === '\r' || ch === '\n') {
        stdin.setRawMode(false);
        stdin.pause();
        stderr.write('\n');
        return text;
      }
      if (ch === '\u0003') {
        stdin.setRawMode(false);
        throw new Failed('cancelled');
      }
      text = ch === '\u007f' ? text.slice(0, -1) : text + ch;
    }
  }
  return text;
}

export async function secretSet(ctx, { args, flags }) {
  const places = placesOf(args.name);
  if (!places.length) throw new Usage(`${args.name} is not a secret infra/cloudflare.mjs defines`);
  ctx.log(`would set ${args.name} on ${places.map((p) => p.where).join(', ')}, from what you type (not shown) or pipe in`);
  if (!flags.apply) {
    ctx.log('nothing changed; --apply sets it');
    return;
  }
  const value = await (ctx.readSecret ?? secretFromInput)();
  if (!value) throw new Failed('no value: nothing set');
  const version = await wranglerVersion();
  for (const place of places) {
    const code = await ctx.run('npx', ['--yes', `wrangler@${version}`, ...place.args], { cwd: place.cwd, input: value });
    if (code !== 0) throw new Failed(`wrangler said ${code} setting ${args.name} on ${place.where}`);
    ctx.log(`set ${args.name} on ${place.where}`);
  }
}

export async function phone(ctx, { args, rest }) {
  if (args.platform !== 'ios' && args.platform !== 'android') throw new Usage('phone takes ios or android');
  const code = await ctx.run(join(root, 'build_phone.sh'), [args.platform, ...rest]);
  if (code !== 0) throw new Failed(`build_phone.sh exited ${code}`);
}
