# 06 — The service

What runs on our side, which is deliberately little. The game is peer to
peer ([doc 02](02-multiplayer.md)), the deal is verifiable
([doc 03](03-fair-deal.md)), presence rides our relay and bot seats are
played by the players and the jury ([doc 04](04-live-play.md)). What is
left is identity, entitlement, and jurors when the room is empty.

## Handlers

| | In | Out |
|---|---|---|
| **attest** | Apple/Google sign-in token, device public key | signed attestation, or refusal because the account is already bound |
| **supersede** | sign-in token, old and new public keys | signed supersession link |
| **checkout** | key, where to come back to | a Stripe Checkout to send the buyer to |
| **entitle** | purchase webhook | entitlement recorded; signed licence available to the key |
| **licence** | key | the licence that key is owed, or 402 |
| **ticket** | key | a one-use code another device can arrive with |
| **claim** | key, code | the code spent, the device bound, and its licence |
| **devices** | key, a device to drop | the devices on this subscription |
| **config** | — (a GET) | what the operator has said: the remote config, below |
| **turn-creds** | attested key | short-lived TURN credentials |
| **last-resort** | table id, hand | the bench comes online for that hand |

Each is a point lookup and a signature. None is in a game's latency path
and none is needed by a table already playing.

**As built.** The handlers run as the Cloudflare Pages worker beside the
site and the app: `service/functions/worker.mjs`, published by
`deploy.sh` as `_worker.js`, answers `/api/…` and hands everything else
to the static assets; `node --test service/functions/worker.test.mjs`
runs it against a stand-in upstream. Built so far: **turn-creds**,
**checkout**, **entitle**, **licence**, **ticket**, **claim**,
**devices**, **attest** and **supersede**; **last-resort** is not, and
the last two are built on this side only — see below.

**Every request is signed by the key it names.** A device's key is
public — it signs every event the device says at a table, and the
relays hand those to anybody — so a handler that acted on a key named
in a body acted for whoever had read it: listed a stranger's
household, dropped their device, made a code against what they paid
for and spent it on another key. Every handler but Stripe's takes
`{key, at, sig}`: the second the request was made, and a BIP-340
signature by that key over `oh-request/1`, the handler, the key, that
second and what the request asks for beyond itself — the code being
spent, the device being dropped — a line each (`signedAsk`,
`app/lib/net/licence.dart`; "who is asking", `worker.mjs`). The handler
is in it, so the request that renews a licence is never spent as one
for a code; a request more than five minutes from the service's clock
is refused and says so; and nothing is written to remember one, which
is why the window is short. See [the security review](security-review.md).

**licence**, `POST /api/licence` with the caller's key, answers the
signed statement below or 402 when no subscription stands behind it.
The signing is the app's own BIP-340 wasm — one curve in this project
and one implementation of it — which the worker fetches from the static
assets it is already serving and keeps for the life of its isolate. It
signs with `OH_SERVICE_SECRET` and then checks its own signature
against `OH_SERVICE_KEY`, the public half every build is compiled to
expect: a pair that does not match is a 503 saying so, rather than
licences no device will take. `dart run bin/service_key.dart` in
`service/` mints a pair; `deploy.sh` passes the public half into the
build.

**checkout**, `POST /api/checkout`, opens a Stripe Checkout session in
subscription mode with the device's key in three places — the session's
metadata, its client reference, and the subscription's metadata, which
is what a renewal a year from now will carry. Where the buyer is sent
back to comes in from the app and is checked against this site's own
origin first: a payment does not land wherever the caller says.

**entitle**, `POST /api/stripe`, is Stripe's webhook. Nothing is read
out of a body until the `Stripe-Signature` header checks out against
`OH_STRIPE_WEBHOOK_SECRET` — HMAC-SHA256 over the timestamp and the
body, and a signature from last week is refused whatever it says, since
a replay is not a payment. `checkout.session.completed` binds the
device; the subscription's own events carry the date. The two arrive in
either order, so a device bound before its date is known is dated on
its first ask after. Nor do the subscription's own events arrive in
order — Stripe promises none, and tries a failed delivery again for
days — so the row keeps the time of the event that wrote it, an older
one is not news, and nothing is news after a deletion or a final
status: an update from before a refund, delivered after it, would
otherwise have been a year of play.

**attest** and **supersede**, `POST /api/attest` and
`/api/supersede`, are one proof with two endings. The proof is the
provider's own sign-in token, checked against that provider's published
keys — issuer, audience, expiry, and a nonce that has to be the hash of
the device's key, so a token lifted from somewhere else cannot bind
somebody's account to the lifter. The nonce is whoever asked the
provider's to choose, though, so it says which key a token was made
for and not that the key wanted it: the request is signed by the key
as well, or a stranger could have his own account signed over
somebody else's key, attest it there, and supersede it onto his own —
carrying their subscription with it. What is stored of the account is an
HMAC of the provider's subject identifier (`OH_ID_HMAC`), never the
identifier; nothing on the `KEY#` side leads back to the provider.
attest binds an account to one device and refuses a second; supersede
is the move, and carries the subscription across — dropping the device
it replaced, and nobody else's, where the household is already five.

**Not built: the app's half of it.** Getting a token out of Google or
Apple in a browser is a handshake with a client id in it, and there is
no id to test against yet, so the flow the app would use — a redirect,
or their button on the page — is a choice made better against a real
one than guessed at. Local mode has a token of its own in the meantime
(`local:<subject>`, taken only where the open house is), so the
handler's own path runs end to end. What is needed to finish it: a
Google OAuth client id and an Apple service id, as
`OH_GOOGLE_AUDIENCE` and `OH_APPLE_AUDIENCE`.

**turn-creds**, `POST /api/turn`
with the caller's table key, answering Cloudflare Realtime TURN
credentials good for four hours, minted from a TURN key that lives in
the project's secrets (`OH_TURN_KEY_ID`, `OH_TURN_API_TOKEN`) and never in
the repo. Without them it says so, and the app falls back to STUN
alone; on localhost the app asks nothing and peers connect directly.
They are minted for a device whose subscription stands and nobody
else: credentials are a relay their holder can push anything through
for four hours, billed by the gigabyte, and TURN is what the
subscription pays for. A subscriber can still mint as many as it
likes, which is what Cloudflare's rate rules and a usage alert are for
(the security review). The app fetches them when a device connects to
the relays (`app/lib/net/turn.dart`) and hands them to every peer
connection at its next table.

## Storage

Everything the service keeps fits one key-value table. Every access is
a lookup by key — no scans, no ranges, no joins.

