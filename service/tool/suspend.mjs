// An account suspended from live play or let back, and its name or
// picture taken off or put back, on the operator's word (the terms, "At
// a live table" and "Copyright"; docs/how-to/suspend-an-account.md).
//
//   node service/tool/suspend.mjs --find <name or email>          the accounts it names
//   node service/tool/suspend.mjs <account or device key>         how the account stands
//   node service/tool/suspend.mjs <account> --suspend             suspend it
//   node service/tool/suspend.mjs <account> --lift                let it back
//   node service/tool/suspend.mjs <account> --remove name,picture take them off
//   node service/tool/suspend.mjs <account> --restore             put them back
//
// An act says what it would do and stops; with --apply it is done. It is
// done in the account's own turn (service/functions/suspension.mjs):
// the tool writes an order into the store, which KV keeps for ten
// minutes, and asks the service to carry it out (POST /api/order),
// asking again while the store has not shown the order to the service
// yet. Taking a name off also takes it off the games the account
// played (records.mjs, anonymizeGames), which putting it back does not
// undo.
//
// Needs CLOUDFLARE_API_TOKEN (Workers KV Storage: Edit, and Workers R2
// Storage: Edit to take a name off kept games) and
// CLOUDFLARE_ACCOUNT_ID; finding by an email address needs
// STRIPE_API_KEY too. Reads the namespace id from
// service/do/wrangler.toml (the production OH_STORE), the bucket from
// infra/cloudflare.mjs (production's OH_RECORDS) and the service from
// config/openhearts.json (appOrigin). Prints accounts, keys and what
// changed, never a name, a picture or a code.

import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import { pages } from '../../infra/cloudflare.mjs';
import { anonymizeGames } from '../functions/records.mjs';
import { hex } from '../functions/rows.mjs';
import { ORDER_KEPT_S, orderOf, orderRow } from '../functions/suspension.mjs';
import { accountOf, findAccounts } from './find.mjs';
import { restStore } from './kv.mjs';
import { restBucket } from './r2.mjs';

/// How the account stands, as the store has it: {exists, suspended (the
/// day, or null), devices, name, picture, held: {name, picture}}, the
/// last three saying only whether there is one.
export async function standing(store, account) {
  const pk = `ACCOUNT#${account}`;
  const profile = await store.get(pk, 'PROFILE');
  const held = await store.get(pk, 'HELD');
  return {
    exists: !!(await store.get(pk, 'META')),
    suspended: (await store.get(pk, 'SUSPENDED'))?.since ?? null,
    devices: (await store.under(pk, 'DEVICE#')).length,
    name: !!profile?.name,
    picture: !!profile?.picture,
    held: { name: typeof held?.name === 'string', picture: typeof held?.picture === 'string' },
  };
}

/// In words, what [act] would do to the account [stands] describes
/// (standing, above).
export function wouldDo(act, stands, { name = false, picture = false } = {}) {
  switch (act) {
    case 'suspend':
      return stands.suspended
        ? `already suspended since ${stands.suspended}; its devices would be checked again and any in use cut off`
        : `would refuse its ${stands.devices} device(s) licences and activations, and cut the one in use off at the relay`;
    case 'lift':
      return stands.suspended ? `would let its ${stands.devices} device(s) back to live play, as each next opens the game` : 'not suspended: nothing to lift';
    case 'remove': {
      const parts = [...(name && stands.name ? ['name'] : []), ...(picture && stands.picture ? ['picture'] : [])];
      return parts.length ? `would take its ${parts.join(' and ')} off its profile, and hold them to put back` : 'nothing of that on its profile';
    }
    case 'restore': {
      const parts = Object.entries(stands.held).filter(([, h]) => h).map(([k]) => k);
      return parts.length ? `would put its ${parts.join(' and ')} back on its profile` : 'nothing held to put back';
    }
    default:
      return 'not an act';
  }
}

