# Security model

This document reviews what a stranger can make the system do, and how
each part defends against it. It covers the Pages worker
(`service/functions/worker.mjs`), the relay worker (`service/do/`), the
local relay and juror (`service/bin`, `service/lib`), `deploy.sh`, the
site's headers, and the app's side of each call (`app/lib/net/`). The
fairness and privacy of the deal itself are covered in
[doc 03](03-fair-deal.md).

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
(`licence`, `checkout`, `manage`, `store`, `ticket`, `claim`, `devices`,
`backups`, `profile`, `attest`, `supersede`, `turn`, `record`) requires
`{key, at, sig}`: a BIP-340 signature by the key over `oh-request/1`, the
handler, the key, the second, and whatever else the request asks for
(`askedBy` and `signedFor` in the worker; `signedAsk` in
`app/lib/net/licence.dart`). Without this, anyone who had seen a
subscriber online could list the household, drop its devices, mint a
code against it and claim it, or open a checkout for the victim's key
and later end it to strand the device.

- The handler name is signed, so a licence request cannot be replayed
  as a code request.
- Requests more than five minutes from the service's clock are refused
  (`requestToleranceS`). Nothing is stored to stop a replay inside that
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
allow-listed algorithms (RS256, ES256), checking issuer, audience
(one of a configured list), expiry, subject and nonce. A malformed token is a 401, never a 500. Only
an HMAC of the subject (`OH_ID_HMAC`) is stored.

Sign in with Apple's notifications (`apple-id`) are checked against the
same key set, issuer and audiences, and an expiry (a day from `iat` when
the token gives none). They must carry an `events` claim with a type and
a subject, so an ID token posted there does nothing. All one can do is
unlink the Apple sign-in it names from its account. A replay unlinks it
again, which is nothing, so no `jti` is kept. The account's devices,
backup codes and subscription are not touched, so the person is never
locked out by it.

## Licences

A licence is domain-separated (`oh-licence/1`), never runs past what
was paid for, and is checked against the public key before it is
issued. The app accepts a licence only through the real BIP-340 path,
never the simulator's fake signatures (whose "signature" is a hash of
the signer's public key, and the service's public key is in every build).
It must also be for the device's own key and in date. A build with no
service key licenses nobody.

Licences are not revocable. That is why they last a month: an ended
subscription stops renewing, and dropping a device deletes its
entitlement row so that the row cannot be dated forward again. The
licence a dropped device already holds runs out on its own.

## Payments

- **Stripe's webhook** reads nothing until `Stripe-Signature` verifies
  over the raw body, compared in constant time
  (`crypto.subtle.verify`). The timestamp must be within five minutes,
  and every `v1` is tried so a rotating secret works. With no secret
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

- **A code cannot take a device off a subscription somebody paid for.**
  A claim link is easy to accept from a stranger. Without this rule, a
  stranger could pull a subscriber's device onto his own subscription and
  then drop it. A device on another paid-up subscription must drop itself
  first, and the app asks "Join this subscription?" before spending any
  code.
- **Codes** are 128 random bits from `crypto.getRandomValues`, one-use,
  good for ten minutes, and carry nothing about the subscription. Their
  rows expire from KV after an hour. Backup codes are 80 bits, and their
  rows are keyed by a digest of the code.
- **One change at a time.** KV has no compare-and-set, so two claims of
  one code, or of two codes into the last place, could otherwise both
  succeed. Every household change goes through the `Household` Durable
  Object for its subscription. Previews have no `HOUSEHOLD` binding and
  fall back to a per-isolate queue, so there the race is closed only
  within an isolate.
- **Rate.** A household is limited to 20 changes and 60 reads an hour.
  Asking for a code while one is outstanding returns the same code, so
  it costs a read, not a write.

## TURN

TURN credentials are a relay their holder can push any traffic through
for four hours, billed by the gigabyte. They are minted only for a
signed request from a device whose subscription stands. A subscriber can
still mint as many as it likes, which is left to the rate limit below
and the account's spend alerts (`infra/cloudflare.mjs`).

## The relay

The relay is open to anybody who can open a socket, and each tag's
object runs on one thread shared by everyone on that tag.

- Every event's id is recomputed and its BIP-340 signature checked
  before anything else sees it. Key and signature shapes are checked
  before they are written into the wasm's memory. Nobody can sign as
  another key, and nobody can silence a table by saying its events
  first, since a duplicate id can only be the same signed event.
- Each socket is bounded: message size, REQ size (so a socket's
  subscriptions always fit the 16 KiB hibernation attachment), at most
  eight subscriptions, and a burst-then-rate limit on publishing that
  refuses floods before checking signatures. An event is serialised
  once for all listeners. Presence uses the tighter `objectLimits`,
  tables use `tableLimits`.
- Remembered ids are capped. Tag names are a single strict path
  segment.
- An object stores only the lobby kind tagged for its own tag, so nobody
  writes into another tag's store. Presence stores nothing.
- **Presence replay.** Every presence event is public and can be sent
  again once a relay forgets its id. A device accepts a `here` or `gone`
  only if it is at most four beats old, at most a minute in the future,
  and newer than the last one it took from that key
  (`presence_replay_test.dart`).

The local relays, the Node host and the juror listen on loopback and
are not deployed. The Node host's WebSocket framing closes the
connection on an oversized or fragmented control frame or an unmasked
frame (`service/do/ws.test.mjs`).

## The worker as a whole

- **Body limits.** 16 KB for every handler, 2 MiB for a game record,
  512 KB for Stripe's webhook.
- **Rate limits.** A Cloudflare rule limits `/api/*` (except the
  webhooks: Stripe's, the stores' and Sign in with Apple's) and the
  relay host to 30 requests per 10 seconds per address
  (`infra/cloudflare.mjs`). An unsigned or wrongly signed request
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
- **Game records** are accepted only from a key seated at the table, and
  are size-capped. They are verified by whoever views them, not by the
  worker.

## The site

Every path is served with `Content-Security-Policy: frame-ancestors
'none'`, `X-Frame-Options: DENY`, HSTS, `nosniff` and a strict referrer
policy (`site/public/_headers`), so no other page can frame the app and steer
its one-tap buttons. One page is excepted: `openhearts.game/carry`, which
hands a device's storage from where the app used to be to
`play.openhearts.game` ([doc 06](06-service.md#the-device-carried-over)).
The worker lets exactly that origin frame it. The page has no buttons, and
it answers only a message from its parent at exactly that origin,
addressed back to exactly that origin. The app checks the answer's origin
and source, and never writes over a key it already has. The app loads no third-party script. Cloudflare's
Web Analytics and email obfuscation are off, since both inject scripts.
Open: a fuller CSP (`script-src`) has not been set. The Flutter build
needs `wasm-unsafe-eval`, and the policy has to be tested against it.

## Secrets

The service key, Stripe keys, the TURN token, the HMAC key and the
bench's juror secret are Cloudflare secrets, set by hand and checked
only by name (`infra/apply.mjs`). The service key is minted with a
CSPRNG by `service/bin/service_key.dart` into `service.secret`, which is
ignored by version control. `deploy.sh` reads only environment
variables and pins `wrangler`. The Android release key's properties
file is never checked in. Every key in the repository is a published
test vector: BIP-340's test pair (used by the e2e rig and the relay's
self-check) and NIP-44's vectors. A scan of the full history with
`detect-secrets` found no credentials.
