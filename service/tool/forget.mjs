// An account forgotten, on its owner's request (the privacy policy's
// choices; docs/how-to/delete-an-accounts-data.md): its name taken off
// the games it played, which stay the other players', and every row the
// service keeps for it deleted — its devices and their entitlements, its
// codes, its sign-in, its device in use, its profile — and those of
// every subscription it has had. Its results stay on the relay, under an account
// number nothing left in the service ties to it.
//
//   node service/tool/forget.mjs --find <name or email>   the accounts it names
//   node service/tool/forget.mjs <account>                what would change, and stop
//   node service/tool/forget.mjs <account> --apply        change it
//
// Refuses an account whose subscription is still paid up: that is
// cancelled first, or its next renewal would find nothing to renew.
//
// Needs CLOUDFLARE_API_TOKEN (Workers KV Storage: Edit, and Workers R2
// Storage: Edit) and CLOUDFLARE_ACCOUNT_ID; finding by an email address
// needs STRIPE_API_KEY too. Reads the namespace id from
// service/do/wrangler.toml (the production OH_STORE) and the bucket from
// infra/cloudflare.mjs (production's OH_RECORDS). Prints rows by key and
// games by key and seat, never a name, a code or a profile.

import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import { pages } from '../../infra/cloudflare.mjs';
import { anonymizeGames, forgottenKey } from '../functions/records.mjs';
import { accountsNamed, accountsPaidBy, forgetAccount } from '../functions/deletion.mjs';
import { dayOf, isAccount } from '../functions/rows.mjs';
import { restStore } from './kv.mjs';
import { restBucket } from './r2.mjs';

function fail(message, code = 2) {
  console.error(`forget: ${message}`);
  process.exit(code);
}

async function main(argv) {
  const token = process.env.CLOUDFLARE_API_TOKEN;
  const account = process.env.CLOUDFLARE_ACCOUNT_ID;
  if (!token || !account) fail('needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID');
  const toml = await readFile(new URL('../do/wrangler.toml', import.meta.url), 'utf8');
  const namespace = /binding = "OH_STORE"\s*\nid = "([0-9a-f]+)"/.exec(toml)?.[1];
  if (!namespace) fail('no OH_STORE namespace id in service/do/wrangler.toml');
  const store = restStore({ token, account, namespace });

  const find = argv.indexOf('--find');
  if (find >= 0) {
    const asked = argv[find + 1];
    if (!asked) fail('--find takes a name or an email address');
    // A name, always: one can have an @ in it. An address too, when it
    // could be one.
    const found = new Set(await accountsNamed(store, store.list, asked));
    if (asked.includes('@')) {
      const key = process.env.STRIPE_API_KEY;
      if (!key) {
        console.error('forget: not looked for as an email address, which needs STRIPE_API_KEY');
      } else {
        const stripe = async (path) => {
          const res = await fetch(`https://api.stripe.com/v1${path}`, { headers: { authorization: `Bearer ${key}` } });
          if (!res.ok) fail(`Stripe said ${res.status}`, 1);
          return res.json();
        };
        for (const a of await accountsPaidBy(store, stripe, asked)) found.add(a);
      }
    }
    for (const a of found) console.log(a);
    console.log(`${found.size} account(s)`);
    return;
  }

  const apply = argv.includes('--apply');
  const target = argv.find((a) => !a.startsWith('--'));
  if (!isAccount(target)) fail('name the account, 32 hex, or --find a name or an email address');
  const subscription = (await store.get(`ACCOUNT#${target}`, 'META'))?.subscription;
  const sub = typeof subscription === 'string' ? await store.get(`SUB#${subscription}`, 'META') : null;
  if (sub && !sub.cancelled_at && sub.renews_at && sub.renews_at >= dayOf(Date.now())) {
    fail(`${subscription} is still paid up to ${sub.renews_at}; cancel it first`, 1);
  }
  const bucket = restBucket({ token, account, bucket: pages.environments.production.r2.OH_RECORDS });
  // The mark first: a game kept from then on, one that ends while this
  // runs or that the account plays while its last licence runs, is kept
  // without its name (records.mjs, keepRecord). Then the games already
  // kept, by their seats' licences, and then the rows. A run that stops
  // part way is run again.
  const mark = forgottenKey(target);
  if (await bucket.get(mark)) {
    console.log(`${mark} is marked`);
  } else {
    if (apply) await bucket.put(mark, { forgotten: dayOf(Date.now()) });
    console.log(`${apply ? 'marked' : 'would mark'} ${mark}, for the games kept from then on`);
  }
  const games = await anonymizeGames(bucket, target, { dry: !apply });
  for (const { key, named } of games) console.log(`${apply ? 'took' : 'would take'} the name off ${key}, seat ${named.join(', ')}`);
  const rows = await forgetAccount(store, target, { dry: !apply, keys: store.list });
  // A household code is a code: its row is said, and not its name.
  for (const row of rows) console.log(`${apply ? 'deleted' : 'would delete'} ${row.replace(/^TICKET#[^|]+/, 'TICKET#…')}`);
  console.log(`${games.length} game(s) and ${rows.length} row(s) ${apply ? 'changed' : 'to change; --apply changes them'}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main(process.argv.slice(2));
}
