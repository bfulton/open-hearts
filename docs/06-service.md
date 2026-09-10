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
players against the local service and relay, with real WebRTC between
them, through a handful of representative cells. That is what proves the
transport, and the only way to see a departure as it actually happens:
a browser closed mid-hand, a second booting a stalled one, a table
draining to one human and the local juror stepping in.

The axes:

| | |
|---|---|
| **Live humans at the start** | 1, 2, 3, 4 — bots in the rest. A table reaches 1 by departures too, so this axis is not independent of the others. |
| **Who goes** | one player; two players in the same window; two in sequence; a juror; the foreman; two jurors; the whole jury |
| **How** | a signed Leave; a silent drop, found by timeout; a boot at fifteen seconds on turn; a two-and-two partition, which is not a departure but looks like one from inside |
| **When** | on the departed seat's own turn; off it; mid-trick; the last trick of a hand; during the pass; during the deal; at a hand boundary |

The juror rows arrive with the jury ([doc 04](04-live-play.md)); they
are in the matrix from the start and skipped until then.

What every cell asserts:

- **The game reaches its end** with a bot in every departed seat — or,
  at two humans with an inferred departure and no jury seated yet, the
  table **pauses and says so**, and stays consistent while paused.
- **Every surviving client holds the same record**, event for event,
  once the network settles.
- **The record verifies**: every human play signed by its seat's key and
  legal under the engine, every bot play recomputable from the deal.
- **Ratings follow doc 04's two rules**: a bot in the winning seat moves
  nobody; a live winner moves everyone, leavers included.
- **A play at 14.9 seconds beats a boot at 15.0**, and a peer holding
  the play rebroadcasts it instead of countersigning the boot.
- **Nobody is removed without a strict majority** of the last agreed
  participant set, so a partition never forks: neither side can act,
  and when it heals there is one record.
- **Nothing hangs**: the virtual clock advances until the game is over
  or the pause is explained on screen.
