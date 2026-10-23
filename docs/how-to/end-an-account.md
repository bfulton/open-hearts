# End an account, or refund a subscription

Use this guide to end an account under the terms ("Ending these terms"), or to refund a web subscription. To suspend an account for now, or to take a name or picture off, see [Suspend an account](suspend-an-account.md) instead.

| Command | What it does |
|---|---|
| `./oh account terminate` | Suspends the account for good, ends its web subscription now, and refunds the unused part of its year, unless the breach was serious. A terminated account can't be lifted. |
| `./oh account refund` | Refunds a web subscription and ends it now: the unused part of its year, or all of its last payment with `--full`. The account itself isn't suspended. |

Both say what they would do and change nothing without `--apply` ([the oh command](../reference/oh.md)).

## Before you begin

- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, as [Suspend an account](suspend-an-account.md#before-you-begin) describes.
- Export `STRIPE_API_KEY`: a live-mode key that can write Subscriptions and Refunds, and read Invoices and Customers. The commands read Stripe in the API version the service's webhook uses (`apiVersion` in `infra/stripe.mjs`).
- Find the account, as [Suspend an account](suspend-an-account.md#find-the-account) shows, and set it in your shell:

  ```bash
  account=0123456789abcdef0123456789abcdef
  ```

## Terminate an account

The terms let us end an account that seriously or repeatedly breaks them, or when the law requires it. A suspension is for while you look into something; a termination is the decision.

1. See what it would do:

   ```bash
   ./oh account terminate "$account"
   ```

   It says how the account stands, how its subscription stands in Stripe (paid to which day, the last payment, anything already refunded), and the refund it would make: the unused part of the year, to the cent.

1. Decide whether the breach was serious. The terms refund the unused part of a web subscription unless the account was ended for a serious breach, such as cheating, harassment, illegal content or fraud. For a serious breach, add `--serious`, and nothing is refunded.

1. Terminate it:

   ```bash
   ./oh account terminate "$account" --apply
   ```

   In this order, it:

   1. Suspends the account in its turn and marks it terminated (`{"act":"terminate",…,"terminated":"<day>"}`). Its device in use is cut off at the relay at once, and no device of it gets a licence or an activation again.
   1. Ends the web subscription in Stripe now. Stripe tells the service, which cuts every device's licence to the day.
   1. Refunds the unused part of the year to the payment method it was paid with, marked in Stripe as `oh_act: terminate`.

   If it stops part way, run it again: each step that is done is skipped, and a refund already made isn't made twice.

1. If the subscription was bought in a store, the command says so and changes nothing there:

   - **App Store:** we can't cancel or refund it. Tell the subscriber to cancel in the App Store and to ask Apple for a refund at [reportaproblem.apple.com](https://reportaproblem.apple.com/).
   - **Google Play:** cancel and refund it in the Play Console, under Order management.

## Refund a web subscription

A refund always ends the subscription: the terms say so, so that no device goes on playing on money that was given back.

1. See what it would do:

   ```bash
   ./oh account refund "$account"
   ```

   Without `--full`, it refunds the unused part of the year. With `--full`, it refunds all of the last payment that hasn't been refunded yet.

1. Refund it:

   ```bash
   ./oh account refund "$account" --apply
   ```

   It ends the subscription in Stripe now, then refunds, marked in Stripe as `oh_act: refund`. Live play on the account's devices stops at the end of that day (UTC).

Refund through `./oh`, which refunds the unused part of the year and marks the refund with what made it. A refund made anywhere else, in Stripe's dashboard or by Link's support, ends the subscription too, when the service hears of it (`endRefunded` in `service/functions/stripe.mjs`), but refunds what whoever made it chose.

## Check it worked

1. See how the account stands now:

   ```bash
   ./oh account show "$account"
   ```

   After a termination, it says `terminated on <day>`.

1. In Stripe's dashboard, the subscription is canceled, and the payment shows the refund with its `oh_act` metadata.

## Learn more

- [Suspend an account, or take its name or picture off](suspend-an-account.md)
- [The service](../explanation/service.md#suspending-an-account): how an act is carried out in the account's turn.
