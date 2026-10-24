// What an oh command reads from the machine it runs on: the credentials
// in the environment, the production store and bucket, the deployment's
// config, Stripe, and the programs it starts. Each is made only when a
// command asks for it, so `oh help` needs nothing, and a test hands a
// command fakes in their place (context, below).

import { spawn as spawnChild } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { PRIVATE_BUCKET, pages } from '../infra/cloudflare.mjs';
import { stripe as stripeDefinition } from '../infra/stripe.mjs';
import { restStore } from '../service/tool/kv.mjs';
import { restBucket, restObjects } from '../service/tool/r2.mjs';

/// The repository's root, wherever oh is run from.
export const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/// A command used wrongly: oh says how to use it and exits 2.
export class Usage extends Error {}

/// A command that could not do what it was asked: oh says why and exits 1.
export class Failed extends Error {}

/// Every credential an oh command can need, and what it has to allow.
/// The reference (docs/reference/oh.md) lists them from here.
export const CREDENTIALS = {
  CLOUDFLARE_API_TOKEN: 'A Cloudflare API token. Accounts: Workers KV Storage Edit, and Workers R2 Storage Edit to find an account by a picture, take a name off kept games, hold or release an account, and keep or fetch the PhotoDNA module. Deploys and infrastructure: what docs/how-to/apply-infrastructure.md lists. Looking into a table (oh table): Workers Observability Read.',
  CLOUDFLARE_ACCOUNT_ID: 'The Cloudflare account the project is in.',
  STRIPE_API_KEY: 'A live-mode Stripe secret or restricted key. Finding an account by email: Customers and Subscriptions read. Refunds and terminations: Subscriptions write, Refunds write, and Invoices read. oh verify: Prices read and Checkout Sessions write, to make a checkout through Link and expire it. Infrastructure: what docs/how-to/apply-infrastructure.md lists.',
  NEW_RELIC_API_KEY: 'A New Relic User key, for the monitors (oh infra), and to read what devices reported of a table (oh table).',
  NEW_RELIC_ACCOUNT_ID: 'The New Relic account the monitors and the browser agent are in.',
  NEW_RELIC_REGION: 'US or EU.',
};

/// [names] from the environment, in order, or Failed naming the ones
/// that are not set.
export function need(env, ...names) {
  const missing = names.filter((n) => !env[n]);
  if (missing.length) throw new Failed(`needs ${missing.join(' and ')} (see oh help credentials)`);
  return names.map((n) => env[n]);
}

/// The deployment's config, config/openhearts.json.
export async function readConfig() {
  return JSON.parse(await readFile(join(root, 'config/openhearts.json'), 'utf8'));
}

/// The one Wrangler version everything is deployed with, where deploy.sh
/// pins it.
export async function wranglerVersion() {
  const script = await readFile(join(root, 'deploy.sh'), 'utf8');
  const version = /^WRANGLER_VERSION=(\S+)$/m.exec(script)?.[1];
  if (!version) throw new Failed('no WRANGLER_VERSION in deploy.sh');
  return version;
}

