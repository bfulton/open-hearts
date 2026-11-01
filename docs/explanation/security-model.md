# Security model

This page explains what a stranger can make the system do, and how
each part defends against it. It covers the Pages worker
(`service/functions/worker.mjs`), the relay worker (`service/do/`), the
house (`service/bin`), the local relay host (`service/lib`), `deploy.sh`, the
site's headers, and the app's side of each call (`app/lib/net/`). The
fairness and privacy of the deal itself are covered in
[the fair deal](fair-deal.md).

## What an attacker starts with

- **Every device's public key.** A key signs every event its device
  says at a table, and the relay serves those events to anyone.
- **Any socket to the relay, on any tag.** The relay is open.
- **The source code.** Nothing depends on being secret except the keys
  in the project's secrets. The deal's fairness is the protocol, and the
  protocol is meant to be read.
- **A subscription of their own**, for the attacks that need one.

## Requests act only for the key that signed them

A public key alone is nobody. Every handler that acts for a device
requires `{key, at, sig}` (which handlers they are is in the
[service reference](../reference/service-api.md)): a BIP-340 signature
by the key over `oh-request/1`, the
handler, the key, the second, and whatever else the request asks for
(`askedBy` and `signedFor` in the worker; `signedAsk` in
`app/lib/net/licence.dart`). Without this, anyone who had seen a
subscriber online could list the household, drop its devices, mint a
code against it and claim it, or open a checkout for the victim's key
and later end it to strand the device.

- The handler name is signed, so a licence request cannot be replayed
  as a code request.
- Requests too far from the service's clock are refused
  (`requestToleranceS`, a [service setting](../reference/configuration.md)). Nothing is stored to stop a replay inside that
  window. A replay needs the request itself, which travels only over
  TLS to our own origin, and the one most worth replaying (`ticket`)
  returns its code to whoever sent it. This is accepted.
- The statement's hash is pinned in tests on both sides
  (`worker.test.mjs`, `licence_test.dart`), so the two implementations
  cannot drift.

## Sign-in

A provider's ID token must carry a nonce equal to the hash of the
device's key. The nonce is chosen by whoever asks the provider, though,
so it shows which key the token was made for, not that the key consented.
The request is therefore also signed by the key. Otherwise a stranger
could bind his own account to a subscriber's key with `attest`, then
`supersede` it onto his own key and carry her subscription with it.
Tokens are verified against the provider's fixed JWKS URL with
allow-listed algorithms (RS256, ES256), checking issuer (Google's in
either of the two forms it signs with), audience (one of a configured
list), expiry, subject and nonce. A malformed token is a 401, never a 500. Only
an HMAC of the subject (`OH_ID_HMAC`) is stored.

