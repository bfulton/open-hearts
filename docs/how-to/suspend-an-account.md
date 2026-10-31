# Suspend an account, or take its name or picture off

Use this guide when an account breaks the terms at a live table, when a copyright notice is complete, or to undo either. The terms allow each act in their sections "At a live table" and "Copyright". To end an account for good, or to refund it, see [End an account, or refund a subscription](end-an-account.md).

| Command | What it does |
|---|---|
| `./oh account suspend` | Suspends the account from live play at once, and stops its web subscription renewing. Its devices get no licence and no activation, and the one in use is cut off at the relay. |
| `./oh account lift` | Lifts the suspension. Each device gets its licence again the next time the app asks for one, and a renewal the suspension stopped starts again. |
| `./oh account remove <account> name`, `picture` or `name,picture` | Takes the name, the picture or both off the account's profile, and holds them so that they can be put back. Taking the name off also takes it off every kept game the account played. |
| `./oh account restore` | Puts back what `remove` held. A name taken off kept games stays off them. |

The command doesn't change the account itself. It writes an order into `OH_STORE`, and asks the service to carry it out in the account's turn, where the account's device in use is known ([how it works](../explanation/service.md#suspending-an-account)). What happens in Stripe, it does itself.

## Before you begin

- Install Node.
- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. The token needs Workers KV Storage: Edit, and, to take a name off kept games, Workers R2 Storage: Edit. The command reads the production namespace's ID from `service/do/wrangler.toml`, the production bucket from `infra/cloudflare.mjs`, and the service's address from `appOrigin` in `config/openhearts.json`.
- Export `STRIPE_API_KEY`, a live-mode key that can read Customers and Invoices and write Subscriptions. Suspending or lifting an account with a web subscription needs it, and so does finding an account by the email address it paid with.
- Run the commands from the repository root.

## Find the account

1. Find the account by the name it plays under, or by the email address its web subscription was paid with:

   ```bash
   ./oh account find 'The Name They Play Under'
   ```

   It finds accounts by a name they play under, by a name that was taken off and is held, and, with `STRIPE_API_KEY`, by the email address of a web subscription. If you have one of the account's device keys instead, 64 hex characters from a kept game or a result, use it in place of the account below: the command finds its account.

   Set the account in your shell for the commands below:

   ```bash
   account=0123456789abcdef0123456789abcdef
   ```

1. See how the account stands:

   ```bash
   ./oh account show "$account"
   ```

   It prints whether the account is suspended or terminated, and since what day; how many devices it has; whether its profile has a name and a picture; and what is held to put back. It never prints a name or a picture. For an account that doesn't exist, it prints `no account` and stops.

Each act below prints what it would do and changes nothing. Run it again with `--apply` to do it. With `--apply`, the command asks the service every 5 seconds, for up to 2 minutes, until the order has reached it: KV can take up to a minute to show a new row everywhere. It prints `done:` and the service's answer. If it prints `the service said 0`, it never reached the service: check `appOrigin` and your network, and run it again. Running an act twice ends the same way as running it once.

## Suspend the account

1. See what it would do:

   ```bash
   ./oh account suspend "$account"
   ```

   For a web subscription, it also says how the subscription stands in Stripe, and that it would stop it renewing. For a subscription bought in a store, it says what to do there by hand.

1. Suspend it:

   ```bash
   ./oh account suspend "$account" --apply
   ```

   The answer is `{"act":"suspend","suspended":true,"flagged":<devices>,"cutOff":<true or false>}`. `cutOff` is `true` when a device was in use and its sockets at the relay were closed. Then it stops the web subscription renewing, and marks it in Stripe as stopped by the suspension (`oh_stopped: suspended`). A subscription the subscriber already cancelled is left as it is.

What the account's devices do then:

- **The device in use** leaves live play at once: its table, where a bot takes its seat, scored as a leave in a rated game; the pool or room it waits in; and any game it watches. A device the relay's word misses hears it at its next renewal, within 20 minutes, or the next time it connects to the relay.
- **Every device** gets no licence. Where the app sells live play, it says instead that the account is suspended from live play, and to email `help@openhearts.game` to ask why or to appeal. Playing alone works as before.
- **A device brought into the account later** is suspended too. A subscription that one of its devices buys stays with the suspended account.

## Lift the suspension

```bash
./oh account lift "$account" --apply
```

The answer is `{"act":"lift","suspended":false,"unflagged":<devices>}`. Each device gets its licence again the next time the app asks for one, which it does each time it starts. If the suspension stopped the web subscription renewing, it renews again; if the subscriber cancelled it, it stays cancelled. A terminated account isn't lifted: the command refuses.

## Take a name or picture off

1. See what it would do. Name what to take off: `name`, `picture`, or `name,picture`:

   ```bash
   ./oh account remove "$account" name
   ```

   For a name, it also prints how many kept games the account played, which the name comes off. It reads every kept game, so it takes a while.

1. Take it off:

   ```bash
   ./oh account remove "$account" name --apply
   ```

   The answer is `{"act":"remove","removed":["name"]}`. Then, for a name, the command prints a `took the name off` line for each kept game, with its seats.

The account's device in use takes the change at its next renewal, within 20 minutes, and its other devices take it when they next start: no name, and the icon in place of the picture.

A picture taken off is also withheld at the relay, wherever it was put out, within a couple of minutes: no pool or room serves it again, and a device that puts it out again isn't carried. It stays withheld for 30 days, or until it is put back. A name the relay already holds stays there, with the room or seating it was published in, for up to a day. Copies that other players' devices already received stay on those devices.

For a copyright notice, the terms say the person who published it is told.

The player can choose a new name or picture. If it breaks the terms too, take it off again or suspend the account. What is held is what the latest removal took.

## Put a name or picture back

After a counter-notice, the terms' "Copyright" section says when the material goes back. Then:

```bash
./oh account restore "$account" --apply
```

The answer is `{"act":"restore","restored":["name","picture"]}`, naming what went back. It reaches the account's devices as a removal does, and a picture put back is no longer withheld at the relay.

## What a suspension doesn't do

- **It doesn't end the subscription or refund it.** It stops a web subscription renewing, so that it runs out at the end of what was paid for. If the suspension was without a good reason, the terms promise a refund of the unused part of a web subscription: see [End an account, or refund a subscription](end-an-account.md#refund-a-web-subscription). A store subscription renews and refunds under the store's rules.
- **It doesn't stop a new account.** An account is a number tied to device keys and payments, not to a person. A device with a new key, or one dropped from the account, can subscribe again as a new account; only checking who people are could stop that. An account paid for on the web with the same address is found by `./oh account find` with that address.
- **It doesn't take back what was published**: results on the relay, kept games, and copies that other devices keep.
- **It isn't deletion.** To delete an account's data, see [Delete an account's data on request](delete-an-accounts-data.md), which also deletes the suspension and anything held.

## Check it worked

```bash
./oh account show "$account"
```

It prints `suspended since <day>` after a suspension, `not suspended` after a lift, and, after `remove` or `restore`, the profile and what is held.

## Learn more

- [The service](../explanation/service.md#suspending-an-account): why the account's own turn carries the order out, and how the relay and the app hear it.
- [Service handlers and storage](../reference/service-api.md#storage): the rows a suspension and a removal keep.
- [The oh command](../reference/oh.md)
