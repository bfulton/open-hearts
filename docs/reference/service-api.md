# Service handlers and storage

This page lists what the Pages worker serves: the hosts it routes, every handler under `/api/`, the statements that requests and answers are signed with, and the rows it keeps.

For why the service works this way, see [the service](../explanation/service.md) and [the security model](../explanation/security-model.md).

## What one deployment holds

`deploy.sh` uploads one directory to the Pages project `open-hearts` (`pages.project` in `infra/cloudflare.mjs`).

| Path in the upload | What | Made by |
|---|---|---|
| `/` | The marketing site, in each of its languages | `site/build.mjs` |
| `/_worker.js/` | The handlers: `service/functions/entry.mjs` as `index.js`, every other module in `service/functions/` except tests and fixtures, `config/openhearts.json` as `openhearts.config.mjs`, and `app/web/schnorr.wasm` | `deploy.sh` |
| `/play/` | The Flutter web build, with base `/`, and the review worker beside it | `flutter build web`, `app/worker/build.sh` |
| `/play/build-info.json` | The build's tag and date, which the app's update check polls | `deploy.sh` |

## Hosts

The worker routes by host. The default `fetch` in `service/functions/worker.mjs` answers `/api/` and hands every other path to `serveStatic`, which, like every other function this section names, is in `service/functions/app_host.mjs`. The browser suites' rig serves the same routes on stand-in hosts (`appHostFor`, `isAppHost`).

| Host | `/api/<name>` | Every other path |
|---|---|---|
| `play.openhearts.game` (rig: `play.openhearts.localhost`) | The handlers | The app at the root. A path with no file extension (`appPage`) is the build's `/play/` page; any other path is that file under `/play/`. |
| `openhearts.game` (rig: `openhearts.localhost`) | 404, with `{"error": "the service has moved to <app host>"}` | The site. `/play` and `/play/…` are 404. `/carry` and `/carry.html` may be framed by the app's host only (`framedBy`). In the rig, links to `https://play.openhearts.game/` point at the rig's app host. |
| Any other host: a preview (`*.open-hearts.pages.dev`), or `127.0.0.1` in the rig | The handlers on a preview, and in the rig; on a production deployment, 404 with `{"error": "no such handler"}` (`answersApi` in `service/functions/worker.mjs`), as at `open-hearts.pages.dev` or a deployment's own address, where the zone's rate limit does not reach | The site at the root, with its links to `https://play.openhearts.game/` pointed at this host's `/play/`. The app at `/play/`, with the page's `<base href="/">` moved to `/play/` (`underPlay`). |

A name that is not a handler answers 404 with `{"error": "no such handler"}`.

## Handlers

