# Make Cloudflare, Stripe and New Relic match their definitions

Use this guide to check the Cloudflare, Stripe and New Relic accounts against their definitions in the repository, and to change the accounts where they differ.

The definitions are `infra/cloudflare.mjs`, `infra/stripe.mjs` and `observability/monitoring.mjs`. `./oh infra` compares the accounts with them, through `infra/apply.mjs` and `observability/apply.mjs`. It only reads unless you add `--apply`.

## Before you begin

- Install Node, and run the commands from the repository root.
- Export the credentials for the accounts you check. For Cloudflare: `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. For Stripe: `STRIPE_API_KEY`, a live-mode key, since `infra/stripe.mjs` describes live mode and the script refuses a key of the other mode. For New Relic: `NEW_RELIC_API_KEY` (a User key), `NEW_RELIC_ACCOUNT_ID` and `NEW_RELIC_REGION`. For what each one and the optional `OH_HELP_FORWARD` and `OH_ALERT_EMAIL` do, see [environment variables](../reference/configuration.md#deploying-and-operating).
- If you are changing a definition, change the file first and run its tests, which need no network and no keys:

  ```bash
  node --test infra/*.test.mjs
  ```

- If Node cannot verify TLS through a proxy, point `NODE_EXTRA_CA_CERTS` at the proxy's CA bundle. Never turn certificate checking off.

## Apply the Cloudflare and Stripe definitions

1. See what differs:

   ```bash
   ./oh infra --only cloudflare
   ./oh infra --only stripe
   ```

   Without `--only`, `./oh infra` checks Cloudflare, Stripe and New Relic in turn ([the oh command](../reference/oh.md)).

   Each line is one of these kinds:

   | Line | Meaning |
   |---|---|
   | `would …` | A change that `--apply` makes. |
   | `by hand:` | A difference that you fix yourself. The line says how. |
   | `unread:` | Something the credentials could not read, in the API's own words. The run exits with 1. |
   | `ok` | A part that matches. |
   | `note:` | Something the script cannot check. |

   No secret or email address is printed: the variables that hold them are named instead.

1. Make the changes:

   ```bash
   ./oh infra --only cloudflare --apply
   ./oh infra --only stripe --apply
   ```

1. Fix each `by hand:` line. The common ones:

   - **The relay worker differs from `service/do/wrangler.toml`.** Deploy the relay worker, as [Deploy the site, app and service](deploy.md) shows.
   - **A Pages secret is not set.** Run the `./oh secret set` command that the line gives. It asks for the value, which isn't shown, and sets it in every environment that `infra/cloudflare.mjs` lists it in.
   - **The relay's `OH_JUROR_SECRET` is not set.** Run `./oh secret set OH_JUROR_SECRET --apply` and paste 64 hex characters, such as the output of `openssl rand -hex 32`. The backup jurors derive their keys from it, so a new value gives them new keys.
   - **No Stripe webhook, or one on another API version.** See [Register the payment and sign-in webhooks](set-up-webhooks.md#register-the-stripe-webhook).
   - **A spend alert or an email forward that needs an address.** Set `OH_ALERT_EMAIL` or `OH_HELP_FORWARD`, and run the script again.
   - **A DNS record that a Cloudflare feature makes is missing**, such as Email Routing's. Turn that feature on again in the dashboard.
   - **A setting only the dashboard can change**, such as Email Sending's onboarding or the customer portal's first save. Change it in the dashboard, where the line points.

1. Once, before the first deploy that sells through Link: in Stripe's Dashboard, under **Settings** > **Managed Payments**, apply for Managed Payments, accept its terms, and turn it on once Stripe approves the account. No API reports it, so `./oh infra` can't; `./oh verify` proves it by making a checkout through Link and expiring it. Until it's on, every web checkout fails, because the service sells only through Link.

1. Run the dry run again until it has no `would` and no `by hand:` lines.

## Apply the New Relic definition

1. See what differs:

   ```bash
   ./oh infra --only newrelic
   ```

1. Make the changes:

   ```bash
   ./oh infra --only newrelic --apply
   ```

   New Relic's search lags about a minute behind what is created, so wait a minute before you run `--apply` again, or it can create a monitor twice.

1. If the run wrote `app/web/observability.js` (the browser app's loader) or the licence notice beside it, commit both and deploy the site, as [Deploy the site, app and service](deploy.md) shows.

## Check it worked

1. Run the dry run again. The Cloudflare and Stripe part ends with `0 change(s), 0 by hand`, and the New Relic part with `0 change(s)`:

   ```bash
   ./oh infra
   ```

## Learn more

- [The service](../explanation/service.md#watching-it-run): what is monitored and why.
- [Configuration, secrets and bindings](../reference/configuration.md): every secret, binding and variable these definitions name.
