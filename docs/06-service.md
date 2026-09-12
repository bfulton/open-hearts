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
| Signalling, waiting rooms, results | public relays | a minimal NIP-01 relay in the repo |
| Last-resort juror | woken on demand | always available |

One process, one flag.

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
the same. What arrives is stamped *from* the envelope's signer — the
peer that sent it, which for a relayed message is not the author — and
that is the distinction "heard from" rests on. The relay says nothing
when a peer goes, so the transport never reports a disconnect; the
heartbeats carry that. Kind 24243 on the same wire is WebRTC
signalling — an offer, an answer, an ICE candidate — addressed with a
`p` tag to one recipient, who is the only one subscribed to it. Plain
text on a local relay; encrypted to the recipient's key (NIP-44) is
the step before a public relay carries it.

`service/test/table_over_relay_test.dart` seats two people and two bots
on the local relay with real keys, real sockets and the wall clock, and
they play a hand: 28 decisions, every one signed twice and verified by
the other side, in about four seconds. That is the cost the app pays,
measured — and it is why the web app will not sign in Dart: the same
signature that takes 11 ms in the VM takes 100 ms compiled to
JavaScript, and 0.6 ms as wasm
([measurements/sign](../measurements/README.md)).

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
players against the local relay and the built app, with real WebRTC
between them, through the app's own screens — it finds the buttons,
the cards and the state pills in the accessibility tree the app grows
on request. Host a room, join it by code, a hand over WebRTC in under
half a minute; then the cells only a browser can show: one closed
mid-hand and replaced by a bot within ten seconds, one stalled on its
turn and booted by the others at fifteen, one that leaves, and the
last person finishing the hand with three bots. That is what proves
the transport. The juror stepping in for a table drained to one human
joins the suite with the jury. It runs in CI on every commit.

The axes:

| | |
|---|---|
| **Live humans at the start** | 1, 2, 3, 4 — bots in the rest. A table reaches 1 by departures too, so this axis is not independent of the others. |
| **Who goes** | one player; two players in the same window; two in sequence; a juror; the foreman; two jurors; the whole jury |
| **How** | a signed Leave; a silent drop, found by timeout; a boot at fifteen seconds on turn; a two-and-two partition, which is not a departure but looks like one from inside |
| **When** | on the departed seat's own turn; off it; mid-trick; the last trick of a hand; during the pass; during the deal; at a hand boundary |

The juror rows run in `packages/table/test/jury_test.dart`, with the
jury of [doc 04](04-live-play.md). The sealed rows — the same simulator
with the verifiable deal of [doc 03](03-fair-deal.md) run for real, its
proofs made and checked on the virtual clock — run in
`packages/table/test/sealed_test.dart`: whole games at one, two and
four people, a leaver mid-hand and during the deal, a table of two
surviving a crash by the jury's verdict and a juror's escrow piece, and
a lone player leaving during the pass while their client looks on. The
chaos walk runs sealed on request (`CHAOS_SEALED=5`), a minute or two a
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
`CHAOS_SEEDS=1000 dart test test/chaos_test.dart` walks a thousand.

What every cell asserts:

- **The game reaches its end** with a bot in every departed seat — or,
  at two humans with an inferred departure and no jury to be drawn, the
  table **pauses and says so**, and stays consistent while paused.
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
