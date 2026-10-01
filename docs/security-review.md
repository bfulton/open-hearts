# Security review — the service, before launch

What runs on our side, read for what a stranger can make it do: the
Pages worker (`service/functions/worker.mjs`), the relay object
(`service/do/`), the local relay and the juror (`service/bin`,
`service/lib`), `deploy.sh`, the headers the site is served with, and
the app's half of each call (`app/lib/net/licence.dart`,
`household.dart`, `buying.dart`, `turn.dart`). Reviewed on 1 October
2026 at `f561398`.

Every finding below was shown, not supposed — by a test that failed
before the fix (named with each one), a script against the code as it
stood, or the live dev deployment's own answer — except where it says
it was shown by reading alone. What could not be shown is marked
**unconfirmed**. **Fixed** means fixed on this branch
with the test that proves it; **needs the owner** means it is a setting,
a plan, a product choice or a dashboard, not code.

Line numbers are the file as it was at `f561398`, which is where the
fault was.

## Findings, worst first

### 1. Critical — a public key was all it took to act for its owner

**Fixed.** `worker.mjs:548–602` (ticket, claim, devices) and `:866–880`
(licence) took the caller's key from the body (`keyOf`, `:839`) and
acted for it. A device's key is public: it signs every event the device
says at a table and the relays hand those to anybody, presence beats
included. So anybody who had seen a subscriber online could:

- list the subscriber's household — every key on it, which ties a
  person's devices together (`devices`);
- drop any device off it, the owner's own included — the owner's paid
  subscription then has no device and no way back in, since there is
  no account (`devices` with `drop`);
- make a code against it (`ticket`) and spend it on their own key
  (`claim`), taking a seat in a stranger's household for free;
- learn whether any key pays, and to when (`licence`).

Run against `f561398` with nothing but the victim's public key: the
household listed, a code made and claimed by the attacker's key, the
victim dropped, the victim's entitlement `null`, the attacker licensed.
Licensing is not configured on the dev deployment, so nobody's was
reachable there; it would have been on the first day it was.

The fix: every handler but Stripe's takes `{key, at, sig}`, a BIP-340
signature by the key over `oh-request/1`, the handler, the key, the
second, and what the request asks for beyond itself (the code spent,
the device dropped) — `askedBy` and `signedFor` in `worker.mjs`,
`signedAsk` in `app/lib/net/licence.dart`. The handler is in the
statement so a licence request cannot be spent as a code request; a
request more than five minutes from the service's clock is refused
with a reason the screen can show. The statement's hash is pinned on
both sides (`worker.test.mjs`, `licence_test.dart`), so the two
languages cannot drift apart unnoticed. Tests: *a key alone is nobody*,
*what a request signs is pinned*.

Nothing is stored to stop a replay inside the five minutes. A replay
needs the request itself, which travels only over TLS to our own
origin; the one worth replaying is `ticket`, whose code goes back to
whoever sent it. Accepted, and written down here.

### 2. High (latent) — anybody's account could be bound to a stranger's key, and carry their subscription off

**Fixed.** `worker.mjs:778–801`, `:661–715`. A sign-in token has to
carry a nonce that is the hash of the device's key (`:713`), and that
was taken as the key's consent. But the nonce is chosen by whoever asks
the provider for the token. A stranger signs into his own Google
account through our client id with the nonce set to the hash of a
subscriber's key, and posts `attest` with that key: his account is now
bound to her device. Then `supersede` with his own key moves the login
there — and `supersede` carries the old device's entitlement to the new
one (`:764–772`). He holds her subscription, and if her household was
full she is dropped from it.

Shown end to end against `f561398` with the test suite's own provider:
attest 200, supersede 200, the attacker's key entitled on the victim's
subscription. Not reachable today only because `OH_GOOGLE_AUDIENCE` and
`OH_APPLE_AUDIENCE` are not set; it would have been the day they were.
The same signed request as (1) closes it: the key has to sign the
attest. Test: *a sign-in binds only a key that asked to be bound*.

### 3. High — TURN credentials for anybody, billed to the project

