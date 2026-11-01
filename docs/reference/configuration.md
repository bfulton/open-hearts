# Configuration, secrets and bindings

This page lists every setting Open Hearts reads: the committed configuration file, the secrets and bindings of the two Cloudflare workers, the environment variables that scripts and tests read, the rows that the operator writes to the store, and the table clocks.

For why the service is set up this way, see [the service](../explanation/service.md).

## `config/openhearts.json`

The non-secret configuration, committed and the same for every deployment.

- The Pages worker reads it beneath its own settings: `service/functions/entry.mjs` passes the file to `withConfig` in `service/functions/deployment.mjs`, which maps each field to an `OH_` name (`configEnv`). A variable of the same name that is set on the project or by a test wins, except `OH_PRICE`: the price is the file's alone. The entry also hands the worker `site/ledger.json` as `OH_LEDGER` (see [Change the terms](../how-to/change-the-terms.md)).
- The relay worker reads it the same way (`service/do/worker.mjs`).
- Where the environment says it is a preview (`OH_DEPLOYMENT` is `preview`), the file is read as a preview has it (`configFor`): `serviceKey` is `preview.serviceKey` and `houseKey` is `preview.houseKey`, or none while there is none, never production's.
- `app/tool/defines.mjs` writes a build's `--dart-define-from-file` from it (`appDefines`), and from nothing in the environment: the phone build's, and the web build's that `deploy.sh` makes. A preview's web build takes the file as a preview has it (`configFor`), and the preview relay as `OH_RELAYS`. The build's commit and date go beside them.
- A field that is `null` is left out, so the feature that needs it stays off.

