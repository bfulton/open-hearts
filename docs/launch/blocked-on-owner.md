# Blocked on the owner

What launch is waiting on that only the owner can do: an account, a
setting, a decision, a signature. Kept current as the work goes; each
item says what it unblocks and where the detail is. Done items move to
the bottom with the day.

## Decisions and review

- **Review the terms** (`site/terms.html`) — with a lawyer if possible.
  The draft promises things nobody asked for: a pro-rata refund if we
  stop renewing a device without good reason; notice before a price
  change; liability capped at the past year's payments or $5; notice
  before live play is ended; "no modified copy called Open Hearts".
  It names no legal entity. Open questions it raises: a mailbox
  address as the GDPR establishment; auto-renewal reminder laws, since
  we hold no email address; the EU 14-day withdrawal right.
- **When to switch on `table` timing** in remote config: only after
  older builds are asked to update (`update.before`), since they ignore
  it and play the standard clocks (doc 06, Remote config).
- **Make the repo public.** The site's privacy page already says "the
  code is public", and the footer links to GitHub.

## Accounts and identifiers

- **A contact email address.** Outreach, the Play Console listing and
  the support page still lack one (`docs/launch/outreach.md`,
  `store-listing.md`).
- **Apple Developer account and App Store Connect**: the app's bundle
  id, the auto-renewable subscription's product id (a yearly
  subscription in its own group), an App Store Server API key (issuer
  id, key id, `.p8`), and App Store Server Notifications V2 pointed at
  the service. Unblocks buying on iPhone.
- **Google Play Console**: the package name, the subscription's product
  id and base plan, a service account with access to the Play Developer
  API, and Real-time Developer Notifications (a Pub/Sub topic with a
  push subscription to the service). Unblocks buying on Android.
- **A Mac with Xcode**, to build, sign and submit the iPhone app — and
  to build the deal's native library for iOS.
- **Provider sign-in**: a Google OAuth client id and an Apple Services
  id, so a lost phone is recovered by signing in (README, roadmap 8).

## Stripe

- **Create the $5.99/year price** and set it as `OH_STRIPE_PRICE`, or
  as `stripePrice` in `config|service` (doc 06, "The service's
  settings").
- **Set up the billing portal** (Stripe → Settings → Billing →
  Customer portal): allow cancelling (at the end of the period),
  updating the payment method and viewing invoices; add the business
  name, the privacy and terms links, and save it. Without a saved
  configuration Stripe refuses to open a portal, and Manage
  subscription says the shop is not open.
- **Decide who may open the portal.** As built, any device on the
  subscription may — so a household that lost the phone that paid can
  still cancel — which also shows any of them the payer's email and
  receipts. Restricting it to the device that paid is a one-line
  change.
- **The webhook** sends `checkout.session.completed`,
  `checkout.session.async_payment_succeeded` and
  `customer.subscription.*` to `/api/stripe`. No other product checked
  out through the API with a `key` in its metadata on this account.

## Cloudflare and deploying

- **Rate limits** (WAF): `/api/*` per IP, generous; tighter on
  `/api/ticket`, `/api/claim`, `/api/checkout`, `/api/turn`; and one on
  WebSocket upgrades to the relay host (`docs/security-review.md`,
  "What the owner has to do").
- **TURN**: a usage alert or budget on Cloudflare Realtime.
- **Plan**: the Workers paid plan, or the rate limits above, before
  launch — KV's free 1,000 writes a day is spendable.
- **Secrets** set as encrypted secrets, not plain variables;
  `OH_OPEN_HOUSE` unset everywhere.
- **Bind the household**: set the Pages project's `OH_STORE` namespace
  id in `service/do/wrangler.toml`, deploy `service/do`, then bind
  `HOUSEHOLD` on the Pages project (script `open-hearts-relay`, class
  `Household`). In that order.
- **The domain**: attach openhearts.game to the Pages project; the
  site, the store listing and the app's legal links assume it.
- **After deploying**, check the headers (`docs/security-review.md`,
  item 6) and that live play works on production end to end — it has
  not been confirmed there.

## Done
