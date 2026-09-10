# 06 — The service

What runs on our side, which is deliberately little. The game is peer to
peer ([doc 02](02-multiplayer.md)), the deal is verifiable
([doc 03](03-fair-deal.md)), presence rides relays and bot seats are
played by the players and the jury ([doc 04](04-live-play.md)). What is
left is identity, entitlement, and a juror when the room is empty.

## Handlers

| | In | Out |
|---|---|---|
| **attest** | Apple/Google sign-in token, device public key | signed attestation, or refusal because the account is already bound |
| **supersede** | sign-in token, old and new public keys | signed supersession link |
| **entitle** | purchase webhook | entitlement recorded; signed licence available to the key |
| **turn-creds** | attested key | short-lived TURN credentials |
| **last-resort** | table id, hand | a juror comes online for that hand |

Each is a point lookup and a signature. None is in a game's latency path
and none is needed by a table already playing.

## Storage

Everything the service keeps fits one key-value table. Every access is
a lookup by key — no scans, no ranges, no joins.

```
PK                         SK             attributes
LOGIN#apple#<hmac(sub)>    IDENTITY       key, created_at
LOGIN#google#<hmac(sub)>   IDENTITY       key, created_at
KEY#<key>                  META           provider, attested_at, attestation
KEY#<key>                  SUPERSEDES     predecessor, link, at
KEY#<key>                  ENTITLEMENT    entitled, source, txn_ref, at, revoked_at
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

Not stored: cards, plays, game state, ratings, emails, device sessions.
Ratings are computed from public records by anyone. TURN credentials are
minted from a secret, not kept. The last-resort juror keeps nothing.

Counters are the instrumentation the design asks for — how often tables
drain to one human, how often a jury cannot be drawn — as atomic
increments, no identities attached.

Secrets — the service signing key, the TURN secret, the purchase webhook
secret, the HMAC key — live in the platform's secret store, never in
the table.

The design is written against DynamoDB's single-table shape and ports to
any key-value store almost literally; the platform choice is deferred to
deployment. A bucket is reserved for archiving public game records,
since relays do not promise retention; whether the service subscribes
to relays or clients post copies is undecided, and nothing depends on
it yet.

## Purchase plumbing

Live play is a one-time purchase. On the stores it is an in-app
purchase; on the web it goes through a merchant of record, which
handles tax in the buyer's jurisdiction. Both land at **entitle** through
one webhook, keyed by the player's public key, and the entitlement
follows the identity across platforms. TURN is Cloudflare's.

## Local mode

The service runs entirely locally for end-to-end tests, with the same
code and different adapters:

| | Production | Local |
|---|---|---|
| Storage | DynamoDB | in-memory, same shape |
| Sign-in | Apple/Google public keys | a test token naming a `sub` |
| Entitlement | purchase webhook | a test endpoint that marks a key entitled |
| TURN | Cloudflare | none; localhost connects directly |
| Signalling | public relays | a minimal NIP-01 relay in the repo |
| Last-resort juror | woken on demand | always available |

One process, one flag.

## Language and layout

The juror runs the bot policy under MPC, and the bot is Dart. So the
juror is Dart, and rather than carry a second language for two hundred
lines of handlers, the whole service is Dart. Locally that is one
`dart run`; in production it is a container, or Dart on a serverless
runtime — a packaging decision, deferred.

```
packages/engine/     the rules and the bot — shared by app and service
app/                 Flutter
service/             handlers, juror, storage adapters, local relay
e2e/                 Playwright, driving real browsers against the local service
site/
docs/
```

Extracting the engine into its own package comes before the service
exists, so nothing is ever imported across the app/service line.

## End-to-end tests

Playwright drives several headless browsers as players against the local
service and relay, with real WebRTC between them. That is what makes the
departure cases testable as they will actually happen: a browser closed
mid-hand, a second booting a stalled one, a table draining to one human
and the local juror stepping into the computation. It is also the only
way to catch partition and split-brain bugs, which do not unit-test.
