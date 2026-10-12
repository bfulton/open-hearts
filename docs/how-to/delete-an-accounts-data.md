# Delete an account's data on request

Use this guide when a person asks for their account's data to be deleted, as the privacy policy offers.

`service/tool/forget.mjs` forgets the account. It takes the account's name off every kept game it played (`anonymizeGames` in `service/functions/records.mjs`), and deletes every row the service keeps for it in `OH_STORE` (`forgetAccount` in `service/functions/worker.mjs`): its devices and their entitlements, its codes and backup codes, its sign-in, its device in use, its profile, and the rows of every subscription it has had. Its results stay on the relay, under its account number, which nothing left in the service ties to the person.

## Before you begin

- Install Node.
- Export `CLOUDFLARE_API_TOKEN`, with Workers KV Storage: Edit and Workers R2 Storage: Edit, and `CLOUDFLARE_ACCOUNT_ID`. The tool reads the production namespace's id from `service/do/wrangler.toml`, and the production bucket from `infra/cloudflare.mjs`.
- To find an account by the email address it paid with, export `STRIPE_API_KEY`, a live-mode key that can read customers and subscriptions.
- Run the commands from the repository root.

## Forget the account

1. Find the account. The privacy policy asks the person for the name they play under and, if they subscribed on the web, the email address they paid with. Give the tool either one:

   ```bash
   node service/tool/forget.mjs --find 'name@example.com'
   node service/tool/forget.mjs --find 'The Name They Play Under'
   ```

   It prints each account it finds, 32 hex characters each. An address finds the accounts behind the web subscriptions paid with it, and a name finds the accounts whose profile has that name. Text with an `@` in it is looked for both ways, since a name can have one. In either, case and the spaces at its ends don't count. If it finds more than one account, or none, ask the person for more before you go on. Set the account in your shell for the commands below:

   ```bash
   account=0123456789abcdef0123456789abcdef
   ```

1. Make sure the subscription is cancelled. The tool refuses an account whose subscription is still paid up and has no cancellation, since its next renewal would find nothing to renew. For a web subscription, cancel it in Stripe. A store subscription is cancelled by the person, in their store.
1. See what would change. Without `--apply`, the tool only reads:

   ```bash
   node service/tool/forget.mjs "$account"
   ```

   It prints a `would mark` line for the account, a `would take the name off` line for each kept game the account played, with its seats, and a `would delete` line for each row, by key. It reads every kept game, so it takes a while.

   If it stops with `would not be written back as it was sent`, the tool can't rewrite that game without changing how its events read. Don't go on; report it as a bug.

1. Forget the account:

   ```bash
   node service/tool/forget.mjs "$account" --apply
   ```

   The tool first marks the account forgotten in `OH_RECORDS`, as `forgotten/<account>`. A game kept from then on is kept without its name (`keepRecord` in `service/functions/records.mjs`): one that ends while the run goes, or one the account plays while its last licence runs. The games already kept go next, found by the licences at their seats, and then the rows. If the run stops part way, run it again. Forget one account at a time: two runs at once can each write back a game the other has just changed, putting a name back.

## What stays

- **The account's results on the relay.** A result names each seat's account number and device key, and never a name or an email. A result cannot be changed in any case: each copy is signed by the device that published it, and every player's copy names every seat.
- **Its kept games, without its name.** The moves stay, for the other players. A browser that opened a game before the run keeps its own copy.
- **Its `Household` object's note of the device in use**: the device's key, how many times the account was taken up, times, the table it last sat at, and the relay tags it opened since (the `active` entry of `Household` in `service/functions/worker.mjs`). Nothing outside the object can reach it. It is written over only when the account is taken up again, which after deletion never happens. It holds no name or picture.
- **Stripe's own record of a web subscription**, which holds the email address and, in the subscription's metadata, the paying device's key.
- Copies of results, records and table events that other people's devices keep, which the service cannot reach.

## Check it worked

1. Run the dry run again. It prints `forgotten/<account> is marked` and `0 game(s) and 0 row(s) to change; --apply changes them`. A game whose upload was checked a moment before the mark went in can still show up here; if one does, run `--apply` again:

   ```bash
   node service/tool/forget.mjs "$account"
   ```

1. Check that the name no longer finds the account:

   ```bash
   node service/tool/forget.mjs --find 'The Name They Play Under'
   ```

## Learn more

- [The service](../explanation/service.md#deleting-an-accounts-data): what the service keeps for an account, and why forgetting it leaves the results.
- [Service handlers and storage](../reference/service-api.md#storage): every row in `OH_STORE`, and how a game is kept.
