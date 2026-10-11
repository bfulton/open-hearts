// An account's data deleted, on its owner's request (the privacy
// policy's choices; docs/06-service.md): every row the service keeps for
// it — its devices and their entitlements, its codes, its sign-in, its
// device in use, its profile — and its subscription's.
//
//   node service/tool/forget.mjs <account>            what would go, and stop
//   node service/tool/forget.mjs <account> --apply    delete it
//
// Refuses an account whose subscription is still paid up: that is
// cancelled first, or its next renewal would find nothing to renew.
// What else is kept for the account is deleted where it lives: its
// finished games' records in R2, and its results on the relay
// (docs/08-own-relays.md).
//
// Needs CLOUDFLARE_API_TOKEN (Workers KV Storage: Edit) and
// CLOUDFLARE_ACCOUNT_ID, and reads the namespace id from
// service/do/wrangler.toml (the production OH_STORE). Prints the rows,
// which name keys and digests, never a code or a profile.

import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import { dayOf, forgetAccount, isAccount } from '../functions/worker.mjs';
import { restStore } from './kv.mjs';

async function main(argv) {
  const apply = argv.includes('--apply');
  const target = argv.find((a) => !a.startsWith('--'));
  if (!isAccount(target)) {
    console.error('forget: name the account, 32 hex');
    process.exit(2);
  }
  const token = process.env.CLOUDFLARE_API_TOKEN;
  const account = process.env.CLOUDFLARE_ACCOUNT_ID;
  if (!token || !account) {
    console.error('forget: needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID');
    process.exit(2);
  }
  const toml = await readFile(new URL('../do/wrangler.toml', import.meta.url), 'utf8');
  const namespace = /binding = "OH_STORE"\s*\nid = "([0-9a-f]+)"/.exec(toml)?.[1];
  if (!namespace) {
    console.error('forget: no OH_STORE namespace id in service/do/wrangler.toml');
    process.exit(2);
  }
  const store = restStore({ token, account, namespace });
  const subscription = (await store.get(`ACCOUNT#${target}`, 'META'))?.subscription;
  const sub = typeof subscription === 'string' ? await store.get(`SUB#${subscription}`, 'META') : null;
  if (sub && !sub.cancelled_at && sub.renews_at && sub.renews_at >= dayOf(Date.now())) {
    console.error(`forget: ${subscription} is still paid up to ${sub.renews_at}; cancel it first`);
    process.exit(1);
  }
  const rows = await forgetAccount(store, target, { dry: !apply });
  // A household code is a code: its row is said, and not its name.
  for (const row of rows) console.log(`${apply ? 'deleted' : 'would delete'} ${row.replace(/^TICKET#[^|]+/, 'TICKET#…')}`);
  console.log(`${rows.length} row(s) ${apply ? 'deleted' : 'to delete; --apply deletes them'}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main(process.argv.slice(2));
}