/// The production store, OH_STORE, as its namespace is bound in the
/// relay worker's wrangler.toml (the Pages project's production
/// environment binds the same one).
export async function productionStore(env, fetchImpl = fetch) {
  const [token, account] = need(env, 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID');
  const toml = await readFile(join(root, 'service/do/wrangler.toml'), 'utf8');
  const namespace = /binding = "OH_STORE"\s*\nid = "([0-9a-f]+)"/.exec(toml)?.[1];
  if (!namespace) throw new Failed('no OH_STORE namespace id in service/do/wrangler.toml');
  return restStore({ token, account, namespace, fetchImpl });
}

/// The production bucket of kept games, OH_RECORDS, where a legal hold
/// keeps its pictures too.
export function recordsBucket(env, fetchImpl = fetch) {
  const [token, account] = need(env, 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID');
  return restBucket({ token, account, bucket: pages.environments.production.r2.OH_RECORDS, fetchImpl });
}

/// The relay worker's address, the custom domain its wrangler.toml
/// routes to it.
export async function relayOrigin() {
  const toml = await readFile(join(root, 'service/do/wrangler.toml'), 'utf8');
  const host = /routes = \[\{ pattern = "([^"]+)", custom_domain = true \}\]/.exec(toml)?.[1];
  if (!host) throw new Failed('no custom domain in service/do/wrangler.toml routes');
  return `https://${host}`;
}

/// The bucket of the pictures subscribers set, OH_PICTURES, as the
/// relay worker's wrangler.toml binds it.
export async function picturesBucket(env, fetchImpl = fetch) {
  const [token, account] = need(env, 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID');
  const toml = await readFile(join(root, 'service/do/wrangler.toml'), 'utf8');
  const bucket = /binding = "OH_PICTURES"\s*\nbucket_name = "([^"]+)"/.exec(toml)?.[1];
  if (!bucket) throw new Failed('no OH_PICTURES bucket in service/do/wrangler.toml');
  return restObjects({ token, account, bucket, fetchImpl });
}

/// The private bucket, where what this repository must not hold is kept
/// (infra/cloudflare.mjs): the PhotoDNA module (ops/photodna.mjs).
export function privateBucket(env, fetchImpl = fetch) {
  const [token, account] = need(env, 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID');
  return restObjects({ token, account, bucket: PRIVATE_BUCKET, fetchImpl });
}

/// Stripe's API with STRIPE_API_KEY, in the shape the service's webhook
/// is read in (its apiVersion, infra/stripe.mjs): get(path),
/// post(path, fields) and del(path, fields), each the answer's JSON, or
/// Failed with Stripe's own words.
export function stripeApi(env, fetchImpl = fetch) {
  const [key] = need(env, 'STRIPE_API_KEY');
  const call = async (method, path, fields = null) => {
    const res = await fetchImpl(`https://api.stripe.com/v1${path}`, {
      method,
      headers: {
        authorization: `Bearer ${key}`,
        'stripe-version': STRIPE_VERSION,
        ...(fields ? { 'content-type': 'application/x-www-form-urlencoded' } : {}),
      },
      ...(fields ? { body: new URLSearchParams(fields).toString() } : {}),
    });
    const body = await res.json().catch(() => null);
    if (!res.ok) throw new Failed(`Stripe said ${res.status} to ${method} ${path}: ${body?.error?.message ?? ''}`);
    return body;
  };
  return { get: (path) => call('GET', path), post: (path, fields) => call('POST', path, fields), del: (path, fields) => call('DELETE', path, fields) };
}

/// The one Stripe API version the deployment reads Stripe in.
export const STRIPE_VERSION = stripeDefinition.webhooks[0].apiVersion;

/// [command] with [args], from [cwd], its output going straight to the
/// terminal. Resolves with its exit code.
export function run(command, args, { cwd = root, env = process.env, input = null } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnChild(command, args, { cwd, env, stdio: [input === null ? 'inherit' : 'pipe', 'inherit', 'inherit'] });
    child.on('error', reject);
    child.on('exit', (code) => resolve(code ?? 1));
    if (input !== null) child.stdin.end(input);
  });
}

/// [command] with [args], its output kept: {code, out}.
export function capture(command, args, { cwd = root, env = process.env } = {}) {
  return new Promise((resolve) => {
    const child = spawnChild(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', () => resolve({ code: 127, out }));
    child.on('exit', (code) => resolve({ code: code ?? 1, out }));
  });
}

/// What a command is run with: where it writes, the environment, and
/// how it reaches the world. A test passes its own.
export function context(overrides = {}) {
  const env = overrides.env ?? process.env;
  const fetchImpl = overrides.fetch ?? fetch;
  return {
    env,
    fetch: fetchImpl,
    log: (line) => console.log(line),
    warn: (line) => console.error(`oh: ${line}`),
    store: () => productionStore(env, fetchImpl),
    bucket: () => recordsBucket(env, fetchImpl),
    pictures: () => picturesBucket(env, fetchImpl),
    privateFiles: () => privateBucket(env, fetchImpl),
    relay: relayOrigin,
    stripe: () => stripeApi(env, fetchImpl),
    config: readConfig,
    run,
    capture,
    now: () => Date.now(),
    ...overrides,
  };
}
