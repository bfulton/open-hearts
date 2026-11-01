# Delete an account's data on request

Use this guide when a person asks for their account's data to be deleted, as the privacy policy offers.

Most people don't need to ask: **Delete account**, at the foot of the app's subscription page, deletes the account from any of its devices at once, and the operator does nothing ([how it works](../explanation/service.md#deleting-an-accounts-data)). Point a person who asks to it. Use the command below when they can't, for example when they no longer have any of their devices.

`./oh account delete` forgets the account ([the oh command](../reference/oh.md)). It takes the account's name off every kept game it played (`anonymizeGames` in `service/functions/records.mjs`), and deletes every row the service keeps for it in `OH_STORE` (`forgetAccount` in `service/functions/deletion.mjs`): its devices and their entitlements, its codes and backup codes, its sign-in, its device in use, its profile, any suspension or name and picture held, and the rows of every subscription it has had, the notes that it was told of changes to the terms or the privacy policy among them, unless Stripe still runs it (below). Its results stay on the relay, under its account number, which nothing left in the service ties to the person.

## Before you begin

- Install Node.
- Export `CLOUDFLARE_API_TOKEN`, with Workers KV Storage: Edit and Workers R2 Storage: Edit, and `CLOUDFLARE_ACCOUNT_ID`. The command reads the production namespace's id from `service/do/wrangler.toml`, and the production bucket from `infra/cloudflare.mjs`.
- To find an account by the email address it paid with, export `STRIPE_API_KEY`, a live-mode key that can read customers and subscriptions.
- Run the commands from the repository root.

## Forget the account

1. Find the account. The privacy policy asks the person for the name they play under and, if they subscribed on the web, the email address they paid with. Give the command either one:

   ```bash
   ./oh account find 'name@example.com'
   ./oh account find 'The Name They Play Under'
   ```

   It prints each account it finds, 32 hex characters each. An address finds the accounts behind the web subscriptions paid with it, and a name finds the accounts whose profile has that name, or had it until the operator took it off. Text with an `@` in it is looked for both ways, since a name can have one. In either, case and the spaces at its ends don't count. If it finds more than one account, or none, ask the person for more before you go on. Set the account in your shell for the commands below:

   ```bash
   account=0123456789abcdef0123456789abcdef
   ```

1. Know what happens to the subscription. A web subscription still running, cancelled or not, is ended in Stripe by the command itself, as the app's own deletion ends it, before it deletes any row that names it: no more renewals, live play on its devices stops at the end of the day (UTC), and nothing is refunded. That needs `STRIPE_API_KEY`. If the person is owed a refund, make it first with `./oh account refund "$account" --apply`, which refunds the unused part of its year ([how](end-an-account.md#refund-a-web-subscription)). If Stripe does not answer, the command stops with nothing deleted, and is run again. A subscription bought in a store is the person's to cancel, in their store: the command refuses an account whose store subscription is still paid up and not cancelled. One that is cancelled but still runs to the end of its year keeps its notes of the changes it was told of, so that `./oh terms notify` does not write to the person about them again; a change published after the deletion is one it has no note of, and `./oh terms notify --apply` writes to its subscriber about it, as to any other. An account under a legal hold is refused before anything is ended or changed.

1. See what would change. Without `--apply`, the command only reads:

   ```bash
   ./oh account delete "$account"
   ```

   It prints a `would mark` line for the account, a `would take the name off` line for each kept game the account played, with its seats, and a `would delete` line for each row, by key. It reads every kept game, so it takes a while.

   If it stops with `would not be written back as it was sent`, the command can't rewrite that game without changing how its events read. Don't go on; report it as a bug.

1. Forget the account:

   ```bash
   ./oh account delete "$account" --apply
   ```

   The command first marks the account forgotten in `OH_RECORDS`, as `forgotten/<account>`. A game kept from then on is kept without its name (`keepRecord` in `service/functions/records.mjs`): one that ends while the run goes, or one the account plays while its last licence runs. The games already kept go next, found by the licences at their seats, and then the rows. If the run stops part way, run it again. Forget one account at a time: two runs at once can each write back a game the other has just changed, putting a name back.

## What stays

- **The account's results on the relay.** A result names each seat's account number and device key, and never a name or an email. A result cannot be changed in any case: each copy is signed by the device that published it, and every player's copy names every seat.
- **Its kept games, without its name.** The moves stay, for the other players. A browser that opened a game before the run keeps its own copy.
- **Its `Household` object's note of the device in use**: the device's key, how many times the account was taken up, times, the table it last sat at, the relay tags it opened since, and whether the account was suspended (the `active` entry of `Household` in `service/functions/household.mjs`). Nothing outside the object can reach it. It is written over only when the account is taken up again, which after deletion never happens. It holds no name or picture.
- **Stripe's own record of a web subscription**, which holds the email address and, in the subscription's metadata, the paying device's key.
- **The notes of a store subscription that is cancelled but still runs**, a `NOTICE#` row for each change it was told of in the terms or the privacy policy, with the day it was told and its language. They stay after the subscription ends. A web subscription's go with the rest, since the command ends it.
- Copies of results, records and table events that other people's devices keep, which the service cannot reach.

A deletion from the app leaves less in the `Household` object (only how many times the account was taken up) and, once Stripe tells the service the subscription ended, a `SUB#` row saying so, with no customer and no account.

## A game that cannot be rewritten

An email with the subject **Open Hearts: a deleted account's name is still on a kept game** says that an account was deleted from the app, and names each kept game its name could not be taken off. The rest of the deletion went ahead. `JSON.stringify` would not write those records back as they were sent, so nothing rewrites them, `./oh account delete` included. The app never makes such a record.

Look at each one, and delete it from the bucket if it holds the name:

```bash
ops/wrangler/wrangler r2 object get "open-hearts-records/tables/<table>.json" --remote --pipe | gunzip
ops/wrangler/wrangler r2 object delete "open-hearts-records/tables/<table>.json" --remote
```

Its players can no longer look at the game afterwards; their own devices keep their copies.

## Check it worked

1. Run the dry run again. It prints `forgotten/<account> is marked` and `0 game(s) and 0 row(s) to change; --apply changes them`. A game whose upload was checked a moment before the mark went in can still show up here; if one does, run `--apply` again:

   ```bash
   ./oh account delete "$account"
   ```

1. Check that the name no longer finds the account:

   ```bash
   ./oh account find 'The Name They Play Under'
   ```

## Learn more

- [The service](../explanation/service.md#deleting-an-accounts-data): what the service keeps for an account, and why forgetting it leaves the results.
- [Service handlers and storage](../reference/service-api.md#storage): every row in `OH_STORE`, and how a game is kept.
