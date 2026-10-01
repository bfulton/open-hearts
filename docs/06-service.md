# 06 — The service

What runs on our side, which is deliberately little. The game is peer to
peer ([doc 02](02-multiplayer.md)), the deal is verifiable
([doc 03](03-fair-deal.md)), presence rides relays and bot seats are
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
SUB#<subscription>         META           source, txn_ref, renews_at, cancelled_at
SUB#<subscription>         DEVICE#<key>   bound_at
KEY#<key>                  ENTITLEMENT    subscription, licensed_until, at
TICKET#<code>              META           subscription, expires_at, used_at
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
deployment. A bucket is reserved for archiving public game records,
since relays do not promise retention; whether the service subscribes
to relays or clients post copies is undecided, and nothing depends on
it yet.

## What is paid for, and how

Live play is a subscription: **$2.99 a year**. Everything else is free
and stays free — the bots, the records, the verifiable deal, the engine
itself. What the money is for is the part that costs us money to run:
relaying people to each other, TURN when a direct path will not form,
and jurors when a table is left alone.

A year rather than a month, for an unglamorous reason. At three dollars
a month the fixed part of a card fee — thirty cents on Stripe — is ten
per cent of the price, and a store's cut is taken on top; at three
dollars a year the same fee is paid once. $2.99 nets about $2.60 through
Stripe after 2.9% + 30¢, and about $2.54 on a store at the small
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

The store half is not built, and cannot be until the app is in a store
(README, roadmap 8). Until then `canBuyHere` is false off the web and
says so rather than opening a checkout a phone should not be using.

Three things have to be set on the project for any of it to work:
`OH_STRIPE_SECRET`, `OH_STRIPE_PRICE` (a yearly recurring price) and
`OH_STRIPE_WEBHOOK_SECRET`, with the webhook pointed at `/api/stripe`
for `checkout.session.completed` and `customer.subscription.*`. Without
them the shop says it is not open yet, which is what a deployment with
no keys should say.

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
and the other device opens that link with its own camera — so there is
no camera in this app and no permission to ask for, which is most of
why this is the cheap way in. A device with no camera pointed at the
screen gets the same link through the share sheet, as a room's link
goes.

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

A code does not take a device off another subscription that is still
paid up. A code arrives in a link and is spent the moment the app
opens it, so a stranger with a subscription of his own could
otherwise send one to somebody else's phone, take it off the
subscription its owner paid for, and drop it from his. A device
moves on by dropping itself first; one whose subscription has ended
is free to go, and so is one licensed by local mode's open house,
which was never anybody's purchase.
Dropping a device takes away its binding **and** its entitlement row —
not merely the date on it: the subscription is still paid up, so a row
that had only run out would be dated forward again on that device's
next ask. The one it holds runs out on its own within the month, which
is what a licence with no revocation list can promise and all it can.

TURN is Cloudflare's.

## Local mode

The service runs entirely locally for end-to-end tests, with the same
code and different adapters:

| | Production | Local |
|---|---|---|
| Storage | DynamoDB | in-memory, same shape |
| Sign-in | Apple/Google published keys | `local:<subject>`, a token naming a `sub` |
| Entitlement | store and Stripe webhooks | an open house: a key that asks is licensed for a month |
| TURN | Cloudflare | none; localhost connects directly |
| Signalling, waiting rooms, results | our own relay and a few public ones, listened on together; table events written to one relay everyone reads, ours preferred while up; lobby, signalling and whatever goes unanswered to all | a minimal NIP-01 relay in the repo |
| Last-resort jurors | woken on demand | always available |

One process, one flag.

**As built.** The browser suites run the site's own worker in-process
over a `Map`, with `OH_OPEN_HOUSE` set: a key nobody has heard of is
written a subscription and a device binding like any other and licensed
for a month, which is one branch inside `entitlementOf` and is never on
in production. The rig signs with BIP-340's published pair and
`e2e/build.sh` compiles the app to expect it — a key that licenses one
machine's rig and nothing else. So the suites exercise the real handler,
the real signature and the real gate, rather than a door propped open
for them.

## The relay, and the table over it

`service/` is, so far, the local relay — and only that: matchmaking
is the players' own business on the relay (doc 04, "The live table"),
and so are results and ratings. The relay is a NIP-01 subset in a few
hundred lines of Dart — `EVENT`, `REQ` with filters on ids, authors,
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
(`relays.dart`; doc 04, "The live table"). The local relay takes a
`refuse` policy so a test can be the public relay that turns on a
client. What arrives is stamped *from* the envelope's signer — the
peer that sent it, which for a relayed message is not the author — and
that is the distinction "heard from" rests on. The relay says nothing
when a peer goes, so the transport never reports a disconnect; the
heartbeats carry that. Kind 24243 on the same wire is WebRTC
signalling — an offer, an answer, an ICE candidate — addressed with a
`p` tag to one recipient, who is the only one subscribed to it, and
sealed to that recipient's key with NIP-44 (`nip44.dart`, version 2,
written out in Dart and pinned to the published vectors), since a
candidate carries an address and a public relay carries the event.
The two ends' conversation key comes from their keys' shared point
(`Signer.sharedXWith`), the same ECDH the deal's escrow rests on.

What the path itself carries is measured
([measurements/relay](../measurements/relay/README.md)) — and it is the
relay path only: a data channel carries the event as bytes instead,
which is 36% less again (`packages/table/lib/src/frame.dart`), because
a channel has our own code at both ends where a relay has to read and
store what it is given. On the relay, then: 366 bytes of
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
between machines, no database in the middle. Presence is one tag,
`online`, and one object. Tables and matchmaking have not moved.

**It is preferred, and nothing depends on it.** The beats still go to
every relay the device can write to, the public ones included: a device
is online for whoever can hear it, and what another device can reach is
not ours to assume — a build from before the object existed, a network
that blocks the host, a deploy that is down. So a device on the object
and a device on the public relays alone see each other, and the day the
object is not there presence is exactly what it was before it existed
(`service/test/presence_object_test.dart`).

**Marked in the list, never assumed.** A relay that keeps one object
per tag wears `{tag}` where the tag goes, and the client that has a tag
puts it there (`tagMark`, `presence_relay.dart`). It cannot be
inferred from a hostname in either direction: a public relay serves
every tag at its root and would answer a path with a 404, and a
sharded one cannot serve a client that gives it no tag. That is also
why the marked relay is in the list presence takes
(`presenceRelays`, `app/lib/net/relays.dart`) and not in the list
tables and signalling take — a table has nowhere to put its tag until
it moves here.

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

**Nothing is written down.** Presence is ephemeral by definition,
forwarded to whoever is listening and forgotten, so the object has no
storage to pay for, none to read on the way back from hibernation, and
nothing that could ever need a scheduled sweep. A kind that is not
ephemeral is refused with a reason rather than quietly dropped, and the
client writes it to the relays that keep things.

**One relay, two runtimes, one set of tests.** The core
(`service/do/relay.mjs`) is the NIP-01 subset the Dart relay already
speaks, written as plain functions over anything that can send a
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
needs the zone to be on the account; until it is, builds find the
object down and presence rides the public relays, which is the same
thing that has always been true of `nostr.openhearts.game`.

## Language and layout

The juror runs the bot policy — it plays the bot seats it holds
([doc 04](04-live-play.md), "Playing a seat nobody holds") — and the
bot is Dart. So the juror is Dart, and rather than carry a second
language for two hundred lines of handlers, the whole service is Dart. The one exception is the
object per tag, which is JavaScript because the runtime it hibernates
on is: a few hundred lines of NIP-01 that the Dart suites hold to the
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
