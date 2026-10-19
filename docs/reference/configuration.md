# Configuration, secrets and bindings

This page lists every setting Open Hearts reads: the committed configuration file, the secrets and bindings of the two Cloudflare workers, the environment variables that scripts and tests read, the rows that the operator writes to the store, and the table clocks.

For why the service is set up this way, see [the service](../explanation/service.md).

## `config/openhearts.json`

The non-secret configuration, committed and the same for every deployment.

- The Pages worker reads it beneath its own settings: `service/functions/entry.mjs` passes the file to `withConfig` in `service/functions/deployment.mjs`, which maps each field to an `OH_` name (`configEnv`). A variable of the same name that is set on the project or by a test wins, except `OH_PRICE`: the price is the file's alone. The entry also hands the worker `site/ledger.json` as `OH_LEDGER` (see [Change the terms](../how-to/change-the-terms.md)).
- The relay worker reads it the same way (`service/do/worker.mjs`).
- `deploy.sh` compiles `serviceKey`, `google.webClientId` and `apple.servicesId` into the web build.
- `app/tool/defines.mjs` writes the phone build's `--dart-define-from-file` from it (`appDefines`).
- A field that is `null` is left out, so the feature that needs it stays off.

| Field | Worker name (`configEnv`) | Build define (`appDefines`) | What it is |
|---|---|---|---|
| `appOrigin` | none | `OH_APP_ORIGIN` | The app's origin. A phone build calls the service there and builds shared links on it (`app/lib/net/address_io.dart`). `app/tool/defines.mjs` refuses a file without it. |
| `serviceKey` | `OH_SERVICE_KEY` | `OH_SERVICE_KEY` | The service's public key, 64 hex characters. Licences and activations are checked against it. A production deploy and a phone build refuse to run without it. |
| `turnKeyId` | `OH_TURN_KEY_ID` | none | The Cloudflare Realtime TURN key that the worker mints credentials with. `infra/cloudflare.mjs` (`turnKeys`) defines the same key. |
| `stripePrice` | `OH_STRIPE_PRICE` | none | The Stripe price, as a price ID or lookup key, that a checkout sells. A checkout sells it only when it is a year at `price`. |
| `price` | `OH_PRICE` (`"599 usd"`), which no project setting overrides | none | What a year costs on the web: `{"amount": <cents>, "currency": "usd"}`. The terms and the front page state it (`{{price}}`, `site/build.mjs`), Stripe's price is made at it (`infra/stripe.mjs`), and a checkout sells at it and no other. `priceAmount` in `app/lib/net/buying.dart` is held to it by `site/ledger.test.mjs`. Changed only as [Change the terms](../how-to/change-the-terms.md#change-the-price) says. |
| `apple.bundleId` | `OH_APPLE_BUNDLE_ID`, and part of `OH_APPLE_AUDIENCE` | none | The iOS bundle ID. App Store notifications for another bundle are ignored. |
| `apple.product` | `OH_APPLE_PRODUCT` | `OH_APPLE_PRODUCT` | The App Store subscription product. |
| `apple.servicesId` | part of `OH_APPLE_AUDIENCE` | `OH_APPLE_SERVICE_ID` | The Sign in with Apple Services ID that the web uses. |
| `google.package` | `OH_PLAY_PACKAGE` | none | The Android package name. |
| `google.product` | `OH_PLAY_PRODUCT` | `OH_PLAY_PRODUCT` | The Google Play subscription product. |
| `google.webClientId` | `OH_GOOGLE_AUDIENCE` | `OH_GOOGLE_CLIENT_ID` | The Google sign-in client ID. A build without it offers no Google sign-in. |
| `google.playPushAudience` | `OH_PLAY_PUSH_AUDIENCE` | none | The audience of the ID token that Pub/Sub pushes Play notifications with (`pushedByPlay`). |
| `google.playPushEmail` | `OH_PLAY_PUSH_EMAIL` | none | The service account that Pub/Sub pushes as (`pushedByPlay`). |
| `alerts.to` | `OH_ALERTS_TO` | none | Where the operator's alerts go. Only an `@openhearts.game` address is taken (`alertsOf` in `service/functions/alerts.mjs`). |
| `alerts.subscribed` | `OH_ALERT_SUBSCRIBED` (`on` when `true`) | none | Email the operator about each new subscription. |
| `alerts.waiting` | `OH_ALERT_WAITING` (`on` when `true`) | none | Email the operator when a subscriber waits for a person (the `waiting` handler). |
| `alerts.pictures` | `OH_ALERT_PICTURES` (`on` when `true`) | none | Email the operator once a day the new pictures subscribers put out at live tables (`reviewRun` in `service/do/review.mjs`; [Look at the day's new pictures](../how-to/look-at-new-pictures.md)). |

The app also reads `OH_PLAY_PACKAGE` as a build define (`app/lib/net/store_buying.dart`). `appDefines` does not set it, so the default in that file applies.

## Secrets

### Pages project secrets

Defined by name in `pages.environments` in `infra/cloudflare.mjs`. `./oh infra` checks that each one is set, and never reads a value; `./oh secret set` sets one.

| Secret | Production | Preview | Read by | Without it |
|---|---|---|---|---|
| `OH_SERVICE_SECRET` | Yes | Yes | `serviceSigned` in `service/functions/licence.mjs`: signs licences (`licenceFor`) and activations (`activationFor`) | Handlers that sign answer 503. A secret that does not match `OH_SERVICE_KEY` also answers 503. |
| `OH_ID_HMAC` | Yes | Yes | `loginRow`: the HMAC key a sign-in's subject is stored under | `attest`, `supersede` and `apple-id` answer 503. |
| `OH_STRIPE_SECRET` | Yes | No | `checkout`, `manage`, `payerLookup`, `endRefunded`, `healthOf` | `checkout` and `manage` answer 503. `health` reports Stripe as not configured. Backup codes are not emailed. A refund's webhook answers 503, so Stripe sends it again. |
| `OH_STRIPE_WEBHOOK_SECRET` | Yes | No | `webhookSigned` | The `stripe` webhook answers 400 to every delivery. |
| `OH_TURN_API_TOKEN` | Yes | Yes | `mint` | `turn` answers 503, and the app plays over the relay. |
| `OH_PLAY_SERVICE_ACCOUNT` | When the config names Play (`playSecrets`) | No | `playToken`: the Google service account's JSON key for the Play Developer API | `store` answers 503 for a Play purchase. `play` answers a subscription notification with 200 and records nothing. |

The worker calls these Stripe endpoints, in the API version `STRIPE_VERSION` in `service/functions/stripe.mjs` names, which is the webhook's, so `OH_STRIPE_SECRET` needs access to each: `GET /v1/prices` and `GET /v1/prices/{id}`, `POST /v1/checkout/sessions`, `GET /v1/subscriptions/{id}` (with its customer expanded, for a notice of a change to the terms), `POST /v1/billing_portal/sessions`, `GET /v1/customers/{id}`, and, to end a refunded subscription, `GET /v1/invoice_payments`, `GET /v1/invoices/{id}` and `DELETE /v1/subscriptions/{id}`. As a restricted key: Prices, Products, Customers and Invoices read; Checkout Sessions, Customer Portal and Subscriptions write.

### Relay worker secret and variables

The relay worker (`open-hearts-relay`) is defined by `service/do/wrangler.toml`. `infra/cloudflare.mjs` (`relay`) names its secret, and `infra/apply.mjs` checks the live worker against both files.

| Name | Kind | Set in | What it is |
|---|---|---|---|
| `OH_JUROR_SECRET` | Secret | The relay worker's secrets | 64 hex characters. The backup jurors derive their keys from it, and the relay checks each backup juror's mark against it (`benchMark` in `service/do/relay.mjs`). Without it, the relay admits no backup juror. |
| `OH_MAIL_FROM` | Variable | `[vars]` in `service/do/wrangler.toml` | The sender of backup-code emails and the operator's alerts. |
| `OH_SERVICE_KEY` | From the config file | `config/openhearts.json` (`serviceKey`) | The key every activation must be signed by. `wrangler.toml` does not set it. Without a valid key, the relay carries no device. |
| `OH_BENCH_RELAYS` | Optional variable | Not set | Overrides the relays the backup jurors' container follows tables on. The default is `OH_RELAYS` in `service/bench/Dockerfile`. |
| `OH_BENCH_PRESENCE_RELAYS` | Optional variable | Not set | Overrides the relays the backup jurors' container announces presence on. The default is `OH_PRESENCE_RELAYS` in `service/bench/Dockerfile`. |

## Bindings

### Pages project

From `pages.environments` in `infra/cloudflare.mjs`. Pages also provides `ASSETS`, the static files.

| Binding | Kind | Production | Preview | Used for |
|---|---|---|---|---|
| `OH_STORE` | Workers KV | `open-hearts-store` | `open-hearts-store-preview` | Every row the service keeps. See [Storage](service-api.md#storage). |
| `OH_RECORDS` | R2 bucket | `open-hearts-records` | `open-hearts-records-preview` | Finished games' records (`service/functions/records.mjs`). |
| `HOUSEHOLD` | Durable Object (script `open-hearts-relay`, class `Household`) | Bound | Not bound | Runs each account's operations one at a time, and sends the operator's alerts. |
| `OH_METRICS` | Workers Analytics Engine | Dataset `open_hearts_api` | Not bound | One line per request, sampled for `config` and `health` (`measure` and `SAMPLED` in `service/functions/metrics.mjs`). |

Without `HOUSEHOLD`, the worker runs each account's operations in a queue in its own isolate (`inHousehold`), and sends no alerts.

### Relay worker

From `service/do/wrangler.toml`.

| Binding | Kind | Used for |
|---|---|---|
| `TABLE` | Durable Object, class `TagRelay` | One object per tag. See [Relay tags, kinds and limits](relay.md). |
| `HOUSEHOLD` | Durable Object, class `Household` | Each account's object. The Pages project binds the same class. |
| `BENCH` | Durable Object and Cloudflare Container, class `Bench` | The backup jurors (`service/do/bench.mjs`). |
| `OH_STORE` | Workers KV | The same namespace as production's `OH_STORE`. The `Household` object reads and writes it. Each relay object reads [relay settings](#relay-settings) and the pictures withheld from it, and adds a picture the automatic check hides. |
| `OH_PICTURES` | R2 bucket `open-hearts-pictures` | A copy of each new picture a subscriber puts out, for the operator to look at, served at `pictures.openhearts.game` (`service/do/review.mjs`). |
| `AI` | Workers AI | The automatic check of each new picture, by `@cf/cloudflare/clef-flash` (`checkPicture` in `service/do/review.mjs`). Without it, pictures are copied and not checked. |
| `EMAIL` | Email Sending (`send_email`) | Backup-code emails, the operator's alerts, and the day's new pictures. |
| `OH_METRICS` | Workers Analytics Engine, dataset `open_hearts_relay` | A line of counts from each object: a minute after its last, and at once when its last socket closes, each with the seconds it covers (`tally` and `tallied` in `service/do/relay.mjs`). |

Its schedule (`triggers.crons`) runs once a day at 13:00 UTC, when `alerts.pictures` is on: it deletes the copies in `OH_PICTURES` that nobody has put out for 30 days, hides any new picture the check found should be hidden that isn't yet, and emails the operator the new ones.

## Environment variables

### Deploying and operating

| Variable | Read by | What it is |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | `./oh` (most commands), `deploy.sh` (required), `infra/apply.mjs` | A Cloudflare API token. |
| `CLOUDFLARE_ACCOUNT_ID` | `./oh` (most commands), `deploy.sh` (required), `infra/apply.mjs` | The Cloudflare account ID. |
| `STRIPE_API_KEY` | `./oh account`, `infra/apply.mjs` | The operator's live-mode Stripe key: for `./oh infra`'s Stripe part, for finding an account by email, and for what suspending, ending and refunding an account do in Stripe. What each needs it to allow is in [the oh command](oh.md#credentials). |
| `OH_HELP_FORWARD` | `infra/apply.mjs` | Where `help@` and `alerts@` forward. When unset, the destination is only checked to be verified. |
| `OH_ALERT_EMAIL` | `infra/apply.mjs`, `observability/apply.mjs` | Who the Cloudflare spend alerts and the New Relic alerts email. |
| `NEW_RELIC_API_KEY` | `observability/apply.mjs` (required) | A New Relic User key. |
| `NEW_RELIC_ACCOUNT_ID` | `observability/apply.mjs` (required) | The New Relic account. |
| `NEW_RELIC_REGION` | `observability/apply.mjs` | `US` (the default) or `EU`. |
| `OH_SERVICE_KEY`, `OH_GOOGLE_CLIENT_ID`, `OH_APPLE_SERVICE_ID` | `deploy.sh` | Override the values from `config/openhearts.json` for one build. |
| `OH_RELAYS` | `deploy.sh` | Passed to the web build as a define. Leave it unset so that the build uses its own relay list. |
| `FLUTTER` | `deploy.sh`, `build_phone.sh`, `e2e/build.sh`, `app/worker/build.sh` | The `flutter` command to run. |
| `DART` | `app/worker/build.sh` | The `dart` command to run. |
| `ANDROID_NDK_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT` | `crypto/build_android.sh` | Where to find the Android NDK. |
| `CARGO_HOME` | `crypto/wasm.sh` | Removed from paths inside the wasm, so that every machine builds the same bytes. |

What each script does with the Cloudflare API token, which is what the token needs to allow:

- `deploy.sh` publishes to the Pages project and, with `--prune`, lists and deletes its deployments.
- `./oh account delete` reads and deletes rows in `OH_STORE` (Workers KV Storage: Edit), and reads and rewrites kept games in `OH_RECORDS` (Workers R2 Storage: Edit).
- The other `./oh account` acts read rows and write orders in `OH_STORE` (Workers KV Storage: Edit), and, to take a name off, read and rewrite kept games in `OH_RECORDS` (Workers R2 Storage: Edit). `./oh config` reads and writes rows in `OH_STORE`.
- `infra/apply.mjs` reads every resource that `infra/cloudflare.mjs` defines, and with `--apply` changes them.
- The relay's deploy (`./oh deploy relay`, which runs `npx wrangler deploy` in `service/do`) uploads the relay worker with its Durable Objects, its container image and its custom domain.

No script checks the token's permissions first. A missing permission shows as Cloudflare's own error, or for `infra/apply.mjs` as an `unread:` line.

### Tests and local runs

| Variable | Read by | What it is |
|---|---|---|
| `OH_RELAY` | `service/lib/src/relay.dart`, so the `service/` tests and `service/bin/service.dart` | Unset: the Dart relay. `js`: the relay the Cloudflare object runs, hosted by `service/do/host.mjs`. `object`: the same, under the object's own rules (one tag an address, only that tag's kinds). |
| `OH_DEAL_MEMO` | `packages/deal/lib/memo.dart` | `off` keeps no deal answers on disk. |
| `CHECK_PLAN` | `check.sh` | Any non-empty value: print what would run, and run nothing. |
| `CHROME_EXECUTABLE` | `check.sh` (`app` suite) | The Chrome that runs `app/test/web`. |
| `PLAYWRIGHT_BROWSERS_PATH` | `check.sh` (`app` suite) | Where to look for Playwright's Chromium when no other Chrome is found. |
| `OH_JUROR_SECRET` | `service/bin/juror.dart`, `service/do/host.mjs` | The backup jurors' secret. Without it, `juror.dart` makes fresh keys and has no mark. |
| `OH_SERVICE_KEY` | `service/bin/juror.dart` | The jurors hold every seat to its licence under this key. |
| `OH_OPEN_HOUSE` | The Pages worker (`openHouse`) | Local mode: every device that asks is licensed, and `local:` sign-ins are accepted. Honoured only for a request to `localhost`, `127.0.0.1` or a `*.localhost` host (`isLocal`). The browser suites' rig sets it. |
| `OH_TURN_LOCAL` | The Pages worker (`turn`) | In local mode, the TURN URL that `turn` hands out, with fixed credentials. The rig points it at its coturn. |

### Build defines

Compile-time values the app reads with `String.fromEnvironment`. They are not environment variables.

| Define | Read in | Set by |
|---|---|---|
| `OH_SERVICE_KEY` | `app/lib/net/licence.dart` | `deploy.sh`, `app/tool/defines.mjs`, `e2e/build.sh` |
| `OH_APP_ORIGIN` | `app/lib/net/address_io.dart` | `app/tool/defines.mjs` |
| `OH_GOOGLE_CLIENT_ID`, `OH_APPLE_SERVICE_ID` | `app/lib/net/provider_tokens.dart` | `deploy.sh`, `app/tool/defines.mjs` |
| `OH_APPLE_PRODUCT`, `OH_PLAY_PRODUCT`, `OH_PLAY_PACKAGE` | `app/lib/net/store_buying.dart` | `app/tool/defines.mjs` (not `OH_PLAY_PACKAGE`) |
| `OH_RELAYS` | `app/lib/net/relays.dart` | `deploy.sh` (empty). A comma list replaces the build's relays. |

## Remote config

The row `config|app` in `OH_STORE`, which the `config` handler serves to every device. The worker checks each field (`configOf` in `service/functions/config.mjs`), and the app checks each again (`RemoteConfig.parse` in `app/lib/net/remote_config.dart`). A field that fails its check is left at its default. An absent or unreadable row serves `CONFIG_DEFAULTS`.

| Field | Check | Default | Effect |
|---|---|---|---|
| `v` | Served, not read | `1` | The row's format version. |
| `live` | Boolean | `true` | `false` closes live play: the buttons, table links and juror duty. Games in progress play on. |
| `offer` | Boolean | `true` | `false` hides the paid tier from devices that have not bought it. |
| `relays` | 1 to `MOST_RELAYS` `wss:` URLs on `openhearts.game` or a subdomain, with no user info. All must pass, or none is taken. | The build's (`ourRelay` in `app/lib/net/relays.dart`) | Replaces the build's relays, read at app start. A build served from a local host, or built with `OH_RELAYS`, ignores it. |
| `banner` | `id` matching `^[\w.-]{1,64}$`; `level` `warn` (anything else is `info`); `text` by two-letter language code, English required, each up to `LONGEST_SAY` characters | None | A line on the front door. |
| `update` | `before` as `YYYY-MM-DD`; optional `text` as for `banner` | None | Asks builds published before that day to update. |
| `feedback` | An `https:` URL or a `mailto:` address | The project's issues | Where "Tell us what's broken" sends a report. |
| `table` | See [Table clocks](#table-clocks). All fields pass, or none is served. | The standard table | The clocks of tables this device starts. |
| `waits` | See the next table. | The app's own | How long the app waits on the network. |

Beside the row's fields, the `config` handler serves `notices`: each document's newest material or price change in `site/ledger.json`, for 60 days from the day it was published, as `[{document, date, summary}]` with the summary in each language (`noticesOf` in `service/functions/notices.mjs`). The row can't set it.

The price, and where the terms and the privacy policy are, are not fields: the site publishes them, and they change only with it.

The `config` handler answers with `cache-control: public, max-age=60`. The app keeps the last answer for its next start, and asks again every `configEveryMin`.

### Waits

Each field of `waits` is taken on its own when it is a whole number within its bounds. Bounds are `WAITS_BOUNDS` in `service/functions/config.mjs` and `AppWaits.bounds` in `app/lib/net/remote_config.dart`; `service/functions/config.test.mjs` holds the two equal. Defaults are the `AppWaits` constructor. All values are milliseconds, except `configEveryMin`, which is minutes.

| Field | `AppWaits` field | What the app waits for |
|---|---|---|
| `licenceMs` | `licence` | The device's licence. |
| `householdMs` | `household` | A household code, claim, drop or device list. |
| `buyMs` | `buy` | Opening a checkout. |
| `turnMs` | `turn` | TURN credentials. |
| `configMs` | `config` | This config. |
| `configEveryMin` | `configEvery` | How often an open app asks for this config again. |
| `relaySlowMs` | `relaySlow` | When the screen says a relay is slow. |
| `relayGiveUpMs` | `relayGiveUp` | When the app gives up on a relay. |
| `standingMs` | `standing` | The standings from the first relay. |
| `standingAllMs` | `standingAll` | The standings from the other relays. |
| `roomStartMs` | `roomStart` | How long after the last arrival a friends' room starts, once two are in. |
| `meshAnswerMs` | `meshAnswer` | A direct connection to a peer. After this, the table uses the relay. |
| `recordMs` | `record` | Keeping or fetching a game's record. |
| `recordAgainMs` | `recordAgain` | How often a just-finished game's record is asked for again. |
| `recordForMs` | `recordFor` | How long it is asked for, when the game was watched to its end. |
| `recordSoonMs` | `recordSoon` | How long it is asked for, when the page was opened just as the game ended. |

Two groups go together. When a group breaks its rule, the worker drops every field of it (`waitsOf`), and the app uses its own values for every field of it (`AppWaits.parse`). A field of a group that is not set is compared at the app's default.

- **The relay pair:** `relaySlowMs` must be less than `relayGiveUpMs`.
- **The record's three waits:** `recordAgainMs` must be no more than `recordForMs` and no more than `recordSoonMs`.

## Service settings

The row `config|service` in `OH_STORE`. It is never served. The Pages worker and the `Household` object read it at most once a minute per isolate (`settle`, `SETTINGS_KEPT_MS`). Each number is taken when it is a whole number within its bounds, and otherwise keeps its default (`serviceSettingsOf`).

Defaults and bounds: `SERVICE_DEFAULTS` and `SERVICE_BOUNDS` in `service/functions/settings.mjs`.

| Field | What it sets |
|---|---|
| `licenceDays` | How long a licence lasts. A licence never runs past the day the subscription is paid to. |
| `mostDevices` | How many devices one account may have. |
| `ticketMinutes` | How long a household code is good for. |
| `ticketReuseMinutes` | How much time an outstanding code must have left to be handed out again rather than replaced. Must be less than `ticketMinutes`; otherwise it is lowered. |
| `turnTtlS` | How long TURN credentials last, in seconds. |
| `requestToleranceS` | How far a signed request's time may be from the service's clock, in seconds. |
| `webhookToleranceS` | How old a Stripe webhook's timestamp may be, in seconds. |
| `householdChangesPerHour` | An account's changes in an hour: everything asked of its queue that is not counted below, such as codes, claims, drops, backup-code rotations and sign-in links. Apple's unlinks have a separate allowance of the same size. |
| `householdReadsPerHour` | An account's reads in an hour: device lists, profile reads, and backup codes shown or emailed. |
| `activationsPerHour` | An account's activations in an hour, counting the relay's checks for it and `review`'s. |
| `profileWritesPerHour` | Writes of an account's profile in an hour. |
| `recordsPerHour` | Game records an account may send to be kept in an hour. |

Each allowance is counted in the account's own queue (`sequencer` and `kindOf`). A request over an allowance gets 429. The operator's orders (`order`) are not counted.

## Relay settings

The row `config|relay` in `OH_STORE`. It is never served. Each relay object reads it when it is built after waking (`limitsFrom` in `service/do/relay.mjs`), and only the `online` object applies it. Every other tag keeps `tableLimits`. Each value is taken when it is a whole number within its bounds (`objectLimitsOf`).

Defaults and bounds: `objectLimits` and `objectLimitBounds` in `service/do/relay.mjs`.

| Field | What it sets |
|---|---|
| `message` | The longest message a socket may send, in characters. |
| `request` | The longest `REQ` a socket may send, in characters. |
| `burst` | How many events a socket may publish at once. |
| `perSecond` | How many events a socket may publish each second after its burst. |

## Table clocks

The clocks a table plays by. The device that starts a table takes them from the `table` field of its [remote config](#remote-config), and they ride in the signed start event (`TableSpec.timing` in `packages/table/lib/src/spec.dart`), so every seat plays by the same clocks. A start event with no timing, or with any field of the wrong type or out of bounds, gives the standard table (`TableTiming.parse`).

Bounds: `TableTiming.bounds` in `packages/table/lib/src/timing.dart`, and the same values in `TABLE_TIMING_BOUNDS` in `service/functions/config.mjs`. All values are milliseconds.

| Field | Default in | What it times |
|---|---|---|
| `graceMs` | `TimeBank` in `packages/table/lib/src/time_bank.dart` | A person's grace per card, before the bank is touched. |
| `passGraceMs` | `TimeBank` | A person's grace for the pass. |
| `bankMs` | `TimeBank` | A person's thinking time per hand, beyond the graces. |
| `fixedMs` | `TimeBank` | A person's deal steps and audit, which their device answers by itself. |
| `botActsMs` | `TableTiming` in `packages/table/lib/src/timing.dart` | A held bot seat's card or pass. |
| `botDealsMs` | `TableTiming` | A held bot seat's deal steps and audit. |
| `quorumLostMs` | `TableTiming` | How long a table stopped for a lost quorum waits before the game ends. |
| `silenceMs` | `TableTiming` | How long a person may be silent before a peer may boot them at their turn. |
| `jurorSilenceMs` | `TableTiming` | How long a juror may be silent before the table stops counting it. |

One more clock is fixed in code and is not in remote config: `reloadGraceMs` in `TableClient` (`packages/table/lib/src/client.dart`), how long a seat whose connection closed has to come back before it counts as silent.

For how the clocks are used, see [live play](../explanation/live-play.md) and [the table's states](../explanation/table-states.md).
