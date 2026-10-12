# Service handlers and storage

This page lists what the Pages worker serves: the hosts it routes, every handler under `/api/`, the statements that requests and answers are signed with, and the rows it keeps.

For why the service works this way, see [the service](../explanation/service.md) and [the security model](../explanation/security-model.md).

## What one deployment holds

`deploy.sh` uploads one directory to the Pages project `open-hearts` (`PROJECT` in `deploy.sh`, `pages.project` in `infra/cloudflare.mjs`).

| Path in the upload | What | Made by |
|---|---|---|
| `/` | The marketing site, in each of its languages | `site/build.mjs` |
| `/_worker.js/` | The handlers: `service/functions/entry.mjs` as `index.js`, every other module in `service/functions/` except tests and fixtures, `config/openhearts.json` as `openhearts.config.mjs`, and `app/web/schnorr.wasm` | `deploy.sh` |
| `/play/` | The Flutter web build, with base `/`, and the review worker beside it | `flutter build web`, `app/worker/build.sh` |
| `/play/build-info.json` | The build's tag and date, which the app's update check polls | `deploy.sh` |

## Hosts

The worker routes by host (`serveStatic` and the default `fetch` in `service/functions/worker.mjs`). The browser suites' rig serves the same routes on stand-in hosts (`appHostFor`, `isAppHost`).

| Host | `/api/<name>` | Every other path |
|---|---|---|
| `play.openhearts.game` (rig: `play.openhearts.localhost`) | The handlers | The app at the root. A path with no file extension (`appPage`) is the build's `/play/` page; any other path is that file under `/play/`. |
| `openhearts.game` (rig: `openhearts.localhost`) | 404, with `{"error": "the service has moved to <app host>"}` | The site. `/play` and `/play/…` are 404. `/carry` and `/carry.html` may be framed by the app's host only (`framedBy`). In the rig, links to `https://play.openhearts.game/` point at the rig's app host. |
| Any other host: a preview (`*.open-hearts.pages.dev`), or `127.0.0.1` in the rig | The handlers | The site at the root, with its links to `https://play.openhearts.game/` pointed at this host's `/play/`. The app at `/play/`, with the page's `<base href="/">` moved to `/play/` (`underPlay`). |

A name that is not a handler answers 404 with `{"error": "no such handler"}`.

## Handlers