| Field | Worker name (`configEnv`) | Build define (`appDefines`) | What it is |
|---|---|---|---|
| `appOrigin` | `OH_APP_ORIGIN`, which the relay orders a termination at (`service/do/known.mjs`) | `OH_APP_ORIGIN` | The app's origin. A phone build calls the service there and builds shared links on it (`app/lib/net/address_io.dart`). `app/tool/defines.mjs` refuses a file without it. |
| `serviceKey` | `OH_SERVICE_KEY` | `OH_SERVICE_KEY` | The service's public key, 64 hex characters. Licences and activations are checked against it. A production deploy and a phone build refuse to run without it. |
| `houseKey` | `OH_HOUSE_KEY` | `OH_HOUSE_KEY` | The house's public key, 64 hex characters: the house every live table the app seats names, which deals and plays its bot seats and says how the game came out (`app/lib/net/licence.dart`). The relay carries the house on this key alone, referees sealed tables for it and takes results from it. `./oh house key --apply` writes it, and sets its secret on the relay worker as `OH_HOUSE_SECRET`. A production deploy and a phone build refuse to run without it. |
| `preview.houseKey` | `OH_HOUSE_KEY`, on a preview | `OH_HOUSE_KEY`, in a preview's build | The previews' house, never production's. `./oh preview secrets` writes it, with the preview relay's `OH_HOUSE_SECRET`. |
| `preview.serviceKey` | `OH_SERVICE_KEY`, on a preview | `OH_SERVICE_KEY`, in a preview's build | The public key previews sign with, which is never production's: licences and activations on previews are checked against it. `./oh preview secrets` writes it ([Play live on a preview](../how-to/deploy.md#play-live-on-a-preview)). A preview without it licenses nobody, and the preview relay refuses to deploy. |
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
| `alerts.pictures` | `OH_ALERT_PICTURES` (`on` when `true`) | none | Email the operator once a day the new pictures subscribers set (`reviewRun` in `service/do/review.mjs`; [Look at the day's new pictures](../how-to/look-at-new-pictures.md)). |
| `arachnid.endpoint` | `OH_ARACHNID_ENDPOINT` | none | The address of Arachnid Shield's PDQ call, which checks each new picture's PDQ hash against known images of child sexual abuse (`shieldSays` in `service/do/arachnid.mjs`). With Shield in use, its username set and no address, nothing is checked and the operator is emailed. |
| `photodna.endpoint` | `OH_PHOTODNA_ENDPOINT` | none | The address of PhotoDNA's MatchHash call, which checks each new picture's PhotoDNA Edge Hashes against known images of child sexual abuse when PhotoDNA is the checker in use (`matchHashes` in `service/do/photodna.mjs`; [Switch the checker of known images](../how-to/handle-abuse-material.md#switch-the-checker-of-known-images)). With the key set and no address, nothing is checked and the operator is emailed. |
| `photodna.module` | none | none | The files of the PhotoDNA module the relay is deployed with, each file's name and its SHA-256: the module that makes a picture's Edge Hashes, which Microsoft licenses to Open Hearts as confidential, and the relay's code that calls it. They're kept in the private bucket `open-hearts-private`, not in this repository. `./oh photodna put` writes the pins, and `./oh deploy relay` builds the relay with exactly these files in place of `service/do/photodna_off.mjs`. With `null`, the relay is deployed without the module, and with PhotoDNA in use it checks nothing and emails the operator ([Update the PhotoDNA module](../how-to/update-the-photodna-module.md)). |
| `ncmec.endpoint` | `OH_NCMEC_ENDPOINT` | none | NCMEC's CyberTipline reporting service: `https://exttest.cybertip.org/ispws`, its test service, until a test report has gone through, then `https://report.cybertip.org/ispws` (`fileReport` in `service/functions/ncmec.mjs`). A report to the test service reaches nobody, and the operator is emailed to report the match by hand. |
| `ncmec.reporter` | `OH_NCMEC_FIRST_NAME`, `OH_NCMEC_LAST_NAME`, `OH_NCMEC_EMAIL` | none | Who a report names as reporting it. The email address is required to file one. |

The app also reads `OH_PLAY_PACKAGE` as a build define (`app/lib/net/store_buying.dart`). `appDefines` does not set it, so the default in that file applies.

## Secrets

### Pages project secrets

Defined by name in `pages.environments` in `infra/cloudflare.mjs`. `./oh infra` checks that each one is set, and never reads a value. `./oh secret set` sets one in each environment that lists it (`secrets`), which is production alone, but for `OH_SERVICE_SECRET`, which `./oh key mint` makes with its key (`madeBy`); a preview's own, which is never production's (`ownSecrets`), is made by `./oh preview secrets`.

| Secret | Production | Preview | Read by | Without it |
|---|---|---|---|---|
| `OH_SERVICE_SECRET` | Yes | Its own, the secret half of `preview.serviceKey` (`./oh preview secrets`) | `serviceSigned` in `service/functions/licence.mjs`: signs licences (`licenceFor`) and activations (`activationFor`) | Handlers that sign answer 503. A secret that does not match `OH_SERVICE_KEY` also answers 503. |
| `OH_ID_HMAC` | Yes | Its own (`./oh preview secrets`) | `loginRow`: the HMAC key a sign-in's subject is stored under | `attest`, `supersede` and `apple-id` answer 503. |
| `OH_STRIPE_SECRET` | Yes | No | `checkout`, `manage`, `payerLookup`, `endRefunded`, `healthOf` | `checkout` and `manage` answer 503. `health` reports Stripe as not configured. Backup codes are not emailed. A refund's webhook answers 503, so Stripe sends it again. |
| `OH_STRIPE_WEBHOOK_SECRET` | Yes | No | `webhookSigned` | The `stripe` webhook answers 400 to every delivery. |
| `OH_TURN_API_TOKEN` | Yes | No | `mint` | `turn` answers 503, and the app plays over the relay. |
| `OH_PLAY_SERVICE_ACCOUNT` | When the config names Play (`playSecrets`) | No | `playToken`: the Google service account's JSON key for the Play Developer API | `store` answers 503 for a Play purchase. `play` answers a subscription notification with 200 and records nothing. |

The worker calls these Stripe endpoints, in the API version `STRIPE_VERSION` in `service/functions/stripe.mjs` names, which is the webhook's, so `OH_STRIPE_SECRET` needs access to each: `GET /v1/prices` and `GET /v1/prices/{id}`, `POST /v1/checkout/sessions`, `GET /v1/subscriptions/{id}` (with its customer expanded, for a notice of a change to the terms), `POST /v1/billing_portal/sessions`, `GET /v1/customers/{id}`, and, to end a refunded subscription, `GET /v1/invoice_payments`, `GET /v1/invoices/{id}` and `DELETE /v1/subscriptions/{id}`. As a restricted key: Prices, Products, Customers and Invoices read; Checkout Sessions, Customer Portal and Subscriptions write.

### Pages project variables

Plain variables, defined in `pages.environments` in `infra/cloudflare.mjs` and set by `./oh infra`. Everything else that is not secret is in [`config/openhearts.json`](#configopenheartsjson).

| Variable | Production | Preview | What it is |
|---|---|---|---|
| `OH_DEPLOYMENT` | Not set | `preview` | Which deployment this is. A preview reads the config as a preview has it (`configFor` in `service/functions/deployment.mjs`): with the key previews sign with. |

### Relay worker secret and variables

The relay worker (`open-hearts-relay`) is defined by `service/do/wrangler.toml`. `infra/cloudflare.mjs` (`relay`) names its secrets, those it needs and those it can do without, and `infra/apply.mjs` checks the live worker against both files.

| Name | Kind | Set in | What it is |
|---|---|---|---|
| `OH_ARACHNID_USERNAME`, `OH_ARACHNID_PASSWORD` | Optional secrets | The relay worker's secrets (`relay.optionalSecrets`) | Arachnid Shield's credentials, which the Canadian Centre for Child Protection issues with an account. Without them, while Shield is the checker in use, no picture is checked against known images. |
| `OH_PHOTODNA_KEY` | Optional secret | The relay worker's secrets (`relay.optionalSecrets`) | PhotoDNA's key, which Microsoft issues with access to its PhotoDNA Cloud Service. Used only while PhotoDNA is the checker in use ([known images](#known-images)). |
| `OH_NCMEC_USERNAME`, `OH_NCMEC_PASSWORD` | Optional secrets | The relay worker's secrets (`relay.optionalSecrets`) | The CyberTipline reporting service's credentials, which NCMEC issues to a registered provider. Without them, a match is acted on all the same and the operator is emailed to report it by hand. |
| `OH_HOUSE_SECRET` | Secret | The relay worker's secrets | 64 hex characters: the house's signing key, and the root of every deal secret it makes for a bot seat. The relay starts the house's container with it (`service/do/bench.mjs`). `./oh house key --apply` makes it. Without it, no house plays, and no sealed table can be dealt. |
| `OH_MAIL_FROM` | Variable | `[vars]` in `service/do/wrangler.toml` | The sender of backup-code emails and the operator's alerts. |
| `OH_SERVICE_KEY` | From the config file | `config/openhearts.json` (`serviceKey`, and `preview.serviceKey` on the preview relay) | The key every activation must be signed by. `wrangler.toml` does not set it. Without a valid key, the relay carries no device. |
| `OH_HOUSE_KEY` | From the config file | `config/openhearts.json` (`houseKey`, and `preview.houseKey` on the preview relay) | The house the relay carries on its key alone, referees sealed tables for and takes results from (`service/do/referee.mjs`), and starts its container with, which does not start on a secret that is not this key's. Without a valid key, the relay referees no sealed table, which is every table the app seats. |
| `OH_BENCH_RELAYS` | Optional variable | The preview relay's `[env.preview.vars]` | Overrides the relays the house's container follows tables on. The default is `OH_RELAYS` in `service/bench/Dockerfile`. |

The preview relay (`open-hearts-relay-preview`, `[env.preview]` in the same file, `relay.preview` in `infra/cloudflare.mjs`) has one secret, its own `OH_HOUSE_SECRET`, made by `./oh preview secrets`, and none of the checkers' or NCMEC's: it checks no picture. Its `OH_DEPLOYMENT` is `preview`, as the Pages project's preview environment's is ([variables](#pages-project-variables)).

## Bindings

### Pages project

From `pages.environments` in `infra/cloudflare.mjs`. Pages also provides `ASSETS`, the static files.

| Binding | Kind | Production | Preview | Used for |
|---|---|---|---|---|
| `OH_STORE` | Workers KV | `open-hearts-store` | `open-hearts-store-preview` | Every row the service keeps. See [Storage](service-api.md#storage). |
| `OH_RECORDS` | R2 bucket | `open-hearts-records` | `open-hearts-records-preview` | Finished games' records (`service/functions/records.mjs`), and the pictures a legal hold keeps (`service/functions/holds.mjs`). |
| `HOUSEHOLD` | Durable Object, class `Household` | Script `open-hearts-relay` | Script `open-hearts-relay-preview`, whose households read and write the previews' store | Runs each account's operations one at a time, and sends the operator's alerts. The preview relay has no mail, so a preview's go nowhere. |
| `OH_METRICS` | Workers Analytics Engine | Dataset `open_hearts_api` | Not bound | One line per request, sampled for `config` and `health` (`measure` and `SAMPLED` in `service/functions/metrics.mjs`). |

Without `HOUSEHOLD`, the worker runs each account's operations in a queue in its own isolate (`inHousehold`), sends no alerts, and neither checks nor keeps the pictures accounts set.

### Relay worker

From `service/do/wrangler.toml`.

| Binding | Kind | Used for |
|---|---|---|
| `TABLE` | Durable Object, class `TagRelay` | One object per tag. See [Relay tags, kinds and limits](relay.md). |
| `HOUSEHOLD` | Durable Object, class `Household` | Each account's object, which checks and keeps each picture the account sets with `OH_PICTURES`, `AI` and `KNOWN`. The Pages project binds the same class. |
| `BENCH` | Durable Object and Cloudflare Container, class `Bench` | The house (`service/do/bench.mjs`, `service/bin/house.dart`): started when a sealed table wants it and it is not there, and stopped once it has gone quiet. |
| `OH_STORE` | Workers KV | The same namespace as production's `OH_STORE`. The `Household` object reads and writes it. Each relay object reads [relay settings](#relay-settings) and the pictures withheld from it; an account's object adds a picture the automatic check hides. |
| `OH_PICTURES` | R2 bucket `open-hearts-pictures` | Each account's own copy of each picture it sets, `account/<account>/<sha256>.jpg`, with all that is known of it in its metadata, kept for the operator until a year after it stops being the account's; served at `pictures.openhearts.game` for the daily email (`service/do/profile_pictures.mjs`, `service/do/review.mjs`). The account's picture now is the one it set last, unless that one says it has ended, and the relay carries only that one. |
| `KNOWN` | Durable Object, class `KnownPictures`, made in the `us` jurisdiction | Asks the checker of known images in use about each new picture as an account sets it, and acts on a match (`service/do/known.mjs`). One object, named `known`. |
| `OH_RECORDS` | R2 bucket `open-hearts-records` | Where a hold the `KnownPictures` object places keeps the account's pictures (`heldPictureKey` in `service/functions/holds.mjs`). |
| `AI` | Workers AI | The automatic check of each new picture as an account sets it, by `@cf/cloudflare/clef-flash` (`checkPicture` in `service/do/review.mjs`). Without it, pictures are kept and not checked. |
| `EMAIL` | Email Sending (`send_email`) | Backup-code emails, the operator's alerts, and the day's new pictures. |
| `OH_METRICS` | Workers Analytics Engine, dataset `open_hearts_relay` | A line of counts from each object: a minute after its last, and at once when its last socket closes, each with the seconds it covers (`tally` and `tallied` in `service/do/relay.mjs`). |

The preview relay (`[env.preview]`) binds `TABLE`, `HOUSEHOLD` and `BENCH` as objects of its own, `OH_STORE` to the previews' store (`open-hearts-store-preview`), and `CF_VERSION_METADATA`, and nothing else: no pictures bucket, so it carries no profile picture; no `KNOWN`, `AI` or `OH_RECORDS`; no `EMAIL`, so it sends no email; and no `OH_METRICS`. It has no schedule.

Its schedule (`triggers.crons`) runs once a day at 13:00 UTC. With a checker's credentials set, it wakes the `KnownPictures` object to try again anything left to do after a match, such as a report waiting on NCMEC's credentials. It deletes from `OH_PICTURES` each picture a year after it stopped being an account's, asks the checker in use again about each picture kept that no checker has cleared, for each account that set it, and hides any the check found should be hidden that isn't; when `alerts.pictures` is on, it also emails the operator the new ones.

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
| `FLUTTER` | `deploy.sh`, `build_phone.sh`, `e2e/build.sh`, `app/worker/build.sh` | The `flutter` command to run. |
| `DART` | `app/worker/build.sh` | The `dart` command to run. |
| `ANDROID_NDK_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT` | `crypto/build_android.sh` | Where to find the Android NDK. |
| `CARGO_HOME` | `crypto/wasm.sh` | Removed from paths inside the wasm, so that every machine builds the same bytes. |

What each script does with the Cloudflare API token, which is what the token needs to allow:

- `deploy.sh` publishes to the Pages project. `./oh deploy site` (before a production deploy) and `./oh deploy prune` list and delete its deployments.
- `./oh account delete` reads and deletes rows in `OH_STORE` (Workers KV Storage: Edit), and reads and rewrites kept games in `OH_RECORDS` (Workers R2 Storage: Edit).
- The other `./oh account` acts read rows and write orders in `OH_STORE` (Workers KV Storage: Edit), and, to take a name off, read and rewrite kept games in `OH_RECORDS` (Workers R2 Storage: Edit). `./oh account find` reads the notes of which accounts set a picture in `OH_PICTURES`, and `./oh account hold` and `./oh account release` copy pictures from it into `OH_RECORDS` and delete them there (Workers R2 Storage: Edit). `./oh config` and `./oh picture` read and write rows in `OH_STORE`.
- `./oh photodna put` and `./oh photodna get` write and read the PhotoDNA module in `open-hearts-private` (Workers R2 Storage: Edit).
- `infra/apply.mjs` reads every resource that `infra/cloudflare.mjs` defines, and with `--apply` changes them.
- The relay's deploy (`./oh deploy relay`, which runs `wrangler deploy` in `service/do`) reads the PhotoDNA module from `open-hearts-private` (Workers R2 Storage: Edit), and uploads the relay worker with its Durable Objects, its container image and its custom domain.

No script checks the token's permissions first. A missing permission shows as Cloudflare's own error, or for `infra/apply.mjs` as an `unread:` line.

### Tests and local runs

| Variable | Read by | What it is |
|---|---|---|
| `OH_DEAL_MEMO` | `packages/deal/lib/memo.dart` | `off` keeps no deal answers on disk. |
| `CHECK_PLAN` | `check.sh` | Any non-empty value: print what would run, and run nothing. |
| `CHROME_EXECUTABLE` | `check.sh` (`app` suite) | The Chrome that runs `app/test/web`. |
| `PLAYWRIGHT_BROWSERS_PATH` | `check.sh` (`app` suite) | Where to look for Playwright's Chromium when no other Chrome is found. |
| `OH_HOUSE_SECRET` | `service/bin/house.dart` | The house's secret. Without it, the house does not start. The browser suites' rig gives it BIP-340's third published pair (`rigHouse` in `e2e/drive.mjs`). |
| `OH_HOUSE_KEY` | `service/bin/house.dart` | The house the relay takes. A house whose secret is not this key's does not start. |
| `OH_SERVICE_KEY` | `service/bin/house.dart` | The house holds every seat to its licence under this key. |
| `OH_OPEN_HOUSE` | The Pages worker (`openHouse`) | Local mode: every device that asks is licensed, and `local:` sign-ins are accepted. Honoured only for a request to `localhost`, `127.0.0.1` or a `*.localhost` host (`isLocal`). The browser suites' rig sets it. |
| `OH_TURN_LOCAL` | The Pages worker (`turn`) | In local mode, the TURN URL that `turn` hands out, with fixed credentials. Nothing sets it now: no part of the game uses TURN, which stays for voice and video chat. |

### Build defines

Compile-time values the app reads with `String.fromEnvironment`. They are not environment variables.

| Define | Read in | Set by |
|---|---|---|
| `OH_SERVICE_KEY` | `app/lib/net/licence.dart` | `app/tool/defines.mjs`, `e2e/build.sh` |
| `OH_HOUSE_KEY` | `app/lib/net/licence.dart` (`houseKey`) | `app/tool/defines.mjs`, `e2e/build.sh` |
| `OH_APP_ORIGIN` | `app/lib/net/address_io.dart` | `app/tool/defines.mjs` |
| `OH_GOOGLE_CLIENT_ID`, `OH_APPLE_SERVICE_ID` | `app/lib/net/provider_tokens.dart` | `app/tool/defines.mjs` |
| `OH_APPLE_PRODUCT`, `OH_PLAY_PRODUCT`, `OH_PLAY_PACKAGE` | `app/lib/net/store_buying.dart` | `app/tool/defines.mjs` (not `OH_PLAY_PACKAGE`) |
| `OH_RELAYS` | `app/lib/net/relays.dart` | `app/tool/defines.mjs`: unset for production, and the preview relay for a preview. A comma list replaces the build's relays, and the remote config's. |
| `OH_BUILD_TAG`, `OH_BUILD_DATE` | `app/lib/build_info.dart` | `app/tool/defines.mjs`: the short commit, with `+` for a tree with uncommitted changes, and the UTC date. Without them a build says `dev`. |
| `OH_UPDATE_CHECK` | `app/lib/build_info.dart` | `app/tool/defines.mjs`: `true`, which turns the "new build" pill on for a deployed web build. |

## Remote config

The row `config|app` in `OH_STORE`, which the `config` handler serves to every device. The worker checks each field (`configOf` in `service/functions/config.mjs`), and the app checks each again (`RemoteConfig.parse` in `app/lib/net/remote_config.dart`). A field that fails its check is left at its default. An absent or unreadable row serves `CONFIG_DEFAULTS`.

| Field | Check | Default | Effect |
|---|---|---|---|
| `v` | Served, not read | `1` | The row's format version. |
| `live` | Boolean | `true` | `false` closes live play: the buttons and table links. Games in progress play on. |
| `offer` | Boolean | `true` | `false` hides the paid tier from devices that have not bought it. |
| `relays` | 1 to `MOST_RELAYS` `wss:` URLs on `openhearts.game` or a subdomain, with no user info. All must pass, or none is taken. | The build's (`ourRelay` in `app/lib/net/relays.dart`) | Replaces the build's relays, read at app start. A build served from a local host, or built with `OH_RELAYS`, ignores it. |
| `banner` | `id` matching `^[\w.-]{1,64}$`; `level` `warn` (anything else is `info`); `text` by two-letter language code, English required, each up to `LONGEST_SAY` characters | None | A line on the front door. |
| `update` | `before` as `YYYY-MM-DD`; optional `text` as for `banner` | None | Asks builds made before that day to update. A web build is made the day `deploy.sh` deploys it, and a phone build the day `build_phone.sh` or the `ios` workflow ran, which is before store review. So set `before` no later than the day the version in the stores was built, or that version is asked to update while the stores have nothing newer. |
| `feedback` | An `https:` URL or a `mailto:` address | The project's issues | Where "Tell us what's broken" sends a report. |
| `table` | See [Table clocks](#table-clocks). All fields pass, or none is served. | The standard table | The clocks of the tables the house seats in the pools, and of a friends' table this device starts. |
| `waits` | See the next table. | The app's own | How long the app waits on the network. |
| `leftEarlyMin` | A whole number from 0 to 60 (`LEFT_EARLY_BOUNDS`, held equal to `RemoteConfig.leftEarlyBounds` by `service/functions/config.test.mjs`). Served only when set. | The app's own: 5 | Minutes Play live waits before it seats a device again, after it left a game early ([the wait after leaving early](../explanation/live-play.md#the-wait-after-leaving-early)). 0 is no wait. The support page's answer on leaving early says "a few minutes", and the dialog before leaving says the number. |

Beside the row's fields, the `config` handler serves `notices`: each document's newest material or price change in `site/ledger.json`, for 60 days from the day it was published, as `[{document, date, revision, summary}]` with the summary in each language and `revision` only for a day's second version or later (`noticesOf` in `service/functions/notices.mjs`). The row can't set it.

The price, and where the terms and the privacy policy are, are not fields: the site publishes them, and they change only with it.

The `config` handler answers with `cache-control: public, max-age=60`. The app keeps the last answer for its next start, and asks again every `configEveryMin`.

### Waits

Each field of `waits` is taken on its own when it is a whole number within its bounds. Bounds are `WAITS_BOUNDS` in `service/functions/config.mjs` and `AppWaits.bounds` in `app/lib/net/remote_config.dart`; `service/functions/config.test.mjs` holds the two equal. Defaults are the `AppWaits` constructor. All values are milliseconds, except `configEveryMin`, which is minutes.

| Field | `AppWaits` field | What the app waits for |
|---|---|---|
| `licenceMs` | `licence` | The device's licence. |
| `householdMs` | `household` | A household code, claim, drop or device list. |
| `buyMs` | `buy` | Opening a checkout. |
| `turnMs` | `turn` | TURN credentials, for a call between seats. Nothing of a game goes over WebRTC. |
| `configMs` | `config` | This config. |
| `configEveryMin` | `configEvery` | How often an open app asks for this config again. |
| `relaySlowMs` | `relaySlow` | When the screen says a relay is slow. |
| `relayGiveUpMs` | `relayGiveUp` | When the app gives up on a relay. |
| `standingMs` | `standing` | The standings from the first relay. |
| `standingAllMs` | `standingAll` | The standings from the other relays. |
| `roomStartMs` | `roomStart` | How long after the last arrival a friends' room starts, once two are in. |
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
| `householdReadsPerHour` | An account's reads in an hour: device lists, profile reads, and backup codes shown or emailed. Also how much a device may ask of an account in an hour on a licence that the store where it asks doesn't back ([signed requests](service-api.md#signed-requests)). |
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

## Known images

The row `config|known` in `OH_STORE`. It is never served. The `KnownPictures` object reads it each time it asks about a picture, and the daily run as it starts (`checkerIn` in `service/do/checkers.mjs`), so a change takes effect without a deploy, within a minute or so as Workers KV shows it.

| Field | What it sets |
|---|---|
| `checker` | The checker of known images in use: `shield` (Arachnid Shield, the default) or `photodna` (Microsoft's PhotoDNA). Anything else, or no row, is `shield` (`knownSettingsOf`). |

What either checker said of a picture stands whichever is in use: a picture is asked about once, and only of the checker in use ([how it works](../explanation/relay.md#known-images-of-child-sexual-abuse)). [Switch the checker of known images](../how-to/handle-abuse-material.md#switch-the-checker-of-known-images).

## Table clocks

The clocks a table plays by, from the `table` field of the [remote config](#remote-config) row. The house takes them for the tables it seats in the pools: the relay reads the row and tells the house its `table`, as the `config` handler serves it, with every wake (`clocks` in `service/do/bench.mjs`), and a wake whose read of the row failed leaves the house with what it had. A friends' table's starter takes them from its own remote config. They ride in the signed start event (`TableSpec.timing` in `packages/table/lib/src/spec.dart`), every field said in full, so every side applies the same clocks to the referee's times. A start whose timing leaves a field out, names one this build does not know, or has one of the wrong type or out of bounds, is no table this build sits at (`TableTiming.exactly`). A `table` field in remote config that leaves a clock out gives today's standard for it; one with a field of the wrong type or out of bounds is not served at all (`tableTimingOf` in `service/functions/config.mjs`). A game kept before the referee is read with whatever timing it says.

Bounds: `TableTiming.bounds` in `packages/table/lib/src/timing.dart`, and the same values in `TABLE_TIMING_BOUNDS` in `service/functions/config.mjs`. All values are milliseconds.

| Field | Default in | What it times |
|---|---|---|
| `graceMs` | `TimeBank` in `packages/table/lib/src/time_bank.dart` | A person's grace per card, before the bank is touched. |
| `passGraceMs` | `TimeBank` | A person's grace for the pass. |
| `bankMs` | `TimeBank` | A person's thinking time per hand, beyond the graces. |
| `fixedMs` | `TimeBank` | A person's deal steps and audit, which their device answers by itself. |
| `botActsMs` | `TableTiming` in `packages/table/lib/src/timing.dart` | The house's time for a bot seat's card or pass. A bot's move is worked out, not thought about, so there is no grace in it and no bank behind it. |
| `botDealsMs` | `TableTiming` | The house's time for a bot seat's step of the deal or its audit, which wait on the deal's slow calls. |
| `houseGraceMs` | `TableTiming` | How long past either of those the house is waited for before the game ends as failed: time for a restarted house to come back and read the log where it left it. Nobody else can play a bot seat's cards. |
| `silenceMs` | `TableTiming` | How long a person's connection may stay closed, as the referee's log has it, before the table gives their seat to a bot at their turn, without waiting on their clock. Long enough for a reload. |

Three more clocks are fixed in code and are not in remote config: `unansweredMs` and `answerMs` (`packages/table/lib/src/relays.dart`), how long a device may hear nothing, with something it sent waiting longer than an answer takes, before it takes itself for cut off; and `downSaidAfterMs` (`LiveController` in `app/lib/live/live_controller.dart`), how long a line that has been up may be down before the screen says so ([a device cut off from the table](../explanation/live-play.md#a-device-cut-off-from-the-table)).

For how the clocks are used, see [live play](../explanation/live-play.md) and [the table's states](../explanation/table-states.md).