Sign in with Apple's notifications (`apple-id`) are checked against the
same key set, issuer and audiences, and an expiry (a day from `iat` when
the token gives none). They must carry an `events` claim with a type and
a subject, so an ID token posted there does nothing. The most a genuine
notice can do is unlink the Apple sign-in it names, which a replay only
does again, and nothing it does locks the person out
([when Apple says a sign-in is gone](service.md#when-apple-says-a-sign-in-is-gone)).

## Licences

A licence is domain-separated (`oh-licence/2`) and checked against the
public key before it is issued ([licence](service.md#licence)). The app
takes BIP-340 signatures and nothing else. The simulator's fake
signatures, whose "signature" is a hash of the signer's public key, are
checked only in a process running the simulator (`packages/table_sim`),
which no build includes, and a licence takes a real signature's length
even there: the service's public key is in every build, so a fake one
would license anybody.

Licences are not revocable, which is why they are short. Dropping a
device deletes its entitlement row, so that the row cannot be dated
forward again, and the licence the device already holds runs out on its
own.

## Payments

- **Stripe's webhook** reads nothing until `Stripe-Signature` verifies
  over the raw body, compared in constant time
  (`crypto.subtle.verify`). The timestamp must be recent
  (`webhookToleranceS`), and every `v1` is tried so a rotating secret works. With no secret
  configured it refuses everything.
- **A checkout binds a key only if this service opened it.** The key is
  read from `metadata`, which only our checkout writes, never from
  `client_reference_id`, which a Payment Link accepts from its URL. The
  session must be a subscription with `payment_status` `paid` or
  `no_payment_required`, so a pending bank transfer binds nothing until
  it clears.
- **Events out of order cannot revive a subscription.** Each row keeps
  the time of the event that wrote it and ignores older ones. Nothing is
  news after a deletion or a final status. An ending also writes down
  every device's entitlement row, so a refund takes effect at each
  device's next ask, not a month later.
- **Store purchases**: an App Store transaction's chain must end at the
  pinned Apple Root CA – G3 through the WWDR and App Store marks, and
  must be this bundle and product. A Play token is checked with Google
  and acknowledged. Store notifications are verified the same way (Play
  through the push's Google ID token).
- **Return addresses** must be this site's origin. The app only leaves
  for Stripe's own hosts. There is no open redirect.

Open: another product checked out through the Stripe API with our
`key` metadata would bind a device. The account must keep to this one
product.

## Households

- **A code cannot take a device off a subscription somebody paid for**
  ([accounts](service.md#accounts)). A claim link is easy to accept from
  a stranger. Without this rule, a stranger could pull a subscriber's
  device onto his own subscription and then drop it.
- **Codes** are 128 random bits from `crypto.getRandomValues`
  (`TICKET_BYTES`), one-use, good for a few minutes (`ticketMinutes`),
  and carry nothing about the subscription. Their rows expire from KV
  soon after (`TICKET_KEPT_S`). Backup codes are 80 bits, and their
  rows are keyed by a digest of the code.
- **One change at a time.** Two claims of one code, or of two codes
  into the last place, cannot both succeed, since every change to an
  account takes its turn in one object
  ([one account at a time](service.md#accounts)). A preview's accounts
  take their turns in the preview relay's objects, the same way.
- **Rate.** A household is limited to so many changes and reads an hour
  (`householdChangesPerHour`, `householdReadsPerHour`).
  Asking for a code while one is outstanding returns the same code, so
  it costs a read, not a write. What a device asks on a licence that
  the store where it asks doesn't back has an allowance of its own, the
  size of the reads'. That covers a device just brought in, and one
  dropped from the household that still holds its licence, so a dropped
  device spends none of the household's
  ([one account at a time](service.md#accounts)). A device coming in,
  with a code, a backup code or a sign-in, has an allowance of its own
  too, the size of the changes', and a code the store already shows as
  spent or run out is turned away before the account's turn is asked:
  whoever once saw a code can keep asking with it, and spends nothing
  the household's own devices need.

## TURN

TURN credentials are a relay their holder can push any traffic through
until they expire (`turnTtlS`), billed by the gigabyte. They are minted only for a
signed request from a device whose subscription stands. A subscriber can
still mint as many as it likes, which is left to the rate limit below
and the account's spend alerts (`infra/cloudflare.mjs`).

## The relay

The relay is open to anybody who can open a socket, and each tag's
object runs on one thread shared by everyone on that tag.

- Every event's id is recomputed and its BIP-340 signature checked
  before anything else sees it, and so is the id of a table event
  inside one (`service/do/referee.mjs`). Key and signature shapes are
  checked before they are written into the wasm's memory. Nobody can
  sign as another key, and nobody can silence a table by saying its
  events first, since a duplicate id can only be the same signed event.
- A table's log takes at most `authorMost` characters of each person's
  events, as much as a whole kept game may be, so one seat's events
  cannot grow its table's object until it fails, or make every
  reconnecting side read without end. The house is the operator's and
  is not held to it. A tick (`TICK`) is taken only from the table's
  people and its house, at most one every `tickGapMs`, none after the
  house's word on the game, and none past `ticksInARowMost` since the
  last event. So nobody else can lengthen the log with ticks, nobody
  can once the game is over, and at a table whose house never says that
  word (one with no house, or one the house will not serve) its people
  cannot tick for ever. Once the log holds `notesMost` ticks and
  connections noted, it takes no more ticks and notes no more
  connections closing. It still notes a person back whom it last noted
  gone, or they would stay gone on every side's rules and lose their
  seat at their next turn; nobody is noted gone after that point, so
  this happens at most once for each, and otherwise only events grow
  the log. These bound each table. A subscriber can still start as many
  tables as it likes, which is left to the account's spend alerts.
- Each socket is bounded: message size, REQ size (so a socket's
  subscriptions always fit in the attachment a hibernating socket
  carries), a few subscriptions (`maxSubscriptions`), and a
  burst-then-rate limit on publishing, and on asking for a table's log,
  that refuses floods before checking signatures. An event is serialised
  once for all listeners. Presence uses the tighter `objectLimits`,
  tables use `tableLimits`.
- A socket that has not answered the challenge has what it says held
  up to `heldMost` messages and `heldMostChars` characters, and may
  answer the challenge once, so it costs the object at most two
  signature checks and a bounded amount of memory.
- Remembered ids are capped. Tag names are a single strict path
  segment.
- An object stores only the lobby kind tagged for its own tag, so nobody
  writes into another tag's store. Presence stores nothing.
- **Presence replay.** Every presence event is public and can be sent
  again once a relay forgets its id. A device accepts a `here` or `gone`
  only if it is a few beats old at most, not far in the future, and
  newer than the last one it took from that key
  (`packages/table/lib/src/presence_relay.dart`,
  `presence_replay_test.dart`).

The Node host and the rig's house listen on loopback and are not
deployed. The Node host's WebSocket framing closes the
connection on an oversized or fragmented control frame or an unmasked
frame (`service/do/ws.test.mjs`).

## The worker as a whole

- **Body limits.** A handler reads at most `MOST_BODY`, a profile
  `MOST_PROFILE_BODY`, a game record `recordMost`
  (`service/functions/records.mjs`), and the payment webhooks
  `MOST_EVENT`.
- **Rate limits.** A Cloudflare rule limits `/api/*` (except the
  webhooks: Stripe's, the stores' and Sign in with Apple's) and the
  relay host to a rate per address (`infra/cloudflare.mjs`). An unsigned or wrongly signed request
  costs a parse and one signature check and touches no storage.
- **No SSRF.** Every outbound fetch goes to a fixed host: Cloudflare's
  TURN API, Stripe, Apple's and Google's key sets and Play's API, and the
  worker's own assets. Nothing a caller sends becomes a URL.
- **KV keys** are built only from validated parts (64-hex keys, codes,
  digests) and from subscription ids that arrive in verified events.
  Nothing a caller sends can add a `|` or reach another prefix.
- **Local mode is local.** `OH_OPEN_HOUSE` licenses every key and
  accepts `local:` sign-ins, but the worker honours it only for requests
  to `localhost`, `127.0.0.1` or a name under `.localhost` (the browser
  rig's stand-ins for the site and the app). Cloudflare routes no such
  host to the project. Local origins get CORS only from a local worker.
- **Errors** describe what went wrong in words and upstream status
  codes, never stack traces or upstream bodies.
- **Game records** are accepted only from a subscriber's device in use
  that is seated at the table and has signed events of its own in the
  record, within an hourly allowance (`recordsPerHour`), and are
  size-capped (`service/functions/records.mjs`). They are verified by
  whoever views them, not by the worker.

## The site

Every path is served with `Content-Security-Policy: frame-ancestors
'none'`, `X-Frame-Options: DENY`, HSTS, `nosniff` and a strict referrer
policy (`site/public/_headers`), so no other page can frame the app and
steer its one-tap buttons. One page is excepted: `openhearts.game/carry`,
which hands a device's storage to `play.openhearts.game`. Only that
origin may frame it, it has no buttons, and it answers only that origin
([the device, carried over](service.md#the-device-carried-over)). The app loads these
third-party scripts:

- New Relic's browser agent, on every page of play.openhearts.game
  only, which its loader (`app/web/observability.js`) fetches from
  `js-agent.newrelic.com`, its chunks pinned by integrity hashes.
- A sign-in provider's script, on the Subscription page once that
  provider's sign-in button is on the screen
  (`app/lib/net/provider_tokens_web.dart`): Apple's `appleid.auth.js`
  from `appleid.cdn-apple.com` in a build with `apple.servicesId`, and
  Google's client from `accounts.google.com` in a build with
  `google.webClientId`. These are not pinned.

Each runs in the app's own document, so it can read the app's storage,
the device's secret key included. Cloudflare's Web Analytics and email
obfuscation are off, since both inject scripts.
Open: a fuller CSP (`script-src`) has not been set. The Flutter build
needs `wasm-unsafe-eval`, and the policy has to be tested against it.

## Secrets

The service key, Stripe keys, the TURN token, the HMAC key and the
house's secret are Cloudflare secrets, checked only by name
(`infra/apply.mjs`). The service key is minted with a CSPRNG by
`service/bin/service_key.dart`, and `oh key mint` sets its secret on
the Pages project without showing it, as `oh house key` does the
house's: neither secret is written anywhere else. The rest are typed
into `oh secret set`, which does not show them either. `deploy.sh`
reads only environment variables. Every deploy runs Wrangler with its
whole dependency tree locked (`ops/wrangler`), and `oh` gives it, and
`deploy.sh`, only Cloudflare's credentials. The Android release key's
properties file is never checked in. Every key in the repository is a published
test vector: BIP-340's test pair (used by the e2e rig and the relay's
self-check) and NIP-44's vectors.

**Previews hold none of production's keys.** A preview runs whatever
branch was deployed to it, reviewed or not, so the secrets it signs
with are its own ([previews](service.md#previews)): a service key pair
of its own, whose public half every preview build and the preview relay
name, an HMAC key of its own for the sign-ins it stores, and a house
key pair of its own, whose secret only the preview relay holds. It has
no TURN token, since no part of the game uses TURN. `oh preview
secrets` makes them and sets them without showing them, and `oh secret
set` puts production's on production alone. Nothing a preview signs is
good in production, and a preview takes nothing production signed: its
relay admits only activations its own key signed. Who plays on a
preview is the operator's say: there is nothing to buy, and an account
there is an invitation (`oh preview invite`).

**Deploying a preview runs the branch's own code with the operator's
Cloudflare token.** What a preview serves holds none of production's
keys, but what deploys it is the branch's: its `oh`, `deploy.sh` and
`site/build.mjs`, the Flutter, Cargo and Dart builds they start, and
the `[env.preview]` of its `service/do/wrangler.toml`, all run on the
operator's machine with `CLOUDFLARE_API_TOKEN`. That token is the
account's, so it can also deploy production and write production's
store. `oh` gives what it runs no credential but Cloudflare's, and only
an honest branch's `oh` does that. So a preview is deployed only from a
branch the operator has read, as before running any of its code,
`./check.sh` included. Open: previews in a Cloudflare account of their
own, deployed with that account's token, would let a preview be
deployed from a branch nobody has read.