Every handler is in `ROUTES` in `service/functions/worker.mjs`, and is reached as `/api/<name>`. In the **Signed** column, "Yes" means the request goes through `signedFor` (see [Signed requests](#signed-requests)), and the value is what the request signs as its `what` line.

| Handler | Method | Signed | Who may call it | Implemented by | What it does |
|---|---|---|---|---|---|
| `config` | GET | No | Anyone | `configRoute`, `configOf` | Serves the [remote config](configuration.md#remote-config). |
| `health` | GET, HEAD | No | Anyone; the monitors | `healthRoute`, `healthOf` | `{ok, store, stripe}`: 200 when the store reads and Stripe knows the price, 503 otherwise. |
| `licence` | POST | Yes, empty | Any device | `licenceRoute`, `licence` | The device's licence, or 402 when no subscription stands behind it. |
| `activate` | POST | Yes, `<want> <seated>` | A device of an account | `activateRoute`, `activate` | Makes the device its account's device in use, or confirms that it still is. `want` is `open`, `take` or `renew`. Answers an activation, or 409. |
| `checkout` | POST | Yes, empty | Any device; `back` and `cancelled` must be on the same site (`sameSite`) | `checkoutRoute`, `checkout` | Opens a Stripe Checkout session, in subscription mode, for this device. |
| `stripe` | POST | No; Stripe's `stripe-signature` header (`webhookSigned`) | Stripe | `stripeRoute`, `record` | Stripe's webhook: makes the account, binds the paying device, dates the subscription. |
| `manage` | POST | Yes, empty | A device of an account with a Stripe subscription; 409 for a store subscription | `manageRoute`, `manage` | Opens Stripe's billing portal. |
| `store` | POST | Yes, the proof | Any device with an App Store signed transaction or a Play purchase token | `storeRoute`, `appleTransaction`, `playPurchase`, `bindPurchase` | Binds the purchase and returns the device's licence. |
| `apple` | POST | No; a JWS chained to Apple's root (`appleSigned`) | App Store Server Notifications V2 | `appleRoute` | Dates the subscription. |
| `play` | POST | No; a Google ID token from Pub/Sub (`pushedByPlay`) | Google Play real-time developer notifications | `playRoute` | Dates the subscription. |
| `ticket` | POST | Yes, empty | A device of an account | `ticketRoute`, `ticketFor` | A one-use household code another device can join with. |
| `claim` | POST | Yes, the code | Any device holding a code | `claimRoute`, `claimWith`, `redeemBackup` | Spends a household code or a backup code, brings the device into the account, and returns its licence. |
| `devices` | POST | Yes, the key to drop, or empty | A device of an account | `devicesRoute`, `dropDevice` | Lists the account's devices, the one in use and the linked sign-in; can drop a device. |
| `backups` | POST | Yes, `rotate`, `send` or empty | A device of an account | `backupsRoute`, `backupsFor` | Shows, replaces or emails the account's backup codes. |
| `profile` | POST | Yes, the profile text, or empty for a read | Read: a device of an account whose subscription stands. Write: the account's device in use | `profileRoute`, `profileRead`, `profileWritten` | Reads or writes the account's profile. See [Profile](#profile). |
| `waiting` | POST | Yes, `<pool> <target>` | A device of an account whose subscription stands | `waitingRoute`; `alertWaiting` in `service/functions/alerts.mjs` | Tells the operator that a subscriber is waiting for a person. Answers `{ok: true}` whether or not anyone was told. |
| `attest` | POST | Yes, empty | A device of an account | `signInRoute`, `attest` | Links an Apple or Google sign-in to the device's account. |
| `supersede` | POST | Yes, empty | Any device whose sign-in is linked to an account | `signInRoute`, `supersede` | Brings the device into the account that the sign-in is linked to. |
| `apple-id` | POST | No; a JWT signed with Apple's sign-in keys (`appleIdNotice`) | Sign in with Apple server-to-server notifications | `appleIdRoute`, `unlinkSignIn` | Unlinks a sign-in whose person stopped using it with the app, or whose Apple Account was deleted. |
| `turn` | POST | Yes, empty | A device whose subscription stands | `turn`, `mint` | Cloudflare Realtime TURN credentials. |
| `record` | POST | Yes, the table ID | The device in use of an account whose subscription stands, seated at the table, with signed events of its own in the record; at most `recordsPerHour` an hour | `recordRoute`; `keepRecord` in `service/functions/records.mjs` | Keeps a finished game's record. The first copy is kept. Where the service has its keys, a record whose person's seat has no licence the service signed for its key, or whose account sits twice, is refused with 403 (`licenceProblem`). |
| `review` | POST | Yes, the table ID | The device in use of an account whose subscription stands, while the account is not seated at that table | `reviewRoute`; `recordResponse` in `service/functions/records.mjs` | Serves a kept game's record. |

Every handler with a signed request also answers an `OPTIONS` preflight, as does `config`.

## Signed requests

A signed request's body carries `key` (64 hex characters), `at` (the second it was made, as an integer) and `sig` (128 hex characters).

| Statement | Lines, separated by `\n` | Signed by | Made by | Checked by |
|---|---|---|---|---|
| A request | `oh-request/1`, the handler's name, the key, `at`, the `what` line | The device's key | `signedAsk` and `requestDigest` in `app/lib/net/licence.dart` | `requestStatement` and `askedBy` in `service/functions/worker.mjs` |
| A licence | `oh-licence/2`, the device's key, the account, the last day (`YYYY-MM-DD`, UTC), the plan (`PLAN`) | The service key (`OH_SERVICE_SECRET`) | `licenceFor` in `service/functions/worker.mjs` | `Licence` in `packages/table/lib/src/licence.dart` |
| An activation | `oh-active/1`, the account, the device's key, the epoch, the last second (Unix time) | The service key | `activationFor` in `service/functions/worker.mjs` | `Activation` in `packages/table/lib/src/licence.dart`; `activationOf` in `service/do/relay.mjs` |

Each signature is BIP-340 over the SHA-256 hex digest of the statement's text (`digestOf`). A request whose `at` is further from the service's clock than `requestToleranceS` ([service settings](configuration.md#service-settings)) is refused with 401. An activation lasts at most `ACTIVATION_S`, and never past the end of the day the subscription is paid to.

Other strings are hashed or keyed with a tag of their own, and never signed:

| String | Hashed or keyed as | Used for | Where |
|---|---|---|---|
| `oh-backup/1\n<code>` | SHA-256 | The key of a backup code's row | `backupRow` |
| `oh-signin/1\n<key>` | SHA-256 | The nonce a sign-in token must carry | `whoSignedIn`; `signInNonce` in `app/lib/net/sign_in.dart` |
| `oh-store/1\n<key>` | SHA-256 | The device's account ID in a store's records: Play's obfuscated account ID and Apple's `appAccountToken` | `storeAccountOf`; `app/lib/net/store_buying.dart` |
| `oh-play/1\n<token>` | SHA-256 | A Play subscription's ID, `google:<digest>` | `playSubscriptionOf` |
| `<provider>:<subject>` | HMAC-SHA-256 under `OH_ID_HMAC` | A sign-in's row, `LOGIN#<provider>#<hmac>` | `loginRow` |
| `oh-bench/1\n<key>` | HMAC-SHA-256 under `OH_JUROR_SECRET` | A backup juror's mark at the relay | `benchMark` in `service/do/relay.mjs` |

Unless a **Where** cell names another file, the function is in `service/functions/worker.mjs`.

## Request limits

| Limit | Applies to | Constant | Over it |
|---|---|---|---|
| Body size | Every handler not listed below | `MOST_BODY` in `service/functions/worker.mjs` | 400 for a signed request (the body is not read) and for `play`; 413 for `apple-id` |
| Body size | `profile` | `MOST_PROFILE_BODY` | 400 |
| Body size | `record` | `recordMost` in `service/functions/records.mjs`, plus 4096 | 400; a record itself over `recordMost` is 413 |
| Body size | `stripe`, `apple` | `MOST_EVENT` | 413 |
| Rate per address | `/api/` on `play.openhearts.game`, except `stripe`, `apple`, `apple-id` and `play`; and the relay's host | The `http_ratelimit` rule in `infra/cloudflare.mjs` | Blocked by Cloudflare |
| Rate per account | Each account's operations | [Service settings](configuration.md#service-settings) | 429 |

## CORS

The worker echoes an allowed `Origin` in `access-control-allow-origin`, with `vary: origin` (`allowedOrigin` and `cors` in `service/functions/worker.mjs`):

- `openhearts.game`, `www.openhearts.game` and `play.openhearts.game`.
- `open-hearts.pages.dev` and any `*.open-hearts.pages.dev`.
- `localhost`, `127.0.0.1` and any `*.localhost`, only when the request itself went to a local host (`isLocal`).

A preflight answers 204 with the handler's method and `OPTIONS`, the header `content-type`, and a `max-age` of a day (`preflight`).

## Storage

Everything the worker keeps is in the Workers KV namespace `OH_STORE`, one key per row, written `<PK>|<SK>` (`storeOf` in `service/functions/worker.mjs`). Tests and local mode use a `Map` behind the same calls (`memoryStore`).

| PK | SK | Holds | Expires after |
|---|---|---|---|
| `KEY#<key>` | `ENTITLEMENT` | `account`, `licensed_until`, `at` | Never |
| `ACCOUNT#<account>` | `META` | `subscription`, `created_at` | Never |
| `ACCOUNT#<account>` | `DEVICE#<key>` | `bound_at` | Never |
| `ACCOUNT#<account>` | `TICKET` | The outstanding code: `code`, `expires_at`, `devices` | `TICKET_KEPT_S` |
| `ACCOUNT#<account>` | `BACKUP` | `codes` (each `code`, `used_at`), `made_at`, `emailed_at` | Never |
| `ACCOUNT#<account>` | `LOGIN` | `provider`, `login` (the key of its `LOGIN#` row), `at` | Never |
| `ACCOUNT#<account>` | `ACTIVE` | The device in use: `key`, `epoch`, `at`, `seated`, `seated_at`, `tags` (the relay objects it was seen at). Only where `HOUSEHOLD` is not bound; otherwise the `Household` object keeps it in its own storage. | Never |
| `ACCOUNT#<account>` | `PROFILE` | `name`, `icon`, `color`, `picture`, `version`, `updated_at` | Never |
| `SUB#<subscription>` | `META` | `source`, `txn_ref`, `renews_at`, `cancelled_at`, `event_at`, and `final` when set | Never |
| `SUB#<subscription>` | `ACCOUNT` | `account` | Never |
| `SUB#<subscription>` | `CUSTOMER` | The Stripe `customer`, for the billing portal | Never |
| `TICKET#<code>` | `META` | `account`, `expires_at`, `used_at`, `made_by`, `used_by` | `TICKET_KEPT_S` |
| `BACKUP#<digest>` | `META` | `account` | Never |
| `LOGIN#<provider>#<hmac>` | `IDENTITY` | `account`, `created_at` | Never |
| `ALERT#subscribed` | `<subscription>` | `at`: when the operator was told of the subscription | `SUBSCRIBED_DAYS` in `service/functions/alerts.mjs` |
| `ALERT#waiting` | `<subscription>` | `at`: when the operator was told a subscriber was waiting | `WAITING_MINUTES` in `service/functions/alerts.mjs` |
| `config` | `app` | The [remote config](configuration.md#remote-config) | Never |
| `config` | `service` | The [service settings](configuration.md#service-settings) | Never |
| `config` | `relay` | The [relay settings](configuration.md#relay-settings) | Never |

A subscription's ID is `sub_…` for Stripe, `apple:<original transaction ID>` for the App Store, `google:<digest>` for Google Play, and `local-<16 hex>` in local mode.

`service/tool/forget.mjs` deletes an account's rows (`forgetAccount`), and takes its name off its kept games (`anonymizeGames` in `service/functions/records.mjs`).

The worker keeps finished games' records in the R2 bucket `OH_RECORDS`, as `tables/<table>.json`, gzipped, with the sender's key as the custom metadata `from` (`keepRecord` in `service/functions/records.mjs`). A record rewritten when an account is forgotten keeps its gzip and content type, and has no `from`. An account forgotten on request is marked as `forgotten/<account>` in the same bucket. A record sent later is kept without the names of seats whose licence names a marked account, and is refused with 422 if `JSON.stringify` would not give back the text as it was sent.

## Profile

The `profile` handler takes the profile as JSON text and checks it with `profileOf` in `service/functions/worker.mjs`. `service/functions/profile.test.mjs` holds the limits equal to the app's.

| Field | Accepted | Limit in the worker | Limit in the app |
|---|---|---|---|
| `name` | A string, already trimmed, with no control characters | `PROFILE_NAME_MOST` characters | `Identity.longestName` in `app/lib/identity.dart` |
| `icon` | `null`, or one of `PROFILE_ICONS` | `PROFILE_ICONS` | `AvatarIcons.all` in `app/lib/avatar.dart` |
| `color` | `null`, or a whole number from 0 up to, but not including, `PROFILE_COLOURS` | `PROFILE_COLOURS` | `AvatarIcons.paletteSize` in `app/lib/avatar.dart` |
| `picture` | `null`, or base64 of a JPEG | `PROFILE_PICTURE_MOST` bytes | `Avatar.maxPictureBytes` in `app/lib/avatar.dart` |

A profile with any other field is refused, and so is one whose text is longer than `PROFILE_TEXT_MOST`. A refused profile answers 400. A write from a device that is not the account's device in use answers 409.
