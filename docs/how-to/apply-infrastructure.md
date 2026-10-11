# Make Cloudflare, Stripe and New Relic match their definitions

Use this guide to check the Cloudflare, Stripe and New Relic accounts against their definitions in the repository, and to change the accounts where they differ.

The definitions are `infra/cloudflare.mjs`, `infra/stripe.mjs` and `observability/monitoring.mjs`. `infra/apply.mjs` and `observability/apply.mjs` compare the accounts with them. Both only read unless you add `--apply`.

## Before you begin

- Install Node, and run the commands from the repository root.
- Export the credentials for the accounts you check. For Cloudflare: `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. For Stripe: `STRIPE_API_KEY`, a live-mode key, since `infra/stripe.mjs` describes live mode and the script refuses a key of the other mode. For New Relic: `NEW_RELIC_API_KEY` (a User key), `NEW_RELIC_ACCOUNT_ID` and `NEW_RELIC_REGION`. For what each one and the optional `OH_HELP_FORWARD` and `OH_ALERT_EMAIL` do, see [environment variables](../reference/configuration.md#deploying-and-operating).
- If you are changing a definition, change the file first and run its tests, which need no network and no keys:

  ```bash
  node --test infra/*.test.mjs
  ```

- To fix `by hand:` lines with Wrangler, set `WRANGLER_VERSION` as [Deploy the site, app and service](deploy.md#before-you-begin) shows.
- If Node cannot verify TLS through a proxy, point `NODE_EXTRA_CA_CERTS` at the proxy's CA bundle. Never turn certificate checking off.

## Apply the Cloudflare and Stripe definitions

1. See what differs:

   ```bash
   node infra/apply.mjs
   ```

   To check one account only, add `--only cloudflare` or `--only stripe`.

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
   node infra/apply.mjs --apply
   ```

1. Fix each `by hand:` line. The common ones:

   - **The relay worker differs from `service/do/wrangler.toml`.** Deploy the relay worker, as [Deploy the site, app and service](deploy.md) shows.
   - **A Pages secret is not set.** Run the `npx wrangler pages secret put` command that the line gives, with `--project-name open-hearts`. For a secret of the preview environment, add `--env preview`, which the printed command leaves out.
   - **The relay's `OH_JUROR_SECRET` is not set.** In `service/do`, run `npx wrangler@"$WRANGLER_VERSION" secret put OH_JUROR_SECRET` and paste 64 hex characters, such as the output of `openssl rand -hex 32`. The backup jurors derive their keys from it, so a new value gives them new keys.
   - **No Stripe webhook, or one on another API version.** See [Register the payment and sign-in webhooks](set-up-webhooks.md#register-the-stripe-webhook).
   - **A spend alert or an email forward that needs an address.** Set `OH_ALERT_EMAIL` or `OH_HELP_FORWARD`, and run the script again.
   - **A DNS record that a Cloudflare feature makes is missing**, such as Email Routing's. Turn that feature on again in the dashboard.
   - **A setting only the dashboard can change**, such as Email Sending's onboarding or the customer portal's first save. Change it in the dashboard, where the line points.

1. Run the dry run again until it has no `would` and no `by hand:` lines.

## Apply the New Relic definition

1. See what differs:

   ```bash
   node observability/apply.mjs
   ```

1. Make the changes:

   ```bash
   node observability/apply.mjs --apply
   ```

   New Relic's search lags about a minute behind what is created, so wait a minute before you run `--apply` again, or it can create a monitor twice.

1. If the run wrote `app/web/observability.js` (the browser app's loader) or the licence notice beside it, commit both and deploy the site, as [Deploy the site, app and service](deploy.md) shows.

## Check it worked

1. Run both dry runs again. `infra/apply.mjs` ends with `0 change(s), 0 by hand`, and `observability/apply.mjs` with `0 change(s)`:

   ```bash
   node infra/apply.mjs
   node observability/apply.mjs
   ```

## Learn more

- [The service](../explanation/service.md#watching-it-run): what is monitored and why.
- [Configuration, secrets and bindings](../reference/configuration.md): every secret, binding and variable these definitions name.