**Fixed; needs the owner for the rest.** `worker.mjs:882–889` minted
Cloudflare TURN credentials for any 64 hex characters (the doc said
so: "the credentials' short life is the only limit on their use"). A
credential is a relay its holder can push any traffic through for four
hours, and Cloudflare bills TURN egress by the gigabyte past the free
terabyte. On the live dev deployment, `POST /api/turn` with a random
key answered 200 with working credentials (minted once for this review,
not used, expired after four hours).

Now the request must be signed and the key must hold a subscription:
TURN is what the subscription pays for, and only live play — which is
gated on the licence — asks for it (`home_page.dart:364`). A subscriber
can still mint as many as it likes. Test: *TURN is for a device that
holds a licence*.

### 4. Medium — the presence object took anything, of any size, as fast as it came

**Fixed.** `service/do/relay.mjs:234–314`, `service/do/worker.mjs:72–81`.
The object is open to anybody who can open a socket. Cloudflare hands it
messages of up to 32 MiB; an event that matches presence goes to every
device on the tag, and was serialised once per listener, on the one
thread every device on the tag shares. Nothing limited a socket's rate.
And a socket's subscriptions ride through hibernation in its
attachment, which Cloudflare caps at 16 KiB, while a REQ had no size
limit.

Measured against the relay as the object built it: one 4 MiB presence
event was 800 MiB out to 200 listeners and 3.3 s of the object's
thread; 300 events sent at once by one socket were all verified and
fanned out; one REQ made an attachment of 163 KB, which
`serializeAttachment` would refuse, so the socket would silently lose
its subscriptions at the next hibernation.

The object is now built by `objectRelay` in `relay.mjs`, where the tests
build the same thing: no message over 64 K characters is parsed (a
summons, the largest thing presence says, is a few kilobytes); a REQ is
at most 1 KiB, so eight sit well inside the attachment; each socket has
a burst of 30 events and two a second after, refused before the
signature is checked; and an event is serialised once for everyone. The
node host under the suites carries whole tables and keeps no limits.
Against the same attack: nothing sent on, 30 of 300 taken, an empty
attachment. Tests: the five under *the object, open to anybody*.

### 5. Medium — a link could take a paid-up device off its own subscription

**Fixed on the service; the screen is the owner's call.**
`worker.mjs:515–518`, `home_page.dart:181`. A claim link is spent the
moment the app opens it, with nothing asked. `claimWith` moved a device
off whatever subscription it was on. So a stranger with a subscription
of his own makes a code, sends the link to a subscriber, her app spends
it and leaves the subscription she paid for for his, and he drops her
from his. She has no device on her own subscription and no account to
get back in with.

The service now refuses a code for a device that is on another
subscription still paid up ("drop it there first"), without spending
the code. Moving on purpose is dropping yourself first, which the
household page already offers. A device whose subscription has ended,
or one on local mode's open house, moves freely, so the browser suite's
flow is unchanged. The doc said the old behaviour was intended, so this
is a change of rule, written into doc 06. A confirmation on the screen
before a link is spent would be better still; that is UI, left alone
here. Tests: *a code does not take a device off a subscription somebody
paid for*, *a device leaves a subscription by dropping itself*.

### 6. Medium-low — a checkout for somebody else's key