```
PK                         SK             attributes
LOGIN#apple#<hmac(sub)>    IDENTITY       key, created_at
LOGIN#google#<hmac(sub)>   IDENTITY       key, created_at
KEY#<key>                  META           provider, attested_at, attestation
KEY#<key>                  SUPERSEDES     predecessor, link, at
SUB#<subscription>         META           source, txn_ref, renews_at, cancelled_at   (subscription: sub_… Stripe, apple:…, google:…)
SUB#<subscription>         DEVICE#<key>   bound_at
SUB#<subscription>         CUSTOMER       customer (Stripe's, for the billing portal)
KEY#<key>                  ENTITLEMENT    subscription, licensed_until, at
TICKET#<code>              META           subscription, expires_at, used_at
SUB#<subscription>         TICKET         code, expires_at (the one outstanding, handed back while unspent)
COUNTER#<metric>#<day>     -              n
```

Three rules baked in:

- **The provider identifier is stored keyed, never raw.** It is opaque
  but stable, and it joins to a real account. HMAC'd with a server-side
  secret, a leaked table joins to nothing.
- **Nothing on the `KEY#` side leads back to the provider.** The key is
  what public records carry.
- **Entitlement is copied forward on supersession**, so a licence is a
  single read. Supersessions are rare; licences are every session.
- **A subscription is one row and its devices are rows under it**, so
  binding a device by QR, dropping one, and counting the five are all
  point operations, and a renewal touches the subscription rather than
  every device on it.

Not stored: cards, plays, game state, ratings, emails, device sessions.
Ratings are computed from public records by anyone. TURN credentials are
minted from a secret, not kept. The last-resort jurors keep nothing.

Counters are the instrumentation the design asks for — how often tables
drain to one human, how often a jury cannot be drawn — as atomic
increments, no identities attached.

Secrets — the service signing key, the TURN secret, the purchase webhook
secret, the HMAC key — live in the platform's secret store, never in
the table.

**As built.** The shape above, flattened to one key per row —
`PK|SK` — behind four calls: `get`, `put`, `under` (the sort keys under
one partition key, for the devices on a subscription) and nothing else.
Cloudflare KV bound as `OH_STORE` on the site; a `Map` behind the same
four in the browser suite and in the tests, which is all local mode
needs (`memoryStore`). `under` is the only call that is not a point
lookup, and what it ranges over is five devices.

One thing the shape does not survive on its own: the copy of the date a
device keeps so that a licence is one read. Stale is harmless when a
renewal has moved the date *out* — the device catches up on its first
ask after its copy runs out. It is not harmless when a subscription
*ends*: a refund would otherwise leave every device on it licensed for
up to a year. So an ending — deleted, unpaid, expired — writes the
devices down as well as the subscription. Five rows, once, and never on
the renewal path.

