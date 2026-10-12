# Delete an account's data on request

Use this guide when a person asks for their account's data to be deleted, as the privacy policy offers.

`service/tool/forget.mjs` deletes every row the service keeps in `OH_STORE` for the account (`forgetAccount` in `service/functions/worker.mjs`): its devices and their entitlements, its codes and backup codes, its sign-in, its device in use, its profile, and its subscription's rows. Its finished games' records are deleted by hand.

## Before you begin

- Install Node.
- Export `CLOUDFLARE_API_TOKEN`, with Workers KV Storage: Edit, and `CLOUDFLARE_ACCOUNT_ID`. The tool reads the production namespace's id from `service/do/wrangler.toml`.
- Set `WRANGLER_VERSION` as [Deploy the site, app and service](deploy.md#before-you-begin) shows.
- Run the commands from the repository root.

## Delete the data

1. Find the account's id, 32 hex characters. For a subscription bought on the web, find it in Stripe from the email address the person paid with. The subscription's id starts with `sub_`. Then read the account it pays for:

   ```bash
   (cd service/do && npx wrangler@"$WRANGLER_VERSION" kv key get --binding OH_STORE --remote 'SUB#sub_…|ACCOUNT')
   ```

   The answer is `{"account": "…"}`. Set the id in your shell for the commands below:

   ```bash
   account=0123456789abcdef0123456789abcdef
   ```

   No tool yet finds the account of a person who subscribed in the App Store or Google Play, or who gives only the name they play under: the service keeps no row from a name to an account.

1. Make sure the subscription is cancelled. The tool refuses an account whose subscription is still paid up and has no cancellation, since its next renewal would find nothing to renew. For a web subscription, cancel it in Stripe. A store subscription is cancelled by the person, in their store.
1. See what would be deleted. Without `--apply`, the tool only reads:

   ```bash
   node service/tool/forget.mjs "$account"
   ```

   It prints a `would delete` line for each row, by key. Rows under `ACCOUNT#<account>|DEVICE#` name the account's device keys. Keep this output until you have finished, since the rows are gone after the next step.

1. Delete the rows:

   ```bash
   node service/tool/forget.mjs "$account" --apply
   ```

1. Delete the account's finished games from R2. Each record is `tables/<table id>.json` in the bucket `open-hearts-records` (`keyIn` in `service/functions/records.mjs`), and names the account in the licence of its seat. Delete each one, with `table` set to its table id:

   ```bash
   npx wrangler@"$WRANGLER_VERSION" r2 object delete "open-hearts-records/tables/$table.json" --remote
   ```

   No tool yet finds the tables an account played at: R2 keys records by table, and nothing indexes them by account.

1. Leave the account's results on the relay. A result names each seat's account number and device key, and never a name or an email. Once the rows above are deleted, nothing the service keeps ties that number to the person. A result cannot be changed in any case: each copy is signed by the device that published it, and every player's copy names every seat.

## What stays

- The account's `Household` object keeps its own note of the device in use: the device's key, how many times the account was taken up, times, the table it last sat at, and the relay tags it opened since (the `active` entry of `Household` in `service/functions/worker.mjs`). Nothing outside the object can reach it. It is written over only when the account is taken up again, which after deletion never happens. It holds no name or picture.
- The account's results on the relay, under its account number (above).
- Stripe's own record of a web subscription, which holds the email address and, in the subscription's metadata, the paying device's key.
- Copies of results, records and table events that other people's devices keep, which the service cannot reach.

## Check it worked

1. Run the dry run again. It prints `0 row(s) to delete; --apply deletes them`:

   ```bash
   node service/tool/forget.mjs "$account"
   ```

1. Check that the subscription no longer finds the account. The answer is `Value not found`:

   ```bash
   (cd service/do && npx wrangler@"$WRANGLER_VERSION" kv key get --binding OH_STORE --remote 'SUB#sub_…|ACCOUNT')
   ```

## Learn more

- [The service](../explanation/service.md#deleting-an-accounts-data): what the service keeps for an account, and why.
- [Service handlers and storage](../reference/service-api.md#storage): every row in `OH_STORE`.
