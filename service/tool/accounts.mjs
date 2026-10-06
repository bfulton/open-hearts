// Every subscription from before accounts, made an account
// (docs/06-service.md): its devices, each device's row and its backup
// codes moved under a new account, and nothing else touched.
//
//   node service/tool/accounts.mjs            what would move, and stop
//   node service/tool/accounts.mjs --apply    move it
//
// Run at the deploy that brings accounts in, before the worker that
// knows them goes live. The worker moves any subscription it meets that
// this has not — one whose device the old worker added after this ran —
// in the subscription's own turn, the same way, so running this is
// what makes the move happen at the deploy rather than as each one is
// next touched. Running it twice moves nothing the second time.
//
// Needs CLOUDFLARE_API_TOKEN (Workers KV Storage: Edit) and
// CLOUDFLARE_ACCOUNT_ID, and reads the namespace id from
// service/do/wrangler.toml (the production OH_STORE). Prints counts and
// subscription ids, never a key or a code.

import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import { accountFor } from '../functions/worker.mjs';

/// Moves every subscription in [store] that has no account yet: the
/// store's own calls (get, put, del, under) and [subscriptions], every
/// subscription id it holds. Returns how many it moved.
export async function migrateAll(store, { say = console.log, now = Date.now(), dry = false, subscriptions = null } = {}) {
  const ids = subscriptions ?? (await subscriptionsIn(store));
  let moved = 0;
  for (const subscription of ids) {
    if ((await store.get(`SUB#${subscription}`, 'ACCOUNT'))?.account) continue;
    const devices = (await store.under(`SUB#${subscription}`, 'DEVICE#')).length;
    const codes = !!(await store.get(`SUB#${subscription}`, 'BACKUP'));
    if (devices === 0 && !codes) continue;
    moved++;
    say(`${dry ? 'would move' : 'moving'} ${subscription}: ${devices} device(s)${codes ? ', backup codes' : ''}`);
    if (!dry) await accountFor(store, subscription, { now });
  }
  return moved;
}

/// The subscription ids a store's rows name, for a store that can list
/// them (the tests' memoryStore).
async function subscriptionsIn(store) {
  const ids = new Set();
  for (const k of store.rows?.keys() ?? []) {
    const m = /^SUB#([^|]+)\|/.exec(k);
    if (m) ids.add(m[1]);
  }
  return [...ids];
}

/// OH_STORE through Cloudflare's API, behind the calls the worker's
/// store makes (service/functions/worker.mjs, storeOf).
function restStore({ token, account, namespace }) {
  const base = `https://api.cloudflare.com/client/v4/accounts/${account}/storage/kv/namespaces/${namespace}`;
  const auth = { authorization: `Bearer ${token}` };
  const at = (pk, sk) => encodeURIComponent(`${pk}|${sk}`);
  const list = async (prefix) => {
    const names = [];
    let cursor = '';
    do {
      const res = await fetch(`${base}/keys?prefix=${encodeURIComponent(prefix)}&limit=1000${cursor ? `&cursor=${cursor}` : ''}`, { headers: auth });
      const page = await res.json();
      if (!page.success) throw new Error(`listing said ${res.status}`);
      for (const { name } of page.result) names.push(name);
      cursor = page.result_info?.cursor ?? '';
    } while (cursor);
    return names;
  };
  return {
    list,
    async get(pk, sk) {
      const res = await fetch(`${base}/values/${at(pk, sk)}`, { headers: auth });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`reading said ${res.status}`);
      return res.json();
    },
    async put(pk, sk, value) {
      const res = await fetch(`${base}/values/${at(pk, sk)}`, { method: 'PUT', headers: { ...auth, 'content-type': 'application/json' }, body: JSON.stringify(value) });
      if (!res.ok) throw new Error(`writing said ${res.status}`);
    },
    async del(pk, sk) {
      const res = await fetch(`${base}/values/${at(pk, sk)}`, { method: 'DELETE', headers: auth });
      if (!res.ok && res.status !== 404) throw new Error(`deleting said ${res.status}`);
    },
    async under(pk, prefix) {
      return (await list(`${pk}|${prefix}`)).map((n) => n.slice(`${pk}|`.length));
    },
  };
}

async function main(argv) {
  const apply = argv.includes('--apply');
  const token = process.env.CLOUDFLARE_API_TOKEN;
  const account = process.env.CLOUDFLARE_ACCOUNT_ID;
  if (!token || !account) {
    console.error('accounts: needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID');
    process.exit(2);
  }
  const toml = await readFile(new URL('../do/wrangler.toml', import.meta.url), 'utf8');
  const namespace = /binding = "OH_STORE"\s*\nid = "([0-9a-f]+)"/.exec(toml)?.[1];
  if (!namespace) {
    console.error('accounts: no OH_STORE namespace id in service/do/wrangler.toml');
    process.exit(2);
  }
  const store = restStore({ token, account, namespace });
  const subscriptions = [...new Set((await store.list('SUB#')).map((n) => n.slice('SUB#'.length).split('|')[0]))];
  const moved = await migrateAll(store, { dry: !apply, subscriptions });
  console.log(`${moved} subscription(s) ${apply ? 'moved' : 'to move; --apply moves them'}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main(process.argv.slice(2));
}
