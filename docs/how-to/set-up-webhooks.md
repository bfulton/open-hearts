# Register the payment and sign-in webhooks

Use this guide to point Stripe, Sign in with Apple, the App Store and Google Play at the service's handlers, which they notify when a payment or a sign-in changes.

| Sender | Address | Handler checks |
|---|---|---|
| Stripe | `https://play.openhearts.game/api/stripe` | The `Stripe-Signature` header, against `OH_STRIPE_WEBHOOK_SECRET`. |
| Sign in with Apple | `https://play.openhearts.game/api/apple-id` | Apple's signature on the notice, and that it is for one of the app's Apple identifiers. |
| App Store | `https://play.openhearts.game/api/apple` | The App Store's signature, and that it is for `apple.bundleId` in `config/openhearts.json`. |
| Google Play | `https://play.openhearts.game/api/play` | A Google ID token from Pub/Sub, for the audience and service account that `config/openhearts.json` names. |

These four addresses are left out of the rate limit on `/api/` (`infra/cloudflare.mjs`).

## Before you begin

- Install Node, export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, and set `WRANGLER_VERSION` as [Deploy the site, app and service](deploy.md#before-you-begin) shows.
- Make sure the identifiers each handler needs are in `config/openhearts.json` and deployed: `apple` for the two Apple handlers, and `google` for Google Play. Without them, the Apple handlers answer 503, and the Play handler turns every push away with 401. For the fields, see [`config/openhearts.json`](../reference/configuration.md#configopenheartsjson).
- For Sign in with Apple, make sure the Pages secret `OH_ID_HMAC` is set. For Google Play, `OH_PLAY_SERVICE_ACCOUNT` must be set, so that the service can ask Play about a purchase. See [Pages project secrets](../reference/configuration.md#pages-project-secrets).
- Run the commands from the repository root.

## Register the Stripe webhook

1. In the Stripe dashboard, in live mode, add a webhook endpoint at `https://play.openhearts.game/api/stripe`. Give it the API version and the events that `webhooks` in `infra/stripe.mjs` names. Stripe sets an endpoint's API version only when the endpoint is made.
1. Copy the endpoint's signing secret, which Stripe shows once, and set it as a secret on the Pages project's production environment. It asks for the value, which isn't shown as you paste it. Previews have no Stripe, so it is set on production only.

   ```bash
   ./oh secret set OH_STRIPE_WEBHOOK_SECRET --apply
   ```

1. Deploy the site, so that the live deployment is one made after the secret was set. See [Deploy the site, app and service](deploy.md).
1. If this endpoint replaces one on an older API version, delete the old endpoint in the dashboard.

From here on, `./oh infra --only stripe --apply` keeps the endpoint's events and enabled state as `infra/stripe.mjs` defines them.

## Register the Sign in with Apple notifications

1. On Apple's developer site, open Certificates, Identifiers & Profiles, then Identifiers, then the App ID `game.openhearts`.
1. Under Sign In with Apple, select Edit, and set the Server-to-Server Notification Endpoint to `https://play.openhearts.game/api/apple-id`.
1. Save.

## Register the App Store Server Notifications

1. In App Store Connect, open the app's App Information.
1. Under App Store Server Notifications, set the Production Server URL to `https://play.openhearts.game/api/apple`, and choose Version 2. The handler reads only Version 2 notifications.

## Register Google Play's real-time developer notifications

1. In Google Cloud, create a Pub/Sub topic for the notifications, and give `google-play-developer-notifications@system.gserviceaccount.com` the Pub/Sub Publisher role on it.
1. Create a push subscription on the topic to `https://play.openhearts.game/api/play`, with authentication on. Choose the service account it pushes as, and an audience.
1. Put the service account's email in `config/openhearts.json` as `google.playPushEmail`, and the audience as `google.playPushAudience`. The handler accepts a push only when the token's `email` and `aud` match these (`pushedByPlay` in `service/functions/stores.mjs`). Commit the change to `main`, and deploy the site.
1. In the Google Play Console, under the app's monetization setup, turn on real-time notifications and enter the topic's full name.

## Check it worked

1. Check that each address reaches its handler. Each answers an unsigned request with an error that names what is missing, rather than a 404:

   ```bash
   curl -s -X POST https://play.openhearts.game/api/stripe -d '{}'
   curl -s -X POST https://play.openhearts.game/api/apple-id -d '{}'
   curl -s -X POST https://play.openhearts.game/api/apple -d '{}'
   curl -s -X POST https://play.openhearts.game/api/play -d '{}'
   ```

   The first three answer `{"error":"not signed"}` and the last `{"error":"not Play"}`. An answer that says something is not set up yet means the handler's identifiers are not in the deployed config.

1. For Stripe, check that the endpoint matches its definition. The line for the webhook starts with `ok`:

   ```bash
   ./oh infra --only stripe
   ```

   In the Stripe dashboard, the endpoint's deliveries answer 200. A 400 with `not signed` means `OH_STRIPE_WEBHOOK_SECRET` is not this endpoint's signing secret.

1. For Google Play, send a test notification from the Play Console. In Google Cloud, the push subscription shows it delivered. A 401 means the token's audience or service account does not match `config/openhearts.json`.

## Learn more

- [The service](../explanation/service.md#payment): how each store's notifications change a subscription.
- [The service](../explanation/service.md#when-apple-says-a-sign-in-is-gone): what a Sign in with Apple notification does.
- [Security model](../explanation/security-model.md#payments): how each notification is verified.