Every handler is in `ROUTES` in `service/functions/worker.mjs`, and is reached as `/api/<name>`. The first function under **Implemented by** is in that file too. In the **Signed** column, "Yes" means the request goes through `signedFor` in `service/functions/http.mjs` (see [Signed requests](#signed-requests)), and the value is what the request signs as its `what` line.

| Handler | Method | Signed | Who may call it | Implemented by | What it does |
|---|---|---|---|---|---|
| `config` | GET | No | Anyone | `configRoute`; `configOf` in `service/functions/config.mjs`, `noticesOf` in `service/functions/notices.mjs` | Serves the [remote config](configuration.md#remote-config), with the `notices` of changes to the terms and the privacy policy. |
| `health` | GET, HEAD | No | Anyone; the monitors | `healthRoute`; `healthOf` in `service/functions/health.mjs` | `{ok, store, stripe}`: 200 when the store reads and Stripe knows the price, 503 otherwise. |
| `licence` | POST | Yes, empty | Any device | `licenceRoute`; `licence` in `service/functions/licence.mjs` | The device's licence, or 402 when no subscription stands behind it, or 403 with `suspended: true` when its account is suspended. |
| `activate` | POST | Yes, `<want> <seated>` | A device of an account | `activateRoute`; `activate` in `service/functions/household.mjs` | Makes the device its account's device in use, or confirms that it still is. `want` is `open`, `take` or `renew`. Answers an activation, with `profile`, the version of the account's profile; or 409; or 403 with `suspended: true` when the account is suspended. |
| `checkout` | POST | Yes, empty | Any device; `back` and `cancelled` must be on the same site (`sameSite` in `service/functions/stripe.mjs`) | `checkoutRoute`; `checkout` in `service/functions/stripe.mjs` | Opens a Stripe Checkout session, in subscription mode, sold through Link (Managed Payments), for this device. The optional `lang` is the app's language, one of the site's; Stripe's page is in it, and the subscription is marked with it (`checkoutLanguage`). The buyer cannot pay without ticking Stripe's box agreeing to the terms and the privacy policy, and Link's page says that subscribing authorizes Link to charge them until they cancel. 403 with `suspended: true` for a device of a suspended account. |
| `stripe` | POST | No; Stripe's `stripe-signature` header (`webhookSigned` in `service/functions/stripe.mjs`) | Stripe | `stripeRoute`; `record` and `endRefunded` in `service/functions/stripe.mjs` | Stripe's webhook: makes the account and binds the paying device, in the subscription's turn; dates the subscription; and ends a subscription one of whose payments was refunded (`charge.refunded`), answering 502 when Stripe could not be asked, so that Stripe sends the event again. A checkout whose binding or backup codes the account's turn could not do yet (400 from a relay that does not know the op, 429 or 5xx) is answered 503, for the same reason. |
| `manage` | POST | Yes, empty | A device of an account with a Stripe subscription; 409 for a store subscription | `manageRoute`; `manage` in `service/functions/stripe.mjs` | Opens Stripe's billing portal. |
| `store` | POST | Yes, the proof | Any device with an App Store signed transaction or a Play purchase token | `storeRoute`; `appleTransaction` and `playPurchase` in `service/functions/stores.mjs`, `bindPurchase` in `service/functions/subscriptions.mjs` | Binds the purchase and returns the device's licence. |
| `apple` | POST | No; a JWS chained to Apple's root (`appleSigned` in `service/functions/x509.mjs`) | App Store Server Notifications V2 | `appleRoute` | Dates the subscription. |
| `play` | POST | No; a Google ID token from Pub/Sub (`pushedByPlay` in `service/functions/stores.mjs`) | Google Play real-time developer notifications | `playRoute` | Dates the subscription. |
| `ticket` | POST | Yes, empty | A device of an account | `ticketRoute`; `ticketFor` in `service/functions/accounts.mjs` | A one-use household code another device can join with. |
| `claim` | POST | Yes, the code | Any device holding a code | `claimRoute`; `claimWith` and `redeemBackup` in `service/functions/accounts.mjs` | Spends a household code or a backup code, brings the device into the account, and returns its licence. |
| `devices` | POST | Yes, the key to drop, or empty | A device of an account | `devicesRoute`; `dropDevice` in `service/functions/household.mjs` | Lists the account's devices, the one in use and the linked sign-in; can drop a device. |
| `backups` | POST | Yes, `rotate`, `send` or empty | A device of an account | `backupsRoute`; `backupsFor` in `service/functions/accounts.mjs` | Shows, replaces or emails the account's backup codes. |
| `profile` | POST | Yes, the profile text, or empty for a read | Read: a device of an account whose subscription stands. Write: the account's device in use | `profileRoute`; `profileRead` and `profileWritten` in `service/functions/profile.mjs` | Reads or writes the account's profile. See [Profile](#profile). |
| `waiting` | POST | Yes, `<pool> <target>` | A device of an account whose subscription stands | `waitingRoute`; `alertWaiting` in `service/functions/alerts.mjs` | Tells the operator that a subscriber is waiting for a person. Answers `{ok: true}` whether or not anyone was told. |
| `report` | POST | Yes, `<about> <what>` | A device of an account whose subscription stands, about another account | `reportRoute`; `reportOf` and `alertReport` in `service/functions/alerts.mjs` | Emails the operator a player's report of another: `about` (the account reported), `what` (`picture`, `name` or `other`), and optionally `table`, the `name` and `picture` (its SHA-256) the reporter saw, and a `note` of up to `REPORT_NOTE_MOST` characters. Sent whatever the `alerts` switches say. The same report from the same account is sent once a day; 429 after `REPORTS_A_DAY` in a day; 503 when it could not be sent, which is not counted. |
| `delete` | POST | Yes, empty | A device on an account (its `DEVICE#` row there) | `deleteRoute`; `deleteAccount` in `service/functions/deletion.mjs` | Deletes the device's account: ends each web subscription of it still running in Stripe, marks it forgotten and takes its name off its kept games, then deletes its rows and cuts its device in use off at the relay, with the reason `deleted:`. Answers `{deleted: true}`, the same under a legal hold, where only the asking is noted (`deleteAsked`). 404 `no account` for a device on none, which is what a deletion already done answers; 502 when Stripe did not answer, with nothing deleted. |
| `attest` | POST | Yes, `<provider> <token>` | A device of an account | `signInRoute`; `attest` in `service/functions/logins.mjs` | Links an Apple or Google sign-in to the device's account. The provider and the token are both signed, so a request taken off the wire cannot be sent again with another sign-in's token, and one signed over nothing, as these once were, is refused with 401 `not signed by that key`. A `provider` or a `token` that is not a string is refused with 401 `that sign-in does not check out`. |
| `supersede` | POST | Yes, `<provider> <token>` | Any device whose sign-in is linked to an account | `signInRoute`; `supersede` in `service/functions/signin.mjs` | Brings the device into the account that the sign-in is linked to. Signed and refused as `attest` is. |
| `apple-id` | POST | No; a JWT signed with Apple's sign-in keys (`appleIdNotice` in `service/functions/signin.mjs`) | Sign in with Apple server-to-server notifications | `appleIdRoute`; `unlinkSignIn` in `service/functions/logins.mjs` | Unlinks a sign-in whose person stopped using it with the app, or whose Apple Account was deleted. |
| `turn` | POST | Yes, empty | A device whose subscription stands | `turn`; `mint` in `service/functions/turn.mjs` | Cloudflare Realtime TURN credentials. |
| `record` | POST | Yes, the table ID | The device in use of an account whose subscription stands, seated at the table, with signed events of its own in the record; at most `recordsPerHour` an hour | `recordRoute`; `keepRecord` in `service/functions/records.mjs` | Keeps a finished game's record: the copy that carries the house's checked result (`vouches` in `service/functions/records.mjs`), or the first copy while none does. A kept copy that does not is replaced by one that does, on the etag read, and a kept copy that does is never replaced; either way the sender's own seat's name is kept, and put beside the copy that is kept when the sender's copy is not (`mergedInto`). Answers `{kept: true}`, with `already: true` when a copy stays; 409 when the kept copy kept changing under five tries. A record in a form other than the one kept now (`recordVersion` in `service/functions/records.mjs`) is refused with 400. Where the service has its keys, a record whose person's seat has no licence the service signed for its key, or whose account sits twice, is refused with 403 (`licenceProblem`). |
| `review` | POST | Yes, the table ID | The device in use of an account whose subscription stands, while the account is not seated at that table | `reviewRoute`; `recordResponse` in `service/functions/records.mjs` | Serves a kept game's record. |
| `order` | POST | No; the body names an order, `{order}`, which must be in `OH_STORE`, where only the operator writes | The operator's `./oh account` and `./oh terms notify` | `orderRoute`; `carryOut` in `service/functions/suspension.mjs`, `carryOutNotice` in `service/functions/notices.mjs` | Carries out the operator's order for an account in its turn: `suspend`, `terminate`, `lift`, `remove` or `restore`. A `lift` of a terminated account is answered 409. Or a `notice`: emails each of up to `NOTICES_PER_ORDER` web subscriptions one email of the changes in `OH_LEDGER` it names that the subscription wasn't told of (each document's newest change that subscribers are told of, with the earlier ones it covers), at the address Stripe has, once, and answers how many were told, told already, not told and why, or not sent. 404 until the store shows the order, and for an account that doesn't exist; 410 once the order is older than `ORDER_KEPT_S`. Not counted against the account's allowances. |

Every handler with a signed request also answers an `OPTIONS` preflight, as does `config`.

## Signed requests

A signed request's body carries `key` (64 hex characters), `at` (the second it was made, as an integer) and `sig` (128 hex characters).

| Statement | Lines, separated by `\n` | Signed by | Made by | Checked by |
|---|---|---|---|---|
| A request | `oh-request/1`, the handler's name, the key, `at`, the `what` line | The device's key | `signedAsk` and `requestDigest` in `app/lib/net/licence.dart` | `requestStatement` and `askedBy` in `service/functions/http.mjs` |
| A licence | `oh-licence/2`, the device's key, the account, the last day (`YYYY-MM-DD`, UTC), the plan (`PLAN`) | The service key (`OH_SERVICE_SECRET`) | `licenceFor` in `service/functions/licence.mjs` | `Licence` in `packages/table/lib/src/licence.dart`; `licensedAccount`, `accountAsking` and `heldAccount` in `service/functions/licence.mjs` |
| An activation | `oh-active/1`, the account, the device's key, the epoch, the last second (Unix time) | The service key | `activationFor` in `service/functions/licence.mjs` | `Activation` in `packages/table/lib/src/licence.dart`; `activationOf` in `service/do/relay.mjs` |

Every signed request from the app also carries `licence`, the licence the device holds, when it holds one (`askHandler` in `app/lib/net/household.dart`, and `iceServersFor` in `app/lib/net/turn.dart`). A licence counts only if it is this device's, signed by the service with a signature of 128 hex characters, and not run out (`licensedAccount`). A device just brought in by its account's `Household` object somewhere else is known to that object before the store at the handler's end has heard of it (see [the service](../explanation/service.md#accounts)):

- `activate`, `profile`, `devices`, `backups`, `ticket` and `attest` ask the account the licence names, and otherwise the account the store names (`accountAsking` in `service/functions/licence.mjs`). The account's object decides.
- `turn`, `waiting`, `report`, `record` and `review` take the store's word where it backs the licence. Where the store names another account or none, they ask the object of the account the licence names whether it holds the device (`heldAccount`, and the `held` operation in `service/functions/household.mjs`).
- `delete` takes the store's word alone.

What an account's object is asked on a licence the store doesn't back is counted against an allowance of its own, `householdReadsPerHour` an hour, apart from the account's own devices' allowances.

Each signature is BIP-340 over the SHA-256 hex digest of the statement's text (`digestOf` in `service/functions/rows.mjs`). A request whose `at` is further from the service's clock than `requestToleranceS` ([service settings](configuration.md#service-settings)) is refused with 401. An activation lasts at most `ACTIVATION_S` (in `service/functions/licence.mjs`), and never past the end of the day the subscription is paid to.

Other strings are hashed or keyed with a tag of their own, and never signed:

| String | Hashed or keyed as | Used for | Where |
|---|---|---|---|
| `oh-backup/1\n<code>` | SHA-256 | The key of a backup code's row | `backupRow` in `service/functions/accounts.mjs` |
| `oh-signin/1\n<key>` | SHA-256 | The nonce a sign-in token must carry | `whoSignedIn` in `service/functions/signin.mjs`; `signInNonce` in `app/lib/net/sign_in.dart` |
| `oh-store/1\n<key>` | SHA-256 | The device's account ID in a store's records: Play's obfuscated account ID and Apple's `appAccountToken` | `storeAccountOf` in `service/functions/stores.mjs`; `app/lib/net/store_buying.dart` |
| `oh-play/1\n<token>` | SHA-256 | A Play subscription's ID, `google:<digest>` | `playSubscriptionOf` in `service/functions/stores.mjs` |
| `<provider>:<subject>` | HMAC-SHA-256 under `OH_ID_HMAC` | A sign-in's row, `LOGIN#<provider>#<hmac>` | `loginRow` in `service/functions/logins.mjs` |

## Request limits

| Limit | Applies to | Constant | Over it |
|---|---|---|---|
| Body size | Every handler not listed below | `MOST_BODY` in `service/functions/http.mjs` | 400 for a signed request (the body is not read) and for `play`; 413 for `apple-id` |
| Body size | `profile` | `MOST_PROFILE_BODY` in `service/functions/profile.mjs` | 400 |
| Body size | `record` | `recordMost` in `service/functions/records.mjs`, plus 4096 | 400; a record itself over `recordMost` is 413 |
| Body size | `stripe`, `apple` | `MOST_EVENT` in `service/functions/http.mjs` | 413 |
| Rate per address | `/api/` on `play.openhearts.game`, except `stripe`, `apple`, `apple-id` and `play`; and the relay's host | The `http_ratelimit` rule in `infra/cloudflare.mjs` | Blocked by Cloudflare |
| Rate per account | Each account's operations | [Service settings](configuration.md#service-settings) | 429 |

## CORS

The worker echoes an allowed `Origin` in `access-control-allow-origin`, with `vary: origin` (`allowedOrigin` and `cors` in `service/functions/http.mjs`):

- `openhearts.game`, `www.openhearts.game` and `play.openhearts.game`.
- `open-hearts.pages.dev` and any `*.open-hearts.pages.dev`.
- `localhost`, `127.0.0.1` and any `*.localhost`, only when the request itself went to a local host (`isLocal` in `service/functions/settings.mjs`).

A preflight answers 204 with the handler's method and `OPTIONS`, the header `content-type`, and a `max-age` of a day (`preflight` in `service/functions/http.mjs`).

## Storage

Everything the worker keeps is in the Workers KV namespace `OH_STORE`, one key per row, written `<PK>|<SK>` (`storeOf` in `service/functions/rows.mjs`). Tests and local mode use a `Map` behind the same calls (`memoryStore`).

| PK | SK | Holds | Expires after |
|---|---|---|---|
| `KEY#<key>` | `ENTITLEMENT` | `account`, `licensed_until`, `at`, and `suspended` while the account is | Never |
| `ACCOUNT#<account>` | `META` | `subscription`, `created_at`, and `before`, the subscriptions it had before this one | Never |
| `ACCOUNT#<account>` | `DEVICE#<key>` | `bound_at` | Never |
| `ACCOUNT#<account>` | `TICKET` | The outstanding code: `code`, `expires_at`, `devices` | `TICKET_KEPT_S` in `service/functions/accounts.mjs` |
| `ACCOUNT#<account>` | `BACKUP` | `codes` (each `code`, `used_at`), `made_at`, `emailed_at`, `acknowledged` (the last web subscription whose purchase was emailed) | Never |
| `ACCOUNT#<account>` | `LOGIN` | `provider`, `login` (the key of its `LOGIN#` row), `at` | Never |
| `ACCOUNT#<account>` | `ACTIVE` | The device in use: `key`, `epoch`, `at`, `seated`, `seated_at`, `tags` (the relay objects it was seen at), and `suspended` while the account is. Only where `HOUSEHOLD` is not bound; otherwise the `Household` object keeps it in its own storage. | Never |
| `ACCOUNT#<account>` | `PROFILE` | `name`, `icon`, `color`, `picture`, `version`, `updated_at` | Never |
| `ACCOUNT#<account>` | `SUSPENDED` | `since`: the day the account was suspended; `terminated`: the day it was ended, for a terminated account | Never; deleted when the suspension is lifted, which a terminated account never is |
| `ACCOUNT#<account>` | `HELD` | What the operator took off the profile, to put back: `name`, `picture`, and `at`; under a legal hold, what later removals took, in `later` | Never; deleted when put back |
| `ACCOUNT#<account>` | `HOLD` | A legal hold (`service/functions/holds.mjs`): `since`, `until` (a year on), `ref` (the report's number), and `deleteAsked`, the day a deletion was asked for while held. While it is there, the account's rows are not deleted and nothing held is put back. | Never; deleted when released, a year on at the least |
| `SUB#<subscription>` | `META` | `source`, `txn_ref`, `renews_at`, `cancelled_at`, `event_at`, and `final` when set | Never |
| `SUB#<subscription>` | `ACCOUNT` | `account` | Never |
| `SUB#<subscription>` | `CUSTOMER` | The Stripe `customer`, for the billing portal | Never |
| `TICKET#<code>` | `META` | `account`, `expires_at`, `used_at`, `made_by`, `used_by` | `TICKET_KEPT_S` in `service/functions/accounts.mjs` |
| `BACKUP#<digest>` | `META` | `account` | Never |
| `LOGIN#<provider>#<hmac>` | `IDENTITY` | `account`, `created_at` | Never |
| `ORDER#<id>` | `META` | The operator's order: `account`, `act`, `at`, and for `remove`, `name` and `picture`; or, for a notice, `act` (`notice`), `changes` (`[{document, version, covers}]`: each document's newest change by its version, and the earlier versions its summary says too), `subscriptions` and `at` | `ORDER_KEPT_S` in `service/functions/suspension.mjs`; an account's order is deleted once carried out |
| `NOTICE#<document>@<version>` | `SUB#<subscription>` | That the web subscription was told of the change, named by its version in `site/ledger.json`: its day, and after the day's first version its revision (`2026-10-23.2`). `at`, and `lang` it was told in, or `unsent` and why (`no address`, `no such subscription`); `by`, the version whose email told of it, for one told by a later change's email. No address is kept. | When the account is deleted (`forgetAccount`); never, for a store subscription that is cancelled but still runs when `oh account delete` forgets its account (a web subscription is ended first, and its notes go) |
| `ALERT#subscribed` | `<subscription>` | `at`: when the operator was told of the subscription | `SUBSCRIBED_DAYS` in `service/functions/alerts.mjs` |
| `ALERT#waiting` | `<subscription>` | `at`: when the operator was told a subscriber was waiting | `WAITING_MINUTES` in `service/functions/alerts.mjs` |
| `ALERT#report` | `<account>\|<about>\|<what>` | `at`: when the operator was sent this account's report of `about` | A day |
| `ALERT#reports` | `<account>\|<day>` | `n`: how many reports the account sent that day | Two days |
| `config` | `app` | The [remote config](configuration.md#remote-config) | Never |
| `config` | `service` | The [service settings](configuration.md#service-settings) | Never |
| `config` | `relay` | The [relay settings](configuration.md#relay-settings) | Never |
| `config` | `pictures` | The pictures the relay withholds: `pictures`, each `sha256` (of the JPEG's bytes) and `until` (milliseconds); and `allowed`, when any are, the pictures the operator put back after the automatic check hid them, the same way. Read by every tag's object that keeps a lobby ([withheld pictures](../explanation/relay.md#withheld-pictures)). | Each entry after `WITHHELD_FOR_MS` in `service/functions/pictures.mjs`, or when its picture is put back; an allowed one is kept allowed while its copy is kept |

A subscription's ID is `sub_…` for Stripe, `apple:<original transaction ID>` for the App Store, `google:<digest>` for Google Play, and `local-<16 hex>` in local mode.

`./oh account delete` deletes an account's rows (`forgetAccount` in `service/functions/deletion.mjs`), and takes its name off its kept games (`anonymizeGames` in `service/functions/records.mjs`). The other `./oh account` acts write `ORDER#` rows, and `remove` takes a name off kept games the same way.

The worker keeps finished games' records in the R2 bucket `OH_RECORDS`, as `tables/<table>.json`, gzipped, with the sender's key as the custom metadata `from`, the accounts whose licences sit at its seats, comma-separated, as `accounts`, and `vouched: 1` when the copy carries the house's checked result (`keepRecord` in `service/functions/records.mjs`). A copy does when it is how the app writes a record with nothing more in it and its spec is the one its log starts; each entry is numbered by where it is and is an event, a connection opening, one closing or a tick; each event is the table's, from a person at the table or its house, has the keys of an event and no more, an id that is the hash of what it says and a signature that checks, whether or not the table reads it (an event of a kind no build knows, or with the body of none, is an entry every side skips, and counts like any); and a `result` by `OH_HOUSE_KEY` names a count of entries no greater than its own place and the hash of that many (`logHashes`, which `packages/table/test/log_hash.vectors.json` holds to `LogHash` in `packages/table/lib/src/log.dart`). The first copy is written only if none is kept (`etagDoesNotMatch`), and one that replaces another only if it is still the one read (`etagMatches`). The record keeps one name at most beside a seat, each put there by its own seat's device: from a copy, its sender's seat's name; and a name merged into the copy kept, with the same condition on its etag, when its sender's copy is not kept. A record rewritten when an account is forgotten keeps its gzip and content type; rewritten by the worker, it keeps its custom metadata too, and rewritten by `oh account delete`, it has none, since the API that tool writes through carries no custom metadata. A game with no `vouched` is checked as a copy sent is when the next copy for it arrives (`keptVouched`), and is marked again, with its `accounts`, if it carries the house's result; so a game the tool has rewritten, or one kept before the mark, is not replaced by a copy of the same game, and the names beside it stay. An account forgotten on request is marked as `forgotten/<account>` in the same bucket, and an account under a legal hold has a copy of each picture it set as `held/<account>/<sha256>.jpg`, written by `oh account hold` and by the relay when Arachnid Shield matches a picture the account set (`service/do/known.mjs`), and deleted only by `oh account release` (`service/functions/holds.mjs`). A name is not kept for a seat whose licence names a marked account, nor one the filter refuses or that is not a name a profile may hold (`nameFits`). A record whose names are not exactly its sender's own to keep (another seat's is in it, or its sender's is not to be kept) is refused with 422 if everything in it but the names is not what `JSON.stringify` writes, since the names cannot then be changed without changing what its events say; a record with no name to change is kept as it was sent, byte for byte.

## Profile

The `profile` handler takes the profile as JSON text and checks it with `profileOf` in `service/functions/profile.mjs`, where the worker's limits below are. `service/functions/profile.test.mjs` holds the limits equal to the app's.

| Field | Accepted | Limit in the worker | Limit in the app |
|---|---|---|---|
| `name` | A string, already trimmed, with no control characters | `PROFILE_NAME_MOST` characters | `longestName` in `packages/table/lib/src/names.dart` |
| `icon` | `null`, or one of `PROFILE_ICONS` | `PROFILE_ICONS` | `AvatarIcons.all` in `app/lib/avatar.dart` |
| `color` | `null`, or a whole number from 0 up to, but not including, `PROFILE_COLOURS` | `PROFILE_COLOURS` | `AvatarIcons.paletteSize` in `app/lib/avatar.dart` |
| `picture` | `null`, or base64 of a JPEG | `PROFILE_PICTURE_MOST` bytes | `Avatar.maxPictureBytes` in `app/lib/avatar.dart` |

A profile with any other field is refused, and so is one whose text is longer than `PROFILE_TEXT_MOST`. A refused profile answers 400. A name the filter refuses (`nameRefused` in `service/functions/names.mjs`; [names the others see](../explanation/service.md#names-the-others-see)) answers 400 with `not an allowed name`, `NAME_REFUSED` in `service/functions/profile.mjs`. A write from a device that is not the account's device in use answers 409.
