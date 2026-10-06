# 06 — The service

The service is deliberately small. The game is peer to peer
([doc 02](02-multiplayer.md)), the deal is verifiable
([doc 03](03-fair-deal.md)), and matchmaking, results and ratings are the
players' own business on the relay ([doc 04](04-live-play.md)). What runs
on our side:

- **The Pages worker** (`service/functions/`): licences, the shop,
  households, TURN credentials, remote config and game records.
- **The relay worker** (`service/do/`): a Durable Object per tag
  ([doc 08](08-own-relays.md)), the `Household` object, and the bench of
  jurors of last resort (`service/bin/juror.dart` in a container).

None of it is in a game's latency path.

## Handlers

`service/functions/worker.mjs`, published as `_worker.js`, answers
`/api/<name>` and hands every other path to the static assets.

| Handler | Method | What it does |
|---|---|---|
| `licence` | POST, signed | the device's current licence, or 402 if no subscription stands behind it |
| `checkout` | POST, signed | opens a Stripe Checkout session (subscription mode) for this device |
| `stripe` | POST, Stripe-signed | Stripe's webhook: binds the paying device and dates the subscription |
| `manage` | POST, signed | opens Stripe's billing portal for a web subscription (409 for a store one) |
| `store` | POST, signed | takes an App Store signed transaction or a Play purchase token and returns a licence |
| `apple` | POST | App Store Server Notifications V2 |
| `play` | POST | Play real-time developer notifications (Pub/Sub push) |
| `ticket` | POST, signed | a one-use code another device can join the household with |
| `claim` | POST, signed | spends a code (a household code or a backup code), binds the device, returns its licence |
| `devices` | POST, signed | lists the household's devices and can drop one |
| `backups` | POST, signed | shows, replaces or emails the subscription's backup codes |
| `attest`, `supersede` | POST, signed | binds an Apple/Google sign-in to a device key, or moves it to a new key |
| `turn` | POST, signed | Cloudflare Realtime TURN credentials for a subscribed device |
| `record` | POST, signed / GET `record/<table id>` | keeps a finished game's record, and serves it |
| `config` | GET | the remote config ([below](#remote-config)) |
| `health` | GET | whether the store is readable and Stripe answers for the price, for the monitors |

Bodies are capped at 16 KB (a record at 2 MiB, the Stripe webhook at
512 KB). CORS answers the site's own origins. A local origin is answered
only by a worker that is itself running locally.

### Signed requests

A device's key is public. It signs everything the device says at a
table, and the relay hands those events to anybody. So every handler
that acts for a device takes `{key, at, sig}`: a BIP-340
signature by that key over `oh-request/1`, the handler name, the key, the
second the request was made, and anything else the request asks for
(the code being spent, the device being dropped), one per line
(`signedAsk` in `app/lib/net/licence.dart`; `askedBy` and `signedFor` in
`worker.mjs`). Because the handler name is signed, a request for one
handler cannot be replayed against another. A request more than five
minutes from the service's clock is refused with a reason. Nothing is
stored to stop replays within that window, which is why the window is
short. The statement's hash is pinned in tests on both sides.

### Licence

A device holds a **licence**, not a receipt or an account. It is a
four-line statement (a tag `oh-licence/1`, the key, the last day it is
good for, and the plan), hashed and signed with BIP-340 by the service
key (`OH_SERVICE_SECRET`). The app checks it against `OH_SERVICE_KEY`,
the public half compiled into the build (`app/lib/net/licence.dart`,
`app/lib/entitlement.dart`). A licence for another key, past its day, or
signed by anything else is not a licence. A build compiled without a
service key treats every device as unlicensed, never as licensed by
whoever answers.

A licence lasts a month (`licenceDays`), never past what was paid for,
and is renewed while the subscription lives, so an ended subscription
needs no revocation list. The app reads its stored licence before the
first frame and asks the service afterwards, so it plays offline until
the licence's date. The worker checks its own signature against
`OH_SERVICE_KEY` and answers 503 for a mismatched pair.

### Payment

Live play is **$5.99 a year, paid up front**. The rest is free: solo
play, the records, the verifiable deal and the engine. The price is
yearly because a card fee's fixed 30¢ would be most of a monthly price.

**Web: Stripe.** `checkout` writes the device's key into the session's
metadata and the subscription's metadata, so renewals carry it too. The
return address must be on this site, and the app only leaves for Stripe's
own hosts. The webhook reads nothing until `Stripe-Signature` verifies
(HMAC-SHA-256, constant-time, at most five minutes old).
`checkout.session.completed` and `checkout.session.async_payment_succeeded`
bind the device, but only for a session this service created (the key
is read from `metadata`, never from `client_reference_id`) and only once
`payment_status` is `paid` or `no_payment_required`. The
`customer.subscription.*` events carry the date. Stripe does not promise
event order, so each subscription row keeps the time of the event that
wrote it and ignores older ones. Nothing changes a subscription after a
deletion or a final status. `OH_STRIPE_PRICE` (or `stripePrice`) is a
price id or a lookup key. The active price for a lookup key is cached
for five minutes.

**Phones: the store.** The phone buys in its own store and sends the
proof to `store`:

- **App Store**: a StoreKit 2 signed transaction. Its `x5c` chain must
  end at Apple Root CA – G3 (pinned in the worker) through Apple's WWDR
  intermediate to an App Store leaf, with each certificate valid when the
  payload was signed. It must also be this bundle and product, and an
  auto-renewable subscription. Apple is not contacted.
- **Google Play**: a purchase token. The service asks the Play Developer
  API (`subscriptionsv2`) what the token is, checks the product, and
  acknowledges the purchase if it has not been acknowledged.

The subscription id is `apple:<original transaction id>` or
`google:<hash of token>`. The app tags each purchase with a name derived
from its key, `sha256("oh-store/1\n" + key)`: Play's obfuscated account
id is that hash in hex, and Apple's `appAccountToken` is a v4 UUID made
from its first 16 bytes. The paying device moves onto what it paid for.
Another device presenting the same proof (a restore on a new phone)
joins within the household's limit. Renewals, lapses and refunds arrive
at `apple` and `play`, where each notification is verified (for Play,
the Pub/Sub push's Google ID token), and for Play the purchase is
fetched again. Neither store is ever final, since a lapsed subscription
can come back.

Without its identifiers (`apple`, `google` in the configuration) each store answers 503.

### Households

A subscription belongs to a person, not a device. It carries up to five
devices (`mostDevices`), and any of them can drop another or open the
billing portal.

- **A household code.** `ticket` makes a one-use code of sixteen
  random bytes, good for ten minutes. It is shown as a QR of a link into
  the app and as text. The other device opens the link, scans it in the
  app (the platform's scanner, or BarcodeDetector or the bundled ZXing
  port on the web), or types it. Asking again while a code has two
  minutes left returns the same code. The household's size is checked
  when the code is spent. The row expires from KV after an hour.
- **Backup codes.** Five per subscription, each good for one join, in
  the form `XXXX-XXXX-XXXX-XXXX` (Crockford base32, 80 bits; case and
  dashes are ignored, and O, I and L read as 0 and 1). They are made
  when the subscription is paid for and emailed to the checkout's
  address, which is read from Stripe and not kept. Any device on the
  subscription can show them, replace all five, or email them again.
  Email goes through Cloudflare Email Sending (`EMAIL`, from
  `OH_MAIL_FROM`, no reply-to). A store subscription has no address, so
  its codes are only shown. Rows are keyed by a digest of the code.
- **Sign-in.** `attest` checks an Apple or Google ID token against the
  provider's published keys: issuer, audience, expiry, allow-listed
  algorithm, and a nonce equal to the hash of the device's key
  (`sha256("oh-signin/1\n" + key)`, pinned in tests on both sides). The
  request is also signed by the key. It binds the account to that one
  key. `supersede` moves the binding and its subscription to a new key;
  a device already on a paid-up subscription of its own keeps it, and
  only the account moves. Only an HMAC of the provider's subject
  (`OH_ID_HMAC`) is stored. Google's audience is `google.webClientId`;
  Apple's are `apple.bundleId` and `apple.servicesId`, since Apple's
  token names the bundle id on an iPhone and the Services ID on the web.

  The app (`app/lib/net/sign_in.dart`, `provider_tokens.dart`) offers
  Apple on iOS and the web and Google on Android and the web, each only
  in a build compiled with its identifier (`apple.servicesId`,
  `google.webClientId`, compiled in by `deploy.sh`); without them
  there is no sign-in on the screen. On iOS it uses Sign in with Apple,
  on Android Credential Manager (through `google_sign_in_android`, not
  `google_sign_in`, whose web half loads Google's script into every
  page), and on the web Apple's JS popup and Google's own button, whose
  scripts are fetched only when a sign-in is on the screen. On the
  Subscription page a subscriber is offered a sign-in, which attests
  the account here; an account already on another device is moved only
  when the subscriber says so. A device with no subscription signs in to
  get one back: `supersede`, or `attest` for an account never signed in
  with. The device keeps only which provider it signed in with.

A code never takes a device off another subscription that is still paid
up. The app asks "Join this subscription?" before spending one. To move,
a device drops itself first. A device whose subscription has ended is
free to join. Dropping a device deletes its binding and its entitlement
row. The licence it already holds runs out on its own within the month.
When a subscription ends, its devices' entitlement rows are written
down too, so a refund takes effect at each device's next ask.

**One household at a time.** KV has no compare-and-set, so every change
to a household, and its device list, goes through one **Household**
Durable Object per subscription, which handles them one at a time. It is
exported from the relay worker and bound to the Pages project as
`HOUSEHOLD` (production only). Without the binding, as in the tests and
previews, an in-memory queue in the isolate does the same. A household
is limited to 20 changes and 60 reads an hour.

### TURN

`turn` mints Cloudflare Realtime TURN credentials (`OH_TURN_KEY_ID`,
`OH_TURN_API_TOKEN`) valid for four hours, only for a device whose
subscription stands, since TURN is billed by the gigabyte. Without the
secrets it answers 503, and the app makes no data channels and plays
over the relay: channels go through TURN or not at all, so no peer
learns another's address ([doc 02](02-multiplayer.md)).

### Game records

A player at a finished table can `POST` its record. The worker checks
that the sender's key holds a seat in the record, that the table id is
32 hex characters, and that the record is at most 2 MiB. The first copy
is kept, gzipped, in R2 (`OH_RECORDS`). `GET /api/record/<id>` serves it
as immutable. The worker vouches for nothing else. Every viewer replays
the record through the verifier before showing a card.

## Storage

Everything the worker keeps is in one KV namespace, `OH_STORE`, one key
per row as `PK|SK`, behind `get`, `put`, `del` and `under` (the rows under
one partition key, at most a household's devices). Tests and local mode
use a `Map` behind the same calls (`memoryStore`).

```
PK                         SK              holds
KEY#<key>                  ENTITLEMENT     subscription, licensed_until, at
KEY#<key>                  META            provider, attested_at, attestation
KEY#<key>                  SUPERSEDES      predecessor, link, at
SUB#<subscription>         META            source, txn_ref, renews_at, cancelled_at, event time
SUB#<subscription>         DEVICE#<key>    bound_at
SUB#<subscription>         CUSTOMER        Stripe customer, for the portal
SUB#<subscription>         TICKET          the outstanding code (expires)
SUB#<subscription>         BACKUP          the five backup codes, used or not
TICKET#<code>              META            subscription, expires_at, used_at (expires)
BACKUP#<digest>            META            subscription
LOGIN#<provider>#<hmac>    IDENTITY        key, created_at
config|app, config|service                 the operator's rows (below)
```

A provider's identifier is stored only as an HMAC, and nothing on the
`KEY#` side leads back to a provider. Entitlement is copied to each
device so a licence is one read. Cards, plays, game state, ratings and
email addresses are not stored.

## Remote config

Some things have to change for every device at once, faster than a
release. `config` serves one row the operator writes:

```bash
npx wrangler kv key put --binding OH_STORE 'config|app' \
  '{"live": false, "banner": {"id": "relays-down-1", "level": "warn",
    "text": {"en": "Live play is down until 18:00 UTC.", "de": "Live-Spiel bis 18 Uhr UTC aus."}}}'
```

| Field | Effect | Default |
|---|---|---|
| `live` | `false` closes the doors to live play (buttons, table links, going online as a juror) and says so. Games in progress play on. | open |
| `offer` | `false` hides the paid tier from devices that have not bought it. | offered |
| `relays` | One to eight `wss://` relays on `openhearts.game` or a subdomain, replacing the build's list. All must be valid, or none are taken. Read at app start. Local builds ignore it. | the build's |
| `banner` | A line on the front door: `id`, `level` (`info`/`warn`), and `text` by language (English required). | none |
| `feedback` | Where "Tell us what's broken" sends a report: an `https://` page or a `mailto:`. | GitHub issues |
| `privacy`, `terms` | `https://` links shown under Subscribe. | the site's own pages |
| `table` | The clocks of tables this device starts, in ms: `graceMs` (2–60 s), `passGraceMs` (2–120 s), `bankMs` (10–300 s), `fixedMs` (15–120 s), `botActsMs` (5–60 s), `botDealsMs` (15–120 s), `quorumLostMs` (10–120 s), `silenceMs` (30–600 s), `jurorSilenceMs` (10–120 s). All or nothing. They ride in the signed start event, so every seat plays by the starter's clocks. | 6, 20, 45, 40, 15, 40, 20, 120, 30 s |
| `price` | The yearly price shown on the web beside Subscribe, up to 12 characters. Change it together with `stripePrice`. | `$5.99` |
| `update` | `before: YYYY-MM-DD`. Builds published before that day are asked to update (optionally with `text`). | none |

The worker validates every field (`configOf`), and the app validates
them again (`app/lib/net/remote_config.dart`). An invalid field is
treated as missing, and an unreadable row gives the defaults. Responses
are cached for a minute. The app keeps the last answer, uses it at the
next start, and asks again every fifteen minutes while open.

`waits` sets how long the app waits on the network — the licence, a
household, a checkout, TURN, this config and how often it is asked
again, the relays, the standings, a friends' room's start, a direct
connection — each in milliseconds (`configEveryMin` in minutes). Each
field is taken on its own if it is a whole number within its bounds
(`WAITS_BOUNDS` in the worker, `AppWaits.bounds` in the app, kept equal
by a test), and the relay's slow and give-up pair only in that order.

## The service's settings

The service's own numbers live in two rows that are never served:

```bash
npx wrangler kv key put --binding OH_STORE 'config|service' '{"mostDevices": 5, "licenceDays": 31}'
npx wrangler kv key put --binding OH_STORE 'config|relay' '{"burst": 30, "perSecond": 2}'
```

`config|service` is read by the worker and the Household object, at
most once a minute per isolate:

| Field | Bounds | Default |
|---|---|---|
| `stripePrice`: the price a checkout sells, overriding `OH_STRIPE_PRICE` | price id or lookup key | `OH_STRIPE_PRICE` |
| `licenceDays` | 1–62 | 31 |
| `mostDevices` | 1–10 | 5 |
| `ticketMinutes` | 1–60 | 10 |
| `ticketReuseMinutes` (less than `ticketMinutes`) | 0–30 | 2 |
| `turnTtlS` | 600–86,400 | 14,400 |
| `requestToleranceS` | 30–900 | 300 |
| `webhookToleranceS` | 60–900 | 300 |
| `householdChangesPerHour`, `householdReadsPerHour` | 5–500, 10–2,000 | 20, 60 |

`config|relay` is read by each presence object when it wakes (through
the relay worker's own `OH_STORE` binding):

| Field | Bounds | Default |
|---|---|---|
| `message`: longest message, in characters | 8–256 KiB | 64 KiB |
| `request`: longest REQ | 256–1,536 | 1,024 |
| `burst`, `perSecond`: events per socket | 5–200, 1–20 | 30, 2 |

A value that is not a whole number within its bounds keeps its default.
The bounds stop where a setting would open a hole, such as a licence
outliving its subscription or a captured request staying valid for an
hour. Protocol constants (signed statements, code sizes, body limits)
stay in code.

## Watching it run

Monitoring records counts and nothing about anybody. When a Workers
Analytics Engine dataset is bound as `OH_METRICS`:

- **The worker** (`measure`) writes one line per request: the handler,
  the status, the milliseconds, and a weight. `config` and `health` are
  sampled one in ten. An unknown path is recorded as `unknown`.
- **Each relay object** (`tally`) writes one line a minute with
  connections, events, deliveries, subscriptions and each kind of
  refusal. The columns are in the order `tallied` lists them in
  `service/do/relay.mjs`.

No key, address, tag or location is written. To enable it, bind a
dataset named `open_hearts_api` on the Pages project and uncomment the
dataset in `service/do/wrangler.toml`. External ping monitors watch the
site, the app, `/api/health` and the relay
([observability/](../observability/README.md)).

### The operator's alerts

While there are few subscribers, the operator is emailed about each one
(`service/functions/alerts.mjs`, `alerts` in `config/openhearts.json`):

- **A new subscription:** from the Stripe webhook, or the first
  store purchase bound for a subscription. Told once per subscription
  in 30 days, however often the webhook is delivered.
- **A subscriber online:** a device on a subscription asks for its
  licence, which the app does when it opens. Told at most once per
  subscription in `onlineQuietMinutes`.

The mail says which store, the first characters of the subscription
and device, and dates. It never includes an email address or name. It
goes to `alerts@openhearts.game`, which forwards to where help@ goes
(`infra/`). It is sent from the relay worker, which holds the `EMAIL`
binding, through a Household object named `operator-alerts`, which
mails only `@openhearts.game`. A failed alert never fails the request.
Set either flag to `false` and deploy to stop it.

## The relay and the bench

The relay's core ([doc 08](08-own-relays.md)), `service/do/relay.mjs`,
is plain functions with no Cloudflare or Node imports. It checks
signatures with the app's own `app/web/schnorr.wasm`, passed in
precompiled because a Worker may not compile wasm at runtime. The Durable
Object (`TagRelay`, `worker.mjs`) hosts it in production. A plain Node
socket server (`host.mjs`) hosts it under `OH_RELAY=js`, so the whole
`service/` suite runs against the deployed relay's code.

`service/lib` has a Dart relay with the same behaviour, the default in
the Dart tests and in `dart run bin/service.dart` (port 7447). The local
relays also accept the simulator's fake signatures; the deployed object
accepts only BIP-340. WebRTC signalling on the relay is sealed to its
one recipient with NIP-44 v2, since an ICE candidate carries an address.

**The jurors of last resort.** A table with bot seats needs enough
jurors online to hold them. On a quiet night it calls for jurors on the
presence tag. The presence object passes the call to the `Bench` object
(`service/do/bench.mjs`), at most once every twenty seconds. The `Bench`
object starts a Cloudflare Container running `service/bin/juror.dart`:
four jurors in one process, with keys derived from `OH_JUROR_SECRET` so
they are the same across restarts. The bench goes quiet ten minutes
after its last call with nothing to serve, and the object stops the
container. The image is built from the repository on every relay deploy
(`service/bench/build.sh`).

## Deployment

| What | How |
|---|---|
| Site, app and worker | `./deploy.sh` ([doc 01](01-dev-loop.md)) |
| Relay, Household, Bench | `cd service/do && npx wrangler@4 deploy` (`wrangler.toml`: the `TABLE` and `BENCH` objects, the `Household` class, the container, `OH_STORE`, `EMAIL`, the domain `relay.openhearts.game`) |
| Accounts | `node infra/apply.mjs`, a dry run unless given `--apply` ([infra/](../infra/README.md)) |
| Monitoring | `node observability/apply.mjs` |

Pages secrets: `OH_SERVICE_SECRET`, `OH_ID_HMAC`, `OH_STRIPE_SECRET` (a
restricted key), `OH_STRIPE_WEBHOOK_SECRET`, `OH_TURN_API_TOKEN`, and
`OH_PLAY_SERVICE_ACCOUNT` once Play is set up. Everything else that is
not secret is in `config/openhearts.json`, committed: the service's
public key, the TURN key's id, the Stripe price, and the store and
sign-in identifiers (`apple.bundleId`, `product` and `servicesId`;
`google.package`, `product`, `webClientId` and the Play push audience
and email). `deploy.sh` compiles the build's from it and ships the file
to the worker, which reads it beneath the project's settings
(`service/functions/deployment.mjs`): a variable of the same name set on the
project wins, as one set by a test does. A field left null is a feature
left off. Bindings: `OH_STORE` (KV), `OH_RECORDS` (R2),
`HOUSEHOLD` (production only) and optionally `OH_METRICS`. Previews have
their own KV and bucket, and no Stripe. The relay's secret is
`OH_JUROR_SECRET`. `cd service && dart run bin/service_key.dart` mints
the service key pair and writes the secret half to `service.secret`,
which is ignored by version control.

A deployment with no keys degrades safely: no service key means live
play is shut, no Stripe means the shop says it is not open, and no TURN
means tables play over the relay.

## Testing

**Local mode.** The browser suites run the worker in-process over a
`Map` with `OH_OPEN_HOUSE` set. In that mode any key that asks is written
a subscription and licensed for a month, and `local:<subject>` tokens
are accepted as sign-ins. The flag is honoured only for requests to
`localhost` or `127.0.0.1`, so setting it in production does nothing.
`e2e/build.sh` compiles the app against BIP-340's published test key
pair, so the suites exercise the real handlers, signatures and licence
check. With `OH_TURN_LOCAL` set as well, `turn` hands out that local TURN
server with fixed credentials; the rig points it at a coturn it starts
on 127.0.0.1, so channels in the suites go through TURN as they do in
production.

**The departure matrix.** The table protocol's job is to keep four
seats playing while people come and go. The same client code runs under
four harnesses:

- **The simulator** (`packages/table`): every client in-process over a
  simulated network (latency, drops, partitions) on a virtual clock,
  replayable from a seed. The matrix varies how many people start (1–4),
  who goes (players, jurors, the whole jury), how (a signed leave, a
  silent drop, a boot, a partition) and when (on or off turn, mid-trick,
  during the pass or deal, at a hand boundary).
- **The chaos walk** (`tool/chaos.dart`, `--seeds N`, `--sealed N`):
  random faults, checked every few seconds of virtual time against the
  explicit state model (`packages/table/lib/src/model.dart`). CI walks
  forty seeds.
- **The explorer** (`tool/explore.dart`, `--fault-at`, `--match`): one
  run per message, peer and change (lost or delayed), with nothing else
  different (`SimNetwork.steer`), to find ordering faults random walks
  miss.
- **Real sockets and real browsers**: `service/test` runs the jury and a
  summoned juror of last resort over the relay; `e2e/` runs four headless
  browsers over WebRTC ([e2e/README.md](../e2e/README.md)).

Every scenario asserts that the game reaches its end with a bot in each
departed seat, or pauses, says why, and ends unscored ("juror quorum
lost"). It also asserts that every survivor holds the same record, that
the record verifies (every play signed and legal, every bot play
recomputable, and every proof, token and audit at a sealed table), that
nobody is removed without a strict majority of the last agreed
participants, so a partition never forks, and that nothing hangs.