/// [act] carried out for [account] in its turn: the order written, with
/// KV's expiry, and the service asked until it has carried it out.
/// {status, body} as the service last answered, or the error the asking
/// ended on. [tries] asks, [wait] apart: a 404 or an unreachable
/// service is asked again, since KV takes a while to show a new row
/// everywhere; anything else is the answer.
export async function carry(store, account, act, options, { origin, fetchImpl = fetch, tries = 24, wait = 5000, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), now = Date.now() } = {}) {
  const id = hex(crypto.getRandomValues(new Uint8Array(16)));
  await store.put(...orderRow(id), orderOf(account, act, { ...options, now }), { ttl: ORDER_KEPT_S });
  let last = null;
  for (let i = 0; i < tries; i++) {
    if (i) await sleep(wait);
    try {
      const res = await fetchImpl(`${origin}/api/order`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ order: id }),
      });
      last = { status: res.status, body: await res.json().catch(() => null) };
    } catch (e) {
      last = { status: 0, body: { error: `${e?.message ?? e}` } };
    }
    if (last.status !== 404 && last.status !== 0 && last.status < 500) return last;
  }
  return last;
}

function fail(message, code = 2) {
  console.error(`suspend: ${message}`);
  process.exit(code);
}

async function main(argv) {
  const token = process.env.CLOUDFLARE_API_TOKEN;
  const cfAccount = process.env.CLOUDFLARE_ACCOUNT_ID;
  if (!token || !cfAccount) fail('needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID');
  const toml = await readFile(new URL('../do/wrangler.toml', import.meta.url), 'utf8');
  const namespace = /binding = "OH_STORE"\s*\nid = "([0-9a-f]+)"/.exec(toml)?.[1];
  if (!namespace) fail('no OH_STORE namespace id in service/do/wrangler.toml');
  const store = restStore({ token, account: cfAccount, namespace });

  const find = argv.indexOf('--find');
  if (find >= 0) {
    const asked = argv[find + 1];
    if (!asked) fail('--find takes a name or an email address');
    let said;
    try {
      said = await findAccounts(store, asked, { stripeKey: process.env.STRIPE_API_KEY ?? null });
    } catch (e) {
      fail(e.message, 1);
    }
    for (const note of said.notes) console.error(`suspend: ${note}`);
    for (const a of said.found) console.log(a);
    console.log(`${said.found.size} account(s)`);
    return;
  }

  const target = argv.find((a, i) => !a.startsWith('--') && argv[i - 1] !== '--remove');
  const account = await accountOf(store, target);
  if (!account) fail('name the account (32 hex) or one of its devices (64 hex), or --find a name or an email address');
  const acts = ['suspend', 'lift', 'remove', 'restore'].filter((a) => argv.includes(`--${a}`));
  if (acts.length > 1) fail('one act at a time');
  const act = acts[0] ?? null;
  const parts = act === 'remove' ? (argv[argv.indexOf('--remove') + 1] ?? '').split(',') : [];
  if (act === 'remove' && (!parts.length || parts.some((p) => p !== 'name' && p !== 'picture'))) fail('--remove takes name, picture, or name,picture');
  const options = { name: parts.includes('name'), picture: parts.includes('picture') };

  const stands = await standing(store, account);
  if (!stands.exists) fail(`no account ${account}`, 1);
  console.log(`${account}${target !== account ? ` (the account of ${target})` : ''}`);
  console.log(`  ${stands.suspended ? `suspended since ${stands.suspended}` : 'not suspended'}; ${stands.devices} device(s)`);
  console.log(`  profile: ${stands.name ? 'a name' : 'no name'}, ${stands.picture ? 'a picture' : 'no picture'}; held to put back: ${Object.entries(stands.held).filter(([, h]) => h).map(([k]) => k).join(' and ') || 'nothing'}`);
  if (!act) return;

  const bucket = restBucket({ token, account: cfAccount, bucket: pages.environments.production.r2.OH_RECORDS });
  console.log(`  ${wouldDo(act, stands, options)}`);
  if (act === 'remove' && options.name) {
    const games = await anonymizeGames(bucket, account, { dry: true });
    console.log(`  and would take its name off ${games.length} kept game(s)`);
  }
  if (!argv.includes('--apply')) {
    console.log('nothing changed; --apply does it');
    return;
  }
  const config = JSON.parse(await readFile(new URL('../../config/openhearts.json', import.meta.url), 'utf8'));
  const done = await carry(store, account, act, options, { origin: config.appOrigin });
  if (done?.status !== 200) fail(`the service said ${done?.status ?? 'nothing'}: ${done?.body?.error ?? ''}`, 1);
  console.log(`done: ${JSON.stringify(done.body)}`);
  if (act === 'remove' && options.name) {
    const games = await anonymizeGames(bucket, account);
    for (const { key, named } of games) console.log(`took the name off ${key}, seat ${named.join(', ')}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main(process.argv.slice(2));
}