The design is written against DynamoDB's single-table shape and ports to
any key-value store almost literally; the platform choice is deferred to
deployment. A bucket is reserved for archiving public game records. It
was meant for relays that promise no retention; our relay now keeps the
results itself (the `results` tag's object, below), so whether the
bucket is needed at all is undecided, and nothing depends on it yet.

## What is paid for, and how

Live play is a subscription: **$5.99 a year, paid up front**. Everything else is free
and stays free — the bots, the records, the verifiable deal, the engine
itself. What the money is for is the part that costs us money to run:
relaying people to each other, TURN when a direct path will not form,
and jurors when a table is left alone.

A year rather than a month, for an unglamorous reason. The same price
by the month is fifty cents, and the fixed part of a card fee — thirty
cents on Stripe — would be more than half of it, with a store's cut on
top; by the year that fee is paid once. $5.99 nets about $5.52 through
Stripe after 2.9% + 30¢, and about $5.09 on a store at the small
business rate. The shape of the price is chosen by the fees, not the
other way round.

### The licence

What a device holds is not a receipt and not an account: it is a
**licence**, a short statement signed by the service's key —

    { key: <device public key>, until: <date>, plan: 'year' }

— which the app verifies against a public key baked into the build, the
same way it verifies everything else it is told. Three things follow
from that. A device that cannot reach us keeps playing until the date on
its licence, which is the only sane behaviour for a game people take on
a train. Nothing about the purchase is on the device except the
statement, so there is nothing on it worth stealing. And the service is
not in a game's latency path: a licence is read at the front door, not
at a trick.

The date is **short — a month — and renewed while the subscription
lives**. That is what makes cancellation and refunds work without a
revocation list to distribute and check: a cancelled subscription simply
stops being renewed, and the last licence runs out. A year's
subscription is twelve or thirteen renewals, each a single point read.

**As built** (`app/lib/net/licence.dart`, `app/lib/entitlement.dart`).
The statement is four lines — a tag, the key, the day, the plan — hashed
and signed BIP-340, and the date is the last day it is good for, running
to the end of it in UTC. A licence signed by anything but the key this
build names is not a licence; neither is one for another device, and
neither is a licence whose day has passed. It is read off the device
before the first frame and asked of the service behind it, in that
order and never the other way: the front door has to be able to answer
before it is drawn, and a device on a train has to be able to answer at
all.

Two things it does *not* do. It does not go through the general
signature check the rest of the protocol uses, which also takes a
simulated table's fake signature — a hash of the signer's **public**
key, and the service's is printed in every build. And a build that
names no service does not fall open: every device is unlicensed, rather
than every device licensed by whoever answers first.

### Where the money comes in

| | Buying | Renewing | Telling us |
|---|---|---|---|
| iOS, Android | the store's own subscription | the store | App Store server notifications, Play real-time developer notifications |
| Web | Stripe Checkout, subscription mode | Stripe | the Stripe webhook |

Both land at **entitle**, keyed by the public key the buyer had when
they bought — the key rides in the checkout session's metadata, or in
the purchase's application username. A renewal is the same handler with
a later date. Neither path asks the player to make an account.

**As built.** The web half: Checkout, the webhook, and the app's side of
both (`app/lib/net/buying.dart`). Pressing Subscribe asks the service
for a session and leaves for it — and only for Stripe's own host,
checked here, since what a device is sent to is not a place a bad
answer gets to choose. Coming back, the address carries a mark the app
reads once and then takes out: the webhook is usually there before the
browser is, and when it is not the app asks again for a few seconds
rather than telling the buyer nothing happened.

**The store half, as built.** The phone buys in its own store and
brings the store's proof to **store** (`/api/store`), signed as every
request is, with the proof as what it signs:

- **App Store**: a StoreKit 2 signed transaction, a JWS whose `x5c`
  chain must end at Apple Root CA - G3 — pinned in the worker, byte for
  byte — through an intermediate carrying Apple's WWDR mark
  (`1.2.840.113635.100.6.2.1`) to a leaf carrying the App Store's
  (`1.2.840.113635.100.6.11.1`), each signature checked and each
  certificate good at the moment the payload says it was signed. Then
  it must be this app's bundle, this product, an auto-renewable
  subscription. Nothing is asked of Apple. Sandbox transactions are
  taken too — App Review buys in the sandbox — and only testers the
  developer made can make one.
- **Google Play**: a purchase token, which proves nothing alone: the
  service asks the Play Developer API (`subscriptionsv2`) with the
  project's service account what it is, checks the product, and
  acknowledges it if it was not — Play refunds a purchase nobody
  acknowledged within three days.

The subscription is `apple:<original transaction id>` or
`google:<hash of the token>` (a token replacing another, as a
resubscription's does, is the subscription it replaced), dated from
what the store said, and the device joins it in its household's turn
(`bind`). The store's record names the device a purchase was for: the
app sets Apple's `appAccountToken` and Play's obfuscated account id
from a hash of its key. The device that paid moves onto what it paid
for from wherever it was; any other device bringing the same proof —
the same Apple or Google account restoring it on a new phone — joins
as a code would let it, within the household's count and not off
another paid-up subscription. A lapsed or refunded purchase is written
down and licenses nobody (402).

Renewals, lapses and refunds are pushed, as Stripe's are: App Store
Server Notifications V2 at **apple** (`/api/apple`; the notification
and the transaction inside it checked as above, a renewal in its grace
period paid to the end of the grace), and Play's Real-time Developer
Notifications at **play** (`/api/play`; Pub/Sub's push, its Google ID
token checked for the push subscription's own service account and this
endpoint as audience, and then Play asked what the purchase is now).
Neither is ever final: a lapsed App Store subscription keeps its
original transaction when it is bought again.

The variables: `OH_APPLE_BUNDLE_ID`, `OH_APPLE_PRODUCT`;
`OH_PLAY_PACKAGE`, `OH_PLAY_PRODUCT`, `OH_PLAY_SERVICE_ACCOUNT` (the
service account's JSON key, as a secret), `OH_PLAY_PUSH_AUDIENCE` and
`OH_PLAY_PUSH_EMAIL` (the push subscription's). Without them each store
answers that it is not set up yet (503).

**The store half, the app's side** (`app/lib/net/store_buying.dart`):
Subscribe opens the store's own sheet for a yearly auto-renewing
product (`OH_APPLE_PRODUCT`, `OH_PLAY_PRODUCT`, both `live_play_yearly`
until the products exist), and what the store hands back — StoreKit 2's
signed transaction, or Play's purchase token — goes to **store**, signed
over by the device's key like every other request, and comes back a
licence. The purchase is recorded in the store against a name made from
the key, so the store's own notifications say which device paid:
`h = sha256("oh-store/1\n" + key)`, Play's obfuscated account id is `h`
in hex, and the App Store's app account token is a version-4 UUID from
its first sixteen bytes. A purchase is finished with the store only once
the service has taken it, or has said the proof is not from the store or
not paid for; anything else leaves it for the store to hand back at the
next start, or at Restore purchases. A store subscriber manages it in
the store's own subscription settings. Until the store says what the
product costs, `canBuyHere` is false off the web and says so rather
than opening a checkout a phone should not be using.

Three things have to be set on the project for any of it to work:
`OH_STRIPE_SECRET` (a restricted key, `rk_…`, with only what the
worker calls: Checkout Sessions write, Prices read, Subscriptions
read, Customer portal write), `OH_STRIPE_PRICE` (a yearly recurring price: its
`price_…` id, or its lookup key — the same in test mode and live, and
moved to a new price in the dashboard with nothing changed here; the
worker asks Stripe for the active price holding it and keeps the
answer five minutes) and
`OH_STRIPE_WEBHOOK_SECRET`, with the webhook pointed at `/api/stripe`
for `checkout.session.completed`,
`checkout.session.async_payment_succeeded` and
`customer.subscription.*`. Without them the shop says it is not open
yet, which is what a deployment with no keys should say.

All of this — the Pages project's variables, secrets (by name) and
bindings, the stores, the zones' DNS, rules and Email Routing, and on
Stripe's side the price, the portal and the webhook — is written down in
`infra/` and checked against both accounts by `node infra/apply.mjs`, a
dry run unless given `--apply` (infra/README.md). The relay worker's own
setup stays in `service/do/wrangler.toml`, which that run checks the
deployed worker against.

A web subscriber manages the subscription — cancels, changes the
card, reads a receipt — in Stripe's billing portal: **manage** opens a
portal session for the subscription's Stripe customer and the app goes
there as it went to the checkout, accepting only `billing.stripe.com`,
and comes back to this site. Any device bound to the subscription may
open it, as any may drop another, so a household that lost the phone
that paid can still cancel. The customer is kept from the webhook
(`SUB#…|CUSTOMER`); for a subscription bought before it was, Stripe is
asked once. One bought in a store answers 409 and the app says it is
managed where it was bought. The portal itself — cancellation allowed,
the business's name and links — is configured in the Stripe
dashboard.

A checkout binds a key only if this service opened it: the key is read
from the session's `metadata`, which only our checkout writes, and not
from `client_reference_id`, which any Payment Link on the account takes
from its URL. It binds only once paid — `payment_status` `paid` or
`no_payment_required`, so a bank transfer still pending binds nothing
until Stripe says it cleared. The webhook's signature is checked in
constant time, and a body past half a megabyte is not read; every other
handler stops at sixteen kilobytes, far past anything the app sends.

### A subscription is a person's, not a device's

So a second device has to be able to hold the same licence, and there
are three ways for one to get it, in the order they cost the player
anything:

- **A QR code**, which is the fast one and needs nothing typed. A
  subscribed device shows a code carrying a one-time claim ticket: the
  subscription's id, an expiry a few minutes out, and a signature over
  both. The other device scans it and calls **claim**; the service
  checks the ticket has not been used and is not stale, binds the new
  key to the subscription, and issues it a licence. Tickets are
  one-use, so a photograph of someone's screen an hour later is worth
  nothing.
- **A provider account**, which is the durable one. **attest** already
  binds an Apple or Google sign-in to a key and entitlement already
  follows that identity, so signing in on a new phone is enough, and a
  lost phone is recovered the same way.
- **An email address**, for buyers who have neither. The rule that this
  service does not keep email addresses stands: what is stored is an
  HMAC of the address, exactly as a provider's subject identifier is,
  so the table joins to nothing if it leaks. Where an address is needed
  to send a link — a web buyer recovering a lost device — Stripe
  already holds the one they paid with, and it is asked rather than
  kept.

A subscription carries **up to five devices**, and any of them can drop
another. Unbounded sharing by QR is a subscription shared with the
internet; five is a household.

**As built**, the QR one, and with one change to it. The subscribed
device asks for a code, shows it as a QR of a link back into the app,
and the other device opens that link with its own camera. Or the other
device scans it in the app — menu, **Activate subscription**, Scan a
code — or types it there, since the page shows it as text too, in
fours; a device with no camera pointed at the screen also gets the
same link through the share sheet, as a room's link goes. The app's
scanner is the platform's own on a phone (ML Kit on Android, from Play
services rather than bundled; Apple's on iOS), and in a browser its
own BarcodeDetector where it has one that reads QR codes, else ZXing's
JavaScript port served from the site (`web/zxing`) — never a library
fetched from somebody's CDN at the moment a camera is pointed.

The change: the code is sixteen random bytes and nothing else. The
design has it carry the subscription and an expiry under a signature;
what is built keeps both at the service instead, for two reasons that
only showed up against a camera. A code that has to be spent needs a
row whatever it carries, so a signature saves no lookup — and a code
three times longer is a QR three times denser, read across a table by
a phone that is not quite still. It also keeps the subscription id off
the wire, which a photograph of somebody's screen would otherwise
carry away.

The count is read where a code is spent rather than where it is made,
so a code made while there was room cannot let a sixth device in. A
code's row is let go by the store an hour after it is made, spent or
not, so codes do not pile up for ever.

### Backup codes

A code on a screen needs a screen: a device already on the
subscription, in hand. The day there is none — the only phone lost, a
new one in hand — a **backup code** stands in. Five to a subscription,
each good for one device, once, and good until it is used or replaced.
Sixteen characters of Crockford's base32, `XXXX-XXXX-XXXX-XXXX`, eighty
bits: typed by a person, so case and dashes are ignored, and an O, I or
L is taken as the 0 or 1 it looks like.

They are made when the subscription is paid for and **emailed** to the
address the checkout was paid with, which is on Stripe's event and not
kept. Any device on the subscription shows them under Subscription,
marked once used, can **replace** all five at once, which spends the
old ones, and can **email** the ones still good to the payer (its own
signed ask), the address read from Stripe at that moment
(`/customers/{id}`) and not kept. The answer says whether they went,
and if not why — no address, no mail bound, or the send failed — and
the relay's log says the same. A store subscription has no address
here, so its codes are only shown.
The email goes through Cloudflare's Email Sending, bound as `EMAIL` to
the relay worker the household runs in, from `OH_MAIL_FROM`, with no reply
address — a reply would quote the codes — and the support page named
for help; without
both, nothing is sent and the codes are only shown.
The zone's Email Address Obfuscation is off: it rewrote `help@` on the
site's pages and injected a script of Cloudflare's to put it back.

A backup code is entered where a screen's code is (`/api/claim`, the
same signed request): the service tells the two apart by their shape.
It is spent only by a join that goes through, so one turned away by a
full household is still good once a device is dropped. Its row is
keyed by a digest of the code, so a listing of the store lists none of
them; the codes themselves sit in the subscription's row, which only a
device bound to it is shown (`/api/backups`, signed; replacing is
signed as such, so a read cannot be replayed as one).

A code does not take a device off another subscription that is still
paid up. A code arrives in a link, and the app asks before it spends
one — "Join this subscription?" — but a yes is easily given to a link
from a stranger, who could otherwise send one to somebody else's phone, take it off the
subscription its owner paid for, and drop it from his. A device
moves on by dropping itself first; one whose subscription has ended
is free to go, and so is one licensed by local mode's open house,
which was never anybody's purchase.
Dropping a device takes away its binding **and** its entitlement row —
not merely the date on it: the subscription is still paid up, so a row
that had only run out would be dated forward again on that device's
next ask. The one it holds runs out on its own within the month, which
is what a licence with no revocation list can promise and all it can.

#### One household at a time

KV has no compare-and-set: two devices spending one code at once both
read it unspent, and both got in, so a household of four became six.
So everything that changes a household — making a code, spending one,
dropping a device — and the list of its devices goes through one
**Household** Durable Object per subscription, which takes them one at
a time; the rows stay in KV, where everything else reads them. The
object lives in the relay's worker (`service/do`, which exports it)
and is bound to the Pages project as `HOUSEHOLD`; without the binding,
as in the suites and on a single isolate, the same sequencing is a
queue in memory. A household is also held to twenty changes and sixty
reads an hour (by default: "The service's settings"), which is far past what a family does and short of what
a loop does to KV's daily writes. Asking for a code again while one is
outstanding, unspent and good for two more minutes is a read: the same
code comes back.

TURN is Cloudflare's.

## Remote config

Some things have to change for every device at once, sooner than a
build reaches them: live play shut while the relay is down, a line on
the front door saying so, the tables moved to another relay of ours, a build too
old to sit with the others told to update. The **config** handler serves
them, from one row the operator writes:

```bash
npx wrangler kv key put --binding OH_STORE 'config|app' \
  '{"live": false, "banner": {"id": "relays-down-1", "level": "warn",
    "text": {"en": "Live play is down until 18:00 UTC.", "de": "Live-Spiel bis 18 Uhr UTC aus."}}}'
```

| Field | What it does | With none |
|---|---|---|
| `live` | `false` shuts the doors to live play — the buttons, a link to a table, going online as a juror at the start — and says so where the buttons were. A game already at a table plays on, and a device already online stays a juror to the tables that drew it until it is next started. | open |
| `offer` | `false` hides the paid tier from a device that has not bought it: no price, no Subscribe. One with a licence keeps live play. For a store build that may not show a web price. | offered |
| `relays` | The relays the tables meet on, in place of the build's: one to eight, `wss://` only, on `openhearts.game` or a host under it — never a public relay ([doc 08](08-own-relays.md)) — every one good or none taken. Read at the app's start, so the devices that started since the change meet on the new ones and those before it finish where they are. A local build and the rig keep their own. | the build's |
| `banner` | A line across the front door: `id` (letters, digits, `.` `_` `-`), `level` `info` or `warn`, and `text` by language, English required — a device is told it in its own language where the row has it and in English where it does not. | nothing |
| `feedback` | Where "Tell us what's broken" sends a report: an `https://` page or a `mailto:` address. GitHub's new-issue page and mail take the report in the address; another page is opened with the report on the clipboard. | the project's GitHub issues |
| `privacy`, `terms` | Where the privacy policy and the terms of use are, `https://` only, for the links under Subscribe. | the site's `/privacy` and `/terms` |
| `table` | The clocks of a table this device starts, in milliseconds: `graceMs` (2–60 s), `passGraceMs` (2–120 s), `bankMs` (10–300 s), `fixedMs` (15–120 s), `botActsMs` (5–60 s), `botDealsMs` (15–120 s), `quorumLostMs` (10–120 s), `silenceMs` (30–600 s), `jurorSilenceMs` (10–120 s). Any left out are the standard's. They ride in the signed start event, so every seat and juror plays by the starter's, and a table someone else starts keeps theirs ([doc 04](04-live-play.md), "Boot"). All or nothing: one field out of bounds or not a whole number and the worker serves none of it, and a seat that reads such a start plays the standard table. | the standard: 6, 20, 45, 40, 15, 40, 20, 120 and 30 s |
| `price` | What a year costs as the web shows it beside Subscribe (`$5.99`, `€6,49`): up to twelve characters with a digit, no spaces or markup. Change it with the Stripe price it describes (`stripePrice`, below). A store build shows the store's own. | the build's, `$5.99` |
| `waits` | How long a device waits on the network, each in milliseconds and each taken or left on its own: `licenceMs` (2–30 s), `householdMs` (3–30 s), `buyMs` (3–60 s), `turnMs` (2–30 s), `configMs` (2–30 s), `relaySlowMs` (3–30 s) before "taking a while" and `relayGiveUpMs` (15–180 s) before giving up, the slow one first or neither taken, `standingMs` (3–30 s) and `standingAllMs` (1–20 s) for the standings, `roomStartMs` (3–60 s) a friends' room waits after its last arrival, `meshAnswerMs` (5–60 s) before a direct connection is left to the relay; and `configEveryMin` (5–240), how often an open app asks for this row again. | 6, 10, 12, 5, 8, 8, 40, 8, 4, 10 and 20 s; every 15 minutes |
| `update` | `before`: a day, `YYYY-MM-DD`; a build published before it is asked to update, in `text` if given and the app's own words if not, with a Reload button on the web. A local build has no day and is never asked. | nothing |

A build from before `table` reads a start that carries one as the
standard table, and would time the others' table by other clocks than
theirs; so set it only once such builds are asked to update (`update`).

The worker checks every field before it serves the row (`configOf`), and
the app checks them again (`app/lib/net/remote_config.dart`): a field
that does not check out is left as the build has it, so a typo in the
row is never worse than no row. A row that cannot be read at all, or a
store that is down, serves the defaults. The answer is cached for a
minute; the app keeps the last one on the device and goes by it at the
next start before it asks again, and asks every quarter of an hour
while it is open — so a door shut reaches every device that opens the
app within a minute, and a tab left open within fifteen. A device that
never reaches the worker — offline, or a phone build, which has no
service address yet — has the build as it was made.

Bot strength is not here: the bots have ratings of their own, fitted on
the ladder and moved by rated games like anyone's ([doc
04](04-live-play.md)), and a table is seated with bots near its own
rating. There is nothing to tune that the ratings do not already say.

## The service's settings

The numbers the service itself runs by are not in the app's row, which
anybody can read, but in two of their own, written the same way:

```bash
npx wrangler kv key put --binding OH_STORE 'config|service' \
  '{"stripePrice": "price_1Q…", "mostDevices": 5, "licenceDays": 31}'
npx wrangler kv key put --binding OH_STORE 'config|relay' '{"burst": 30, "perSecond": 2}'
```

`config|service`, read by the Pages worker and the Household object:

| Field | What it is | Bounds | With none |
|---|---|---|---|
| `stripePrice` | The Stripe price a checkout sells, in place of `OH_STRIPE_PRICE`: its id (`price_…`) or its lookup key. Change `price` in the app's row with it. | a price id or lookup key | `OH_STRIPE_PRICE` |
| `licenceDays` | How long a licence lasts before the device asks again; never past the subscription's own end. | 1–62 | 31 |
| `mostDevices` | Devices on one subscription. | 1–10 | 5 |
| `ticketMinutes` | How long a household code is good for. | 1–60 | 10 |
| `ticketReuseMinutes` | A code asked for again while this much of it is left is the same code. Less than `ticketMinutes`. | 0–30 | 2 |
| `turnTtlS` | How long TURN credentials last. | 600–86,400 | 14,400 |
| `requestToleranceS` | How far a signed request's clock may be from ours. | 30–900 | 300 |
| `webhookToleranceS` | How old a Stripe event may be. | 60–900 | 300 |
| `householdChangesPerHour`, `householdReadsPerHour` | What one household may do in an hour. | 5–500, 10–2,000 | 20, 60 |

`config|relay`, read by each relay object when it wakes (it needs the
relay worker's own `OH_STORE` binding, `service/do/wrangler.toml`):

| Field | What it is | Bounds | With none |
|---|---|---|---|
| `message` | The longest message read, in characters. | 8–256 KiB | 64 KiB |
| `request` | The longest REQ. | 256–1,536 | 1,024 |
| `burst`, `perSecond` | Events one socket may publish at once, then each second. | 5–200, 1–20 | 30, 2 |

Every number is checked against its bounds and one that is not a whole
number inside them is left at its default, so a typo is never worse
than no row; the bounds stop where a setting would become a hole (a
licence outliving its subscription, a captured request good for an
hour). The worker reads its row at most once a minute per isolate; a
relay object reads its row when it is built, which is after every wake.
What stays in the code is what is protocol rather than tuning: the
statements devices sign, the 16-byte codes, the body limits, and the
bounds themselves.

## Watching it run

What the operator can see of the service, and nothing about anybody:
counts, written to Workers Analytics Engine when the project binds a
dataset as `OH_METRICS`, and nothing at all when it does not.

- **The handlers** (`service/functions/worker.mjs`, `measure`) write one
  line a request: the handler's name, the status it answered and the
  milliseconds it took, and how many requests the line stands for. The
  config is asked for by every open app each quarter of an hour, so one
  request in ten of it is written, with a weight of ten; every other
  handler is a person doing something, and each is written. A path no
  handler serves is written as `unknown`, never as what was asked for.
- **The relay object** (`service/do`, `tally`) counts what became of its
  messages — connections opened and closed, events taken and the
  deliveries they made, subscriptions, and each kind of refusal — and
  writes them as one line a minute from each object in use. A line a
  message would be a line every two seconds for every device online.

Neither writes a key, an address, a tag or a location. To turn it on:
in the Pages project's settings, bind an Analytics Engine dataset named
`open_hearts_api` as `OH_METRICS`; for the relay, uncomment the dataset in
`service/do/wrangler.toml` and deploy it. Then, with the account's SQL
API:

```sql
-- Errors and slow answers, by handler, over the last day.
SELECT blob1 AS handler, blob2 AS status,
       SUM(_sample_interval * double2) AS requests,
       quantileWeighted(0.95, double1, _sample_interval) AS p95_ms
FROM open_hearts_api
WHERE timestamp > NOW() - INTERVAL '1' DAY
GROUP BY handler, status ORDER BY requests DESC;

-- The relay object's traffic and refusals, by hour.
SELECT toStartOfHour(timestamp) AS hour,
       SUM(double1) AS opened, SUM(double3) AS events, SUM(double4) AS delivered,
       SUM(double6) AS rate_limited, SUM(double10) AS too_big
FROM open_hearts_relay
WHERE timestamp > NOW() - INTERVAL '7' DAY
GROUP BY hour ORDER BY hour;
```

The relay's columns are in the order `tallied` lists them
(`service/do/relay.mjs`), with the seconds the line covers last.

**What it costs to keep.** The relay object stores nothing: it is
SQLite-backed because new classes on the free plan must be, and it
carries only ephemeral kinds, never written to its storage, so the
object's storage bill is nothing however many tags are in use. What it
costs is requests and duration, which the lines above count. KV holds
the subscriptions, the codes (each gone an hour after it was made) and
the config row; its writes are the thing to watch on the free plan
(docs/security-review.md, finding 10).

For a live look, `npx wrangler tail` on either worker shows its
requests as they come; neither writes anything of its own to the log.

## Local mode

The service runs entirely locally for end-to-end tests, with the same
code and different adapters:

| | Production | Local |
|---|---|---|
| Storage | DynamoDB | in-memory, same shape |
| Sign-in | Apple/Google published keys | `local:<subject>`, a token naming a `sub` |
| Entitlement | store and Stripe webhooks | an open house: a key that asks is licensed for a month |
| TURN | Cloudflare | none; localhost connects directly |
| Signalling, waiting rooms, results | our own relay, `relay.openhearts.game`, one object per tag ([doc 08](08-own-relays.md)) | a minimal relay in the repo, same wire format |
| Last-resort jurors | woken on demand | always available |

One process, one flag.

**As built.** The browser suites run the site's own worker in-process
over a `Map`, with `OH_OPEN_HOUSE` set: a key nobody has heard of is
written a subscription and a device binding like any other and licensed
for a month, which is one branch inside `entitlementOf` and is never on
in production — the worker honours it only for a request to
`localhost` or `127.0.0.1`, so the flag set on a real deployment by
mistake opens nothing. The same goes for CORS: a page served from a
local origin is answered only by a worker that is itself local. The
rig signs with BIP-340's published pair and
`e2e/build.sh` compiles the app to expect it — a key that licenses one
machine's rig and nothing else. So the suites exercise the real handler,
the real signature and the real gate, rather than a door propped open
for them.

## The relay, and the table over it

`service/` is, so far, the local relay — and only that: matchmaking
is the players' own business on the relay (doc 04, "The live table"),
and so are results and ratings. The relay is a subset of our wire
format (Nostr's NIP-01, which it began as) in a few hundred lines of
Dart — `EVENT`, `REQ` with filters on ids, authors,
kinds, `since`, `until`, `limit` and single-letter tags, `CLOSE`, and
`OK`, `EOSE` and `NOTICE` back. Every event's id and BIP-340 signature
are checked before anything else sees it. Stored kinds live in memory
up to a cap; the kinds the table uses are ephemeral (20000–29999),
forwarded and forgotten, because the protocol's own repeat-and-catch-up
already recovers a dropped message and nobody needs a relay to remember
a game.

`packages/table` has the other side: `RelayTransport`, a [Transport]
that wraps each table message in an ephemeral event of kind 24242,
tagged with the table id and signed by the sender, and subscribes to
the same — on every relay in its list, writing to the first that has
not refused it lately and moving a refused event on to the next
(`relays.dart`; doc 04, "The live table"). A deployed build's list
is one relay, ours, with the table id in the address. The local relay
takes a `refuse` policy so a test can be the relay that turns on a
client. What arrives is stamped *from* the envelope's signer — the
peer that sent it, which for a relayed message is not the author — and
that is the distinction "heard from" rests on. The relay says nothing
when a peer goes, so the transport never reports a disconnect; the
heartbeats carry that. Kind 24243 on the same wire is WebRTC
signalling — an offer, an answer, an ICE candidate — addressed with a
`p` tag to one recipient, who is the only one subscribed to it, and
sealed to that recipient's key with NIP-44 (`nip44.dart`, version 2,
written out in Dart and pinned to the published vectors), since a
candidate carries an address and anyone can read what the relay carries.
The two ends' conversation key comes from their keys' shared point
(`Signer.sharedXWith`), the same ECDH the deal's escrow rests on.

What the path itself carries is measured
([measurements/relay](../measurements/relay/README.md)) — and it is the
relay path only: a data channel carries the event as bytes instead,
which is 36% less again (`packages/table/lib/src/frame.dart`), because
a channel has our own code at both ends where a relay has to read,
check and sometimes store what it is given. On the relay, then: 366 bytes of
envelope on an event, a third more again for anything that is not text,
a signature to send one and a rehash and a signature to accept one at
the relay and at every receiver — about 1,650 small events a second on
a loopback, seven tenths of which is the relay checking them. That
was the budget for a juror, which had no other path — the case doc 04
calls "the party that had no channel". A juror drawn from somebody's
app has one now: the summons introduces it and the seats dial it, so
its play crosses a data channel and the relay carries its signalling
(`Transport.reach`, `JurorDuty.dial`). The figures above are still the
budget for the jurors of last resort here, which run in a Dart VM with
no peer connection in it and so stay on the lane doc 02 keeps for
exactly that.

**And what a hand costs it, end to end**
(`service/tool/wire_over_socket.dart`: a counting proxy in front of
the relay, a sealed hand with two people and two bot seats the bench
holds). Five to seven megabytes across the sockets uncompressed; about
1.5 with **permessage-deflate**, which is 74% off and now agreed to —
the clients were always offering it and the relay was refusing,
because `shelf_web_socket` does not do the extension. The upgrade is
dart:io's own now. Half of what a table sends is base64 of curve
points, which no compressor touches, and half is JSON keys, hex ids,
keys and signatures, which go thirteen to one; duplication is what
makes the ratio as good as it is.

The duplication is worth its own line. Of a megabyte published in a
hand, the largest single item was deal turns being said again by
somebody who did not author them: a turn that has not settled is
repeated, and a repeated shuffle argument is twelve kilobytes every
time. A seat now says its own turn again after two seconds, and
everyone else waits ten before carrying it — long enough that
carrying means what it was built to mean, a table cut in two rather
than a message dropped once. Measured in the simulator, where the
count is exact: 21% off everything said and handed over at a jury of
four, 17% at six.

Nothing negotiates compression in the rig that drives the suites
(`service/do/ws.mjs` says so in its own header), so every number
measured there is the uncompressed one.

`service/test/table_over_relay_test.dart` seats two people and two bots
on the local relay with real keys, real sockets and the wall clock, and
they play a hand: 28 decisions, every one signed twice and verified by
the other side, in about four seconds. That is the cost the app pays,
measured — and it is why the web app will not sign in Dart: the same
signature that takes 11 ms in the VM takes 100 ms compiled to
JavaScript, and 0.6 ms as wasm
([measurements/sign](../measurements/README.md)).

## An object per tag

A relay is a meeting point, and a meeting point costs whatever it holds
open. Ours is a **Cloudflare Durable Object per tag** (`service/do/`):
`wss://relay.openhearts.game/<tag>`, the tag in the path because the
object has to be named before the socket is opened, and everyone on
that tag lands on that one object wherever they are — no fan-out
between machines, no database in the middle. Every tag is its own
object: a table's id (its events and its signalling), a pool's
`queue:…` (waiting to be matched), a room code, `results`, and
`online` for presence. It is the only relay a deployed build or a
juror of last resort talks to ([doc 08](08-own-relays.md)); presence
ran on it alone from September, and everything else moved to it from
the public Nostr relays on 3 October 2026.

**It is the one relay, so it is watched.** If the object is down, live
play is down, as it is when the licence handler or TURN is: they are
all on Cloudflare. The monitors (`observability/`) watch it, and the
remote config's `relays` can point the tables at another relay of ours
without a release.

**Marked in the list, never assumed.** A relay that keeps one object
per tag wears `{tag}` where the tag goes, and the client that has a tag
puts it there (`tagMark`, `presence_relay.dart`; `relaysForTag`, used
by the table's transport as well as presence). It cannot be inferred
from a hostname in either direction: a relay that serves every tag at
its root would answer a path with a 404, and a sharded one cannot serve
a client that gives it no tag. Presence, tables, signalling, pools,
rooms and results now take the same list (`presenceRelays`,
`app/lib/net/relays.dart`).

**Hibernation, which is the difference between free and a monthly
bill.** The object hands its sockets to the runtime
(`state.acceptWebSocket`) instead of holding them itself
(`server.accept`), so an open socket costs nothing while nothing is
being said on it: the object is evicted and charged for none of that
time, where accepting the socket itself would have held the object —
and its duration charge — up for as long as anybody was connected, all
night, on every tag. What an evicted object loses is its memory, so
each socket carries its own subscriptions
(`serializeAttachment`) and they come back with it; that ride has a
size limit, so a socket is held to a few subscriptions and the oldest
goes as a new one arrives — bounded as it is written, which is the
rule for everything here.

**Bounded per socket.** Every tag is open to anybody who can open a
socket, and anyone may subscribe to any tag and read what it carries, Cloudflare hands an object messages of up to 32 MiB, and an
event that matches presence goes on to every device listening, on the
one thread they share — one message of four megabytes was 800 MB out
to two hundred listeners and three seconds of that thread. So the
object (`objectRelay`, `objectLimits` in `relay.mjs`) reads no message
longer than 64 K characters, which is several times a summons, the
largest thing presence says; takes a REQ of a kilobyte at most, so
eight of them ride in the 16 KiB a socket's attachment may carry; and
holds each socket to a burst of thirty events and two a second after,
refused before their signatures are checked. Those are presence's,
and the operator can change them; a table's tag carries a deal's
steps and every seat and juror repeating what is unsettled, so it
takes messages of up to 128 KiB and a burst of two hundred and twenty
a second after (`tableLimits`). The node host under the suites is held
to none of it.

**Only the lobby is written down.** Presence, table events,
signalling and waiting to be matched are ephemeral kinds, forwarded to
whoever is listening and forgotten. The `online` object stores nothing
and refuses any other kind with a reason. Every other tag's object
keeps one kind, 4244, the lobby — a room announced, a pool's seating,
a table started, a player's picture, a game's result — and only when
the event's `t` tag is that object's own tag, so nobody writes into
one tag's store through another's (`refusalFor`). It is kept in the
object's own storage (`tag_store.mjs`), so it is still there after
eviction, and a new subscriber is answered with it. A room, a seating,
a start or a picture is kept a day, then deleted by an hourly alarm
(`KEPT_MS`); results, under `results`, are kept for good in storage,
since the ratings are folded from all of them, and the newest 20,000
are held in memory (`storedKeep`). A picture is at most 12,000 bytes
and is sent again on each join of a room or pool. Rows can be deleted
from a tag's storage by hand, which is how a request to delete a
device's results is met.

**One relay, two runtimes, one set of tests.** The core
(`service/do/relay.mjs`) speaks the same subset of our wire format as
the Dart relay, written as plain functions over anything that can send a
string: no Cloudflare imports and no node ones, signatures through the
very wasm the app carries (`app/web/schnorr.wasm`, handed in compiled
because a Worker may not compile one at runtime) rather than a third
implementation of BIP-340. That is what lets it be tested properly.
`service/do/host.mjs` hosts it on a plain node socket — the handshake
and frames of RFC 6455 written out, since node ships a WebSocket
client and no server — and `OH_RELAY=js` puts that host behind the
`Relay` class the Dart tests already construct, so every suite in
`service/` runs against either relay with nothing about the tests
changed:

```bash
cd service && dart test                  # the Dart relay
cd service && OH_RELAY=js dart test      # the relay the object runs
node --test service/do/*.test.mjs        # the core, and the sockets under it
```

The local host takes the simulator's signatures as well as real ones,
by their length, exactly as the Dart relay does and for the same
reason (`signing.dart`); the deployed object knows BIP-340 and refuses
everything else.

**Deploying it.** `cd service/do && npx wrangler@4 deploy` — the
binding (`TABLE`), the class and the SQLite migration are in
`wrangler.toml`, and a first deploy answers on the worker's own
`workers.dev` host. The name the app looks for is a Workers custom
domain on `relay.openhearts.game`, which writes its own DNS record and
needs the zone to be on the account. It is: the relay is deployed
there, and a build with nothing else configured finds live play down
when the object is.

## Language and layout

The juror runs the bot policy — it plays the bot seats it holds
([doc 04](04-live-play.md), "Playing a seat nobody holds") — and the
bot is Dart. So the juror is Dart, and rather than carry a second
language for two hundred lines of handlers, the whole service is Dart. The one exception is the
object per tag, which is JavaScript because the runtime it hibernates
on is: a few hundred lines of relay that the Dart suites hold to the
Dart relay's own behaviour, rather than a runtime chosen to keep the
language. Locally that is one
`dart run`; in production it is a container, or Dart on a serverless
runtime — a packaging decision, deferred.

```
packages/engine/     the rules and the bot — shared by app, table and service
packages/table/      the table protocol — signed events, membership,
                     departures, the play chain — pure Dart over an
                     abstract transport and clock, with its simulator
app/                 Flutter: the table package over WebRTC, and the UI
service/             handlers, juror, storage adapters, local relay
e2e/                 Playwright, driving real browsers against the local service
site/
docs/
```

Extracting the engine into its own package comes before the service
exists, so nothing is ever imported across the app/service line. The
table protocol is a package for the same reason, and one more: the same
code has to run under a simulated network and a real one.

## The departure matrix

The protocol's whole job is to keep four seats playing while people
come and go, and the cases multiply: how many humans, who goes, how,
and when. Written out it is thousands of cells, so the tests are in
two layers that drive the same client code with the network and the
clock swapped.

**The simulator** (`packages/table`) runs every client as an in-process
object over a simulated network — controllable latency, drops, and
partitions — on a virtual clock. The whole matrix runs in seconds,
every failure replays from its seed, and it runs in CI on every commit.

**Real browsers** (`e2e/`): Playwright drives four headless browsers as
players against the local relay and the built app, with real WebRTC
between them, through the app's own screens — it finds the buttons,
the cards and the state pills in the accessibility tree the app grows
on request. Host a room, join it by code, a hand over WebRTC in under
half a minute; then the cells only a browser can show: one closed
mid-hand and replaced by a bot within ten seconds, one stalled on its
turn and booted by the others when its clock runs out, one that leaves, and the
last person finishing the hand with three bots. That is what proves
the transport. The juror stepping in for a table drained to one human
joins the suite with the jury. It runs in CI on every commit.

The axes:

| | |
|---|---|
| **Live humans at the start** | 1, 2, 3, 4 — bots in the rest. A table reaches 1 by departures too, so this axis is not independent of the others. |
| **Who goes** | one player; two players in the same window; two in sequence; a juror; the foreman; two jurors; the whole jury |
| **How** | a signed Leave; a silent drop, found by timeout; a boot when the seat's clock runs out; a two-and-two partition, which is not a departure but looks like one from inside |
| **When** | on the departed seat's own turn; off it; mid-trick; the last trick of a hand; during the pass; during the deal; at a hand boundary |

The juror rows run in `packages/table/test/jury_test.dart`, with the
jury of [doc 04](04-live-play.md). The sealed rows — the same simulator
with the verifiable deal of [doc 03](03-fair-deal.md) run for real, its
proofs made and checked on the virtual clock — run in
`packages/table/test/sealed_test.dart`: whole games at one, two and
four people, a leaver mid-hand and during the deal, a table of two
surviving a crash by the jury's verdict and a juror's escrow piece, and
a lone player leaving during the pass while their client looks on. The
chaos walk runs sealed on request (`dart run tool/chaos.dart --sealed 5`), a minute or two a
seed. Over real sockets (`service/test`): the jury over the relay,
seeded and sealed; and a juror of last resort summoned into a sealed
table of four with real keys, carried through the hand it never saw
dealt while it heartbeats throughout.

**The chaos test** is the matrix's complement: random walks through
the same simulator — departures, partitions, blips, loss and latency at
random times — checking every few seconds of virtual time that no two
survivors hold conflicting decisions, that every record verifies as far
as it goes, and that every state change is one the protocol's explicit
model (`packages/table/lib/src/model.dart`: a turn is open, acting,
contested, split or settled; a seat is human, left, booted, absent or
bot; the table is playing, paused, or finished) allows. Its first hour
found four things the matrix had not; its first 250 seeds found six
more, among them a relayed event mistaken for a sign of life, a leave
that was never re-sent, and a pass lost between a hand opening and its
bots passing; and its first thousand settled a design question — where
a silent seat may be removed — by finding a fork in the answer that
looked more helpful (doc 04, "Silence is answered at the seat's own
turn"). A thousand seeds now finish or pause for the jury with every
survivor holding the same record. CI walks forty seeds on every commit;
`dart run tool/chaos.dart --seeds 1000` walks a thousand.

**The explorer** (`packages/table/tool/explore.dart`) is the chaos
test's complement for orderings. Random faults find what random faults
find — a juror gone, a relay out, loss for a while — and rarely the
other kind: one peer hearing two things the other way round from
everybody else, or the one copy of something that mattered not
arriving at one peer. Five fixes of that kind, undone one at a time,
and the walk caught one. The explorer takes a small sealed game, runs
it once to list every event said in its first seconds and every peer
it went to, and then runs it again once per event, peer and change:
the first copy lost, or every copy held back a couple of seconds. The
simulator is deterministic and the change draws no randomness of its
own (`SimNetwork.steer`), so each run is the first with exactly one
thing different, held to a finished first trick, one reading of every
bot seat's juror, and a sound record. Membership changes go first — a
jury, a top-up, a leave — then the protocol's steps, then the routine
traffic. The deal's cryptography is remembered across runs
(`MemoCrypto`), since each run repeats most of the one before: a run
is a seventh of a second where it was eight, and a scenario's thousand
or so runs take two to five minutes.

Its first sweeps found two faults in code the walk had passed: a
jury witness lost on its way to the proposer, which nothing ever
said again (`lost_jury_witness_test.dart`); and a bot seat played
twice, the same card by its late juror and by the custodian the table
had given it to, splitting a table of two with nothing to see the
split (`two_voices_test.dart`). `--match` replays one run with every
client's trace.

A single change to one message cannot move the scenario's own fault,
and some faults matter only at a moment — a leave that lands while the
deal is being built rather than after its keys — so `--fault-at`
walks the fault through several times, each time's baseline first.
Measured against five fixes of the kind, each undone in a scratch copy
of the client: the walk, given eight sealed seeds and about twelve
minutes each, caught one (a juror saying its own deal step again). The
explorer caught that one at its 25th run, six seconds in, and one the
walk missed — bot seats read from the seat list as it stood rather
than as the hand began — at its 11th, with the leave moved to half a
second. The other three it missed over five to eight thousand runs
each: two want a juror summoned into a redraw partway through a hand,
which only the top-up scenario makes and which plays a whole hand at
1.7 s a run; the third (a drain after the deal's turns open) the
simulator never reproduces at all — its own unit test never failed
either — and it was found in the browsers.

What every cell asserts:

- **The game reaches its end** with a bot in every departed seat — or,
  where the survivors are too few to carry a removal and there is no
  jury to be drawn, the table **pauses and says so**, stays consistent
  while paused, and ends the game once the departed have been silent
  as long as a person is given: "juror quorum lost" ([doc
  04](04-live-play.md), "When quorum is lost anyway").
- **Every surviving client holds the same record**, event for event,
  once the network settles.
- **The record verifies**: every human play signed by its seat's key and
  legal under the engine, every bot play recomputable from the deal —
  and at a sealed table, every proof of the deal, every token, every
  audit, with every play checked against the hand it came from.
- **Ratings follow doc 04's two rules**: a bot in the winning seat moves
  nobody; a live winner moves everyone, leavers included.
- **A play at 14.9 seconds beats a boot at 15.0**, and a peer holding
  the play rebroadcasts it instead of countersigning the boot.
- **Nobody is removed without a strict majority** of the last agreed
  participant set, so a partition never forks: neither side can act,
  and when it heals there is one record.
- **Nothing hangs**: the virtual clock advances until the game is over
  or the pause is explained on screen.
