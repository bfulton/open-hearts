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
- **Make the repo public.** The site's privacy page already says "the
  code is public", and the footer links to GitHub.

## Accounts and identifiers

- **Renew the Cloudflare API token before 9 October 2026**, when it
  expires: deploys (`deploy.sh`, `wrangler deploy`) and the infra check
  (`node infra/apply.mjs`) stop working without it. The same
  permissions, set again as `CLOUDFLARE_API_TOKEN` in the environment.

- **Apple Developer account and App Store Connect** — unblocks buying
  on iPhone (the code is built and tested against a stand-in chain):
  - the app's bundle id → `OH_APPLE_BUNDLE_ID` on the Pages project;
  - an auto-renewable subscription, a year, $5.99, in its own group →
    its product id as `OH_APPLE_PRODUCT` (and in the app build,
    `--dart-define=OH_APPLE_PRODUCT=…`; the placeholder is
    `live_play_yearly`);
  - App Store Server Notifications **V2**, production and sandbox
    URLs both `https://<site>/api/apple`;
  - a sandbox tester, to buy once end to end before review.
- **Google Play Console** — unblocks buying on Android:
  - the package name → `OH_PLAY_PACKAGE`; the subscription's product id
    with a yearly base plan → `OH_PLAY_PRODUCT` (and
    `--dart-define=OH_PLAY_PRODUCT=…`);
  - a Google Cloud service account invited in Play Console (Users and
    permissions) with "View financial data" and "Manage orders and
    subscriptions"; its JSON key as the secret
    `OH_PLAY_SERVICE_ACCOUNT`;
  - Real-time Developer Notifications: a Pub/Sub topic (grant
    `google-play-developer-notifications@system.gserviceaccount.com`
    Publisher on it), named in Play Console's Monetization setup, and a
    **push** subscription to `https://<site>/api/play` with
    authentication on, using a service account of its own: that
    account's email → `OH_PLAY_PUSH_EMAIL`, and the audience (default:
    the push URL) → `OH_PLAY_PUSH_AUDIENCE`;
  - a license tester, to buy once end to end.
- **Store business setup**: Apple's Paid Apps agreement, tax and
  banking forms, and In-App Purchase enabled on the App ID; a Play
  merchant account. Neither store sells a subscription without them.
  Play billing works only for a build uploaded to a testing track.
- **The app's ids.** Android's `applicationId` is still the template's
  `com.openhearts.open_hearts` (`app/android/app/build.gradle.kts`, a
  TODO), and the app's Manage link assumes it (`OH_PLAY_PACKAGE`). Pick
  the final Android package and iOS bundle id before the first upload:
  neither can change after.
- **Android release signing**: an upload keystore, with
  `app/android/key.properties` written from it wherever a release is
  built (a release refuses to build without it).
- **Try it on a real Android phone**: install a build made after
  `crypto/build_android.sh` and play a live table. The native deal
  library is built, exports everything the app calls, and is packed
  into the APK, but there was no emulator here to run it.
- **A Mac with Xcode**, to build, sign and submit the iPhone app — and
  to build the deal's and Schnorr's native libraries for iOS (an
  xcframework linked into Runner, opened with
  `DynamicLibrary.process()`): until then an iPhone build plays alone.
- **App Store metadata**: the privacy policy and terms URLs
  (`/privacy`, `/terms`) in App Store Connect, and the terms named as
  the EULA or Apple's standard one chosen.
- **Provider sign-in**: a Google OAuth client id and an Apple Services
  id, so a lost phone is recovered by signing in (README, roadmap 8).

## Stripe

- **Sales tax, with an accountant**: whether South Carolina, where the
  business is, taxes this subscription, and so whether to register
  there. Other states need registering only past their economic-nexus
  thresholds (commonly $100,000 or 200 sales a year in a state), which
  Stripe Tax's monitoring shows when it is on. The checkout does not
  turn on automatic tax today.
- **Decide who may open the portal.** As built, any device on the
  subscription may — so a household that lost the phone that paid can
  still cancel — which also shows any of them the payer's email and
  receipts. Restricting it to the device that paid is a one-line
  change.
## Cloudflare and deploying

- **Tighter rate limits need a paid zone plan.** The Free plan allows
  one rule; it is in place (below). Per-handler limits — `/api/ticket`,
  `/api/claim`, `/api/checkout`, `/api/turn` at about ten a minute
  (`docs/security-review.md`) — need Pro.
- **Buy it once for real**: on https://openhearts.game/play, subscribe
  with your own card, play a live table on two devices, open Manage
  subscription, then cancel and refund it in Stripe. Everything short
  of a payment has been checked on production (2 October).
- **Revoke the temporary keys** given to set this up: the Stripe
  restricted key and the Cloudflare API token.