**Fixed.** `worker.mjs:803–815`, `:398–412`. Anybody could open a
checkout naming any key. Paid, `record` rewrites that key's entitlement
to the new subscription, so for the price of a year a stranger moves a subscriber's
device onto a subscription he controls, then ends it (cancelling in
Stripe's portal, or asking for a refund) and the device is written down
with it — while her own subscription goes on being charged with no
device on it. Checkout is now a signed request like the rest. Test: *a
checkout is opened only by the device it is for*.

### 7. Medium-low — Stripe's events out of order brought an ended subscription back

**Fixed.** `worker.mjs:414–444`. Stripe does not promise order, and
retries a failed delivery for up to three days. An update from before a
deletion that arrives after it rewrote `renews_at` a year out; the
devices, written down at the deletion, caught up from it on their next
ask. A refund became a year of play. A failed delivery is not only bad
luck: on the free plan a subscriber hammering `ticket` could exhaust the
day's KV writes and make the webhook fail on purpose (see 10). The row
now keeps the time of the event that wrote it and ignores older ones,
and nothing is news after a deletion or a final status (`canceled`,
`incomplete_expired`; not `unpaid`, which is paid back into life).
Test: *Stripe's events in the wrong order*.

### 8. Low — every code ever made was a row for ever

**Fixed.** `worker.mjs:495`, `:514`, `:137–139`. Tickets were written
without an expiry and never deleted, so KV grew by a row per code
forever — and before (1) was fixed, anybody could write them. A code's
row is now written with KV's `expirationTtl` of an hour, spent or not.
Test: *a code's row is let go by the store*.

### 9. Low — two devices spending one code at once both get in

**Confirmed; needs the owner.** `worker.mjs:504–526`. A code is read,
checked unspent, and written spent in separate calls, and KV has no
compare-and-set (and is eventually consistent between locations for up
to a minute). Two claims of one code at once both succeed, so a
household of four becomes six. Shown with two claims in flight on one
store (`{ todo }` test *two devices spending one code at once*, which
fails today and is reported, not counted). Two different codes spent
at once into a household of four go the same way by the same reading
of the count; that case is not tested. The attacker is the subscriber, sharing past five; the cost
is revenue, not anyone's account. Closing it needs the household's
rows behind something transactional — a Durable Object per
subscription, or D1.

### 10. Low — no rate limits anywhere, and the free plan's KV quotas

**Needs the owner.** Nothing in the worker limits requests per client.
Since (1), an unsigned or wrongly signed request costs a JSON parse and
one signature check and touches no storage; a validly signed one from a
key nobody pays for costs one or two KV reads. Writes need a
subscription: a subscriber can still make a code per request (a write
and a list each). On the Workers free plan KV allows 1,000 writes and
1,000 lists a day; one subscriber looping on `ticket` stops every
write — Stripe's included — until midnight UTC. See the owner's list
below.

### 11. Low — the site could be framed

**Fixed; check after deploying.** `site/_headers:6–8` set `nosniff` and
a referrer policy only; the live dev site's `/play/` answered without
`X-Frame-Options` or `frame-ancestors`. Subscribe and Drop are one tap
each (`household_test.dart` drops with a single tap), and under
another site's frame those taps are that site's to steer. Every path now
has `frame-ancestors 'none'`, `X-Frame-Options: DENY` and HSTS. The
dev site showed that `_headers` does reach assets served through the
worker's `env.ASSETS`. Test: *nobody else's page frames the app*
(`web_index_test.dart`).

### 12. Low — the service's signing secret, one `git add -A` from the repo

**Fixed.** `service/bin/service_key.dart:23–27` writes the secret to
`service.secret` in the working directory, and nothing ignored it
(`git check-ignore service/service.secret` found no rule). It is in
`.gitignore` now. The file is still written with the process's umask.

### 13. Low — a malformed sign-in token threw instead of being refused

**Fixed.** `worker.mjs:694` decoded the token's signature outside the
`try` that caught everything else, so a third segment that is not
base64 threw out of the handler: a 500 from Cloudflare, not a 401.
Test: *a token whose signature is not base64*.

### 14. Low — old presence events can be said again

**Not fixed: the clients' side.** `packages/table/lib/src/presence_relay.dart:280–299`
takes a `here` or a `gone` whatever its `created_at`. Every presence
event is public, and any relay will take it again once it has
forgotten the id (ours forgets on eviction or past 40,000 ids). Said
again, an old `here` makes a device that left look online for a beat or
two — enough to be seated and then booted — and an old `gone` takes a
present one out until its next beat. Shown by reading only: the
protocol is not the service, and the public relays would carry the
replay regardless of ours. Ignoring presence older than a few beats is
the fix, in `packages/table`.

## Unconfirmed, and things only the owner can see

- **The webhook's MAC is compared with `===`** (`worker.mjs:389`), not
  in constant time. Not exploitable that anyone has shown over a network
  against a 256-bit HMAC; `crypto.subtle.verify('HMAC', …)` is the
  three-line hardening. Unconfirmed.
- **A checkout is taken as paid when `status` is `complete`** even if
  `payment_status` is `unpaid` (`worker.mjs:399`), which is what Stripe
  sends for delayed payment methods. Whether that matters depends on
  which methods the Stripe account allows. Card and wallets only: no
  issue. Otherwise, take `paid` and `no_payment_required` only and
  handle `checkout.session.async_payment_succeeded`. Unconfirmed.
- **Any checkout on the Stripe account binds a key.** `record` reads the
  key from `metadata.key` or `client_reference_id` without checking the
  price. Payment Links accept `client_reference_id` in their URL, so a
  cheaper subscription product on the same account, sold through a
  link, would buy live play. Keep the account (or at least the webhook
  endpoint) to this one price. Unconfirmed.
- **`OH_OPEN_HOUSE` on the Pages project** licenses every device that
  asks and takes `local:<subject>` as a sign-in for that subject — in
  production that is everyone licensed, and any account whose provider
  subject is known signed into by whoever names it. It is
  never set by the code; make sure it is set in neither the Production
  nor the Preview environment.
- **CORS** echoes any `localhost`/`127.0.0.1` origin (`worker.mjs:38`)
  in production. Nothing rides on ambient credentials, so this grants
  nothing; noted only.
- **Request bodies** are parsed whole (`bodyOf`), bounded only by
  Cloudflare's own request limit. CPU-bound and cheap; noted only.
- **The local relay, its node host and the juror** listen on loopback
  and are not deployed. Noted while reading: `ws.mjs:128` answers a ping
  of more than 125 bytes with a broken frame, and a connection may buffer
  up to 16 MiB before a frame completes. Neither matters on a test
  machine.

## What the owner has to do

1. **Rate limits** (Cloudflare → Security → WAF → Rate limiting rules):
   `/api/*` per IP, generous (say 60 a minute); tighter on `/api/ticket`,
   `/api/claim`, `/api/checkout` and `/api/turn` (say 10 a minute); and
   one on WebSocket upgrades to the relay host, which also bounds how
   many tag objects a client can conjure.
2. **TURN**: a usage alert or budget on Cloudflare Realtime, and a look
   at past usage, since until this branch is deployed anybody can mint
   credentials. The TURN API token itself was never exposed; no rotation
   needed for that.
3. **Plan and quotas**: on the Workers free plan, KV's 1,000 writes a
   day is something one subscriber can spend (10). The paid plan or the
   rate limits above, before launch.
4. **Environment**: `OH_OPEN_HOUSE` unset everywhere; `OH_SERVICE_SECRET`,
   `OH_STRIPE_*`, `OH_TURN_*`, `OH_ID_HMAC` set as encrypted secrets,
   not plain variables.
5. **Stripe**: card and wallets only, or the async-payment handling
   above; this price alone on the webhook's account; the webhook sending
   only `checkout.session.completed` and `customer.subscription.*`.
6. **After deploying**: `curl -sI https://<site>/play/` shows
   `content-security-policy: frame-ancestors 'none'`,
   `x-frame-options: DENY` and `strict-transport-security`; and a fuller
   CSP (`script-src`) once it has been tried against the Flutter build,
   which needs `wasm-unsafe-eval`.
7. **The claim link** spends itself without asking (`home_page.dart:181`).
   The service now protects a paid-up device; a "join this household?"
   confirmation on the screen is the product's call.
8. **Codes spent twice at once** (9): a Durable Object or D1 for the
   household, if sharing past five turns out to matter.
9. **Deploy app and worker together**, which `deploy.sh` already does:
   a build from before this branch sends unsigned requests and is
   refused (it keeps its licence until its date, and the update pill
   asks for a reload).

## What was run

On the branch as committed: `node --test service/functions` 54 pass, 0
fail, 1 todo (finding 9); `node --test service/do` 21 pass;
`cd service && dart test` 32 pass, and `OH_RELAY=js dart test` 32 pass
over the changed relay core; `cd app && flutter test` 187 pass. The
browser flows (`node e2e/flows.mjs`, app built by `e2e/build.sh`): the
two that drive these handlers — the live area, and a second device
brought in by a code, signed through the app's wasm against the
worker — pass; one fails, and failed before this branch: the profile
says "The relays did not answer…" where `e2e/flows.mjs:208` looks for
"No relay answered" (neither file is touched here). The four-browser
suites were not run.

## Read and found sound

- **The webhook** reads nothing until the `Stripe-Signature` checks out
  over the raw body; a timestamp more than five minutes out is refused;
  every `v1` is tried, so a rotating secret works; no secret configured
  refuses everything.
- **Where a buyer comes back to** is this site's origin and nowhere
  else (`sameSite`): an absolute URL elsewhere, `javascript:` and
  `data:` (opaque origins) are all refused. The app, for its part, only
  leaves for `checkout.stripe.com` (`buying.dart:86–98`). No open
  redirect.
- **No SSRF.** Every fetch the worker makes is to a fixed host:
  Cloudflare's TURN API, Stripe's API, Apple's and Google's key sets,
  and its own assets. Nothing a caller sends becomes a URL.
- **KV keys** are built only from validated parts — 64-hex keys, hex
  codes — and from subscription ids that arrive in Stripe-signed
  events. Nothing a caller sends can add a `|` or reach another prefix.
- **Codes** are 128 random bits from `crypto.getRandomValues`, expire in
  ten minutes on the service's clock, are one-use, and carry nothing
  about the subscription. Guessing one is not a thing.
- **The licence** is domain-separated (`oh-licence/1`), never later than
  what was paid for, and checked against the public key before it is
  handed out; the app takes it only from the real BIP-340 path (never
  the simulator's fake signatures), for its own key, and in date
  (`licence.dart:91–107`). Dropping a device takes away its row, not
  just its date.
- **Sign-in tokens**: algorithms allow-listed (RS256, ES256 — no `none`,
  no HMAC confusion), keys from the provider's own fixed JWKS URL,
  issuer, audience, expiry, subject and nonce all checked; the subject
  stored only as an HMAC under `OH_ID_HMAC`.
- **Errors** say what went wrong in words and upstream status codes, no
  stack traces and no upstream bodies.
- **The relay** recomputes every event's id and checks its BIP-340
  signature before anything else sees it, and checks the shape of key
  and signature before writing them into the wasm's memory
  (`relay.mjs:79–87`). Nobody can sign as another key, and nobody can
  silence a table by saying its events first: an id is the hash of the
  signed event, so the only thing that can be a duplicate is the same
  event, already forwarded. Subscriptions per socket and remembered ids
  are bounded; the object stores nothing, so it has no storage to grow;
  tag names are one strict segment.
- **Secrets** live in the project's settings; the repository's keys are
  BIP-340's published test vectors; the service key is minted with a
  CSPRNG; `deploy.sh` reads only environment variables and pins
  `wrangler`; the app's page loads no third-party script.

## Open-source readiness: the whole history

Every line ever added, on every branch (`git log -p --all`, 94,744
added lines), was scanned with `detect-secrets` (all default plugins):
525 hits, every one read. None is a credential. They are the published
NIP-44 vectors (`packages/table/test/nip44.vectors.json`), the published
BIP-340 test pair the suites and `service/do/sign.mjs`'s self-check use
on purpose, digests and lockfile hashes, Xcode identifiers, and test
placeholders (`sk_test`, `whsec_other`, `wss://user:pw@ok.example`). No
key, keystore, `.env`, certificate or `key.properties` file has ever
been committed, and the files that would hold one are ignored
(`app/android/.gitignore`, and the service secret since this review).
Nothing in the published code is anti-cheat that depends on being
secret: the deal's fairness is the protocol (doc 03), and the protocol
is meant to be read.
