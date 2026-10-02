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

- **Name the price.** The yearly $5.99 product is made (2 October).
  Set `OH_STRIPE_PRICE` on the Pages project to the price's **lookup
  key** (simplest: give the test-mode and live-mode prices the same
  one, and later move it to a new price with nothing changed here) or
  to its `price_…` id — not the product's `prod_…`. A `price_…` id
  belongs to one mode, so it has to match the secret key's mode; a
  lookup key resolves in whichever mode the key is.
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

- 2 October: the yearly $5.99 product created in Stripe.