- **A Stripe sandbox** (needs a computer: the dashboard's account
  picker → Sandboxes → Create), its secret key `sk_test_…` added to the
  environment as `STRIPE_SANDBOX_KEY`. Then the price (same lookup key
  `openhearts_annual`), a webhook to
  `https://dev.open-hearts.pages.dev/api/stripe`, the portal, and a
  restricted key for Preview can be set up from here, so purchases can
  be tested on preview without real money.

## Done

- 2 October: the yearly $5.99 product created in Stripe.
- 2 October: `OH_STRIPE_PRICE` set to the price's lookup key.
- 2 October: Stripe's customer portal: cancelling, payment method and invoices on (the defaults). Confirm Manage subscription opens it in the first production test.
- 2 October: `OH_STRIPE_WEBHOOK_SECRET` set.
- 2 October, checked through the API: live mode; price
  `openhearts_annual`, $5.99 a year, active; the live webhook at
  `https://open-hearts.pages.dev/api/stripe`, enabled, with every event
  the service reads (the extra checkout and subscription events it
  receives are answered and ignored); the portal's default
  configuration cancels at the period's end, updates cards and shows
  invoices, and now links the privacy policy and terms.
- 2 October: the service's restricted Stripe key saved as `OH_STRIPE_SECRET`.
- 2 October: Cloudflare set up through the API. Stripe and TURN values
  re-saved as encrypted secrets (the price as plain text); a new
  service signing pair (`OH_SERVICE_SECRET`, public key
  `8031cb21…a46b` compiled into the build) and `OH_ID_HMAC`; the
  `open-hearts-store` KV namespace bound as `OH_STORE`; the relay
  deployed at `relay.openhearts.game` with the store, and its Household
  object bound to the Pages project as `HOUSEHOLD`.
- 2 October: production deployed. openhearts.game serves the site, the
  app at /play, the legal pages and /api; www.openhearts.game and all
  of openhearts.lol redirect (301) to it, path and query kept. Stripe's
  webhook and portal links moved to openhearts.game.
- 2 October, checked on production: headers (frame-ancestors, DENY,
  HSTS, nosniff); a signed licence for an unpaid key 402, unsigned 401;
  a real Stripe checkout session opened; Manage 402 for a non-subscriber;
  a forged webhook 400; TURN 402 for a non-subscriber; the relay
  answering. Fixed on the way: the Pages worker could not load its
  signature wasm on Cloudflare (every signed request answered 503), and
  five old preview deployments that handed TURN credentials to anyone
  were deleted.
- 2 October: only real secrets are encrypted now; `OH_TURN_KEY_ID`
  (`open-hearts-turn`, d681af4e…), `OH_STRIPE_PRICE` and
  `OH_SERVICE_KEY` are plain text. Checked: production minted TURN
  credentials for a device given a test subscription (rows deleted).
- 2 October: Preview has its own store (`open-hearts-store-preview`)
  and no `HOUSEHOLD` binding (that object reads production's store), so
  nothing done on a preview deployment touches production's rows.
- 2 October: the first real purchase, on production: checkout, the
  webhook and the licence all worked. Stripe's account renamed to Open
  Hearts inside a Bright Fulton organization; checkout branded like the
  app; receipt emails (successful payments) switched on.
- 2 October: a rate limit on openhearts.game: `/api/*` (but not the
  Stripe, Apple and Play webhooks) and relay.openhearts.game, 30
  requests per 10 seconds per address, blocked for 10 seconds. Checked:
  a burst of 300 from this machine's handful of addresses drew 429s.
- 2 October: Cloudflare budget alerts at $10, $20, $50, $100 and $200
  of spend in a billing period, emailed to bright.fulton@gmail.com.
  Cloudflare has no hard cap; TURN (free to 1,000 GB a month) is the
  one cost here that grows with use.
- 2 October, decided: no daily cap on TURN credentials. Play uses
  kilobytes against a free 1,000 GB a month; a count cap would not limit
  what one misused credential carries; the budget alerts would show
  misuse at $10. If it is ever needed: shorten `turnTtlS` (config|service)
  to an hour and have the app refresh its credentials mid-session.
- 2 October: the Workers Paid plan on.
- 2 October: the service's Stripe key replaced with one restricted to
  what it calls (Products, Subscriptions and Customers read; Checkout
  Sessions and Customer Portal write); the old one, which a template
  had given read and write on nearly everything, expired. A checkout on
  production opened with the new key.
- 2 October: the jurors of last resort deployed as a Cloudflare
  Container. Checked on production: a call for a juror on
  relay.openhearts.game brought all four online 2.4 s later.
- 2 October: production deployed with no open-bot fallback, Activate
  subscription, backup codes and the About links.
- 3 October: Cloudflare Web Analytics switched off for openhearts.game
  (it injected a script from static.cloudflareinsights.com into the
  site and the app, which the site says it does not do); New Relic is
  what watches the app now (observability/). altesc.game's left as it
  was.
- **A contact email address** — help@openhearts.game, forwarded by Cloudflare Email Routing (4 October 2026).
