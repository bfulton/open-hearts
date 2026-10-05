# 08 — Our own relay, and only ours

> **Status: live 3 October 2026.** Ratings start fresh; the
> relay-endpoint setting stays, and only ever names our own relays.
> Proved before deploying by the table and service suites (the latter
> also through the deployed object's rules, `OH_RELAY=object`), the
> browser flows, and `bench_check` against a local object; after, by
> two hands on openhearts.game's relay with the bench holding the bots.

## Why

Live play runs on three public Nostr relays (`relay.damus.io`,
`relay.primal.net`, `nos.lol`); only presence runs on ours
(`relay.openhearts.game`). The choice was right for a game that had no
server and no bill ([doc 02](02-multiplayer.md)): public relays did
the introductions for free. That game no longer exists. We run a
service, a relay and a container, on a paid plan, and the relays carry
far more than introductions: everything a juror of last resort does,
every bot's card included, goes over them, because the jurors have no
direct connections.

And volunteers owe us nothing. On 2 October a live table on
openhearts.game stopped on a bot's turn while `relay.damus.io` was
refusing the jurors' events: "banned: too many rate-limit violations".
Doc 04 already records a public relay that began demanding proof of
work in the middle of a game. A table we sell should not stand on
infrastructure that can turn on it.

## What stays, and what is free to change

**Signed messages.** Every move is signed by its author and the record
can be checked by anyone; the verifier, the simulator and hundreds of
tests rest on that, and none of it needs the public network. The wire
format they use today happens to be Nostr's, which is why the game could
use public relays at all. From here it is our format, kept because it
works, and **free to change** where a change helps the game — batching a
table's messages, the relay catching a returning player up, a table's
seats being the only ones who may write to it — with no obligation to
stay compatible with Nostr clients or relays. Nothing new is named for
Nostr: the relay is "the relay", at `relay.openhearts.game`, and the
unbuilt `nostr.openhearts.game` leaves the build.

## What the relays carry today

| Kind | What | Stored? | Tagged by |
|---|---|---|---|
| 24242 | a table's events: deal, pass, play, witness, juror messages | no — forwarded and forgotten; the table repeats what was lost | table id |
| 24243 | WebRTC signalling | no | table id |
| 24245 | waiting to be matched | no | pool |
| 24246 | presence, summons, calls for a juror | no | `online` |
| 4244 | the lobby: a room announced, a pool's seating, a table started, a player's picture — and **game results**, which the ratings are folded from | **yes** | room code, pool, `results` |

Everything but the lobby is already the kind our relay carries: one
Cloudflare object per tag, hibernating, nothing written down
(`service/do/`). Presence has run on it since September.

## The design

**1. Tables move to the object we already run.** A table's events and
its signalling go to `wss://relay.openhearts.game/<table id>`, the
waiting room to `/<pool>`, exactly as presence goes to `/online`. One
object per table: everyone at a table, wherever they are, meets in one
place, and the object is gone when the table is. The client already
puts a tag into a relay's address for presence (`relaysForTag`); the
table's transport does the same.

**2. The lobby kind is stored, in the same object, for as long as it
is useful.** The tag's object keeps kind 4244 in its own SQLite store
and answers a new subscriber with what it holds, as a relay does:

- a room, a pool's seating, a table's start, a player's picture: kept
  a day, then deleted by the object's own alarm;
- game results (the `results` tag): kept, since the ratings are folded
  from every result there has been. A result is about a kilobyte; four
  a game.

**Watching, on the same object.** A table's tag also carries its
watch lane, kind 24247, ephemeral like the rest (packages/table,
`watch.dart`): whoever opens a table's address says every twenty
seconds that it is watching, under a key made for the watching, and
the seated player with the lowest key of those still here answers with
the table as anyone at it sees it — names, scores, this hand's cards
played, whose turn — after every move, for a minute after the last
watcher spoke. Nothing hidden, nothing stored; a game nobody watches
says nothing on it. Once the game is over the page fetches the record
and checks it (`review_page.dart`).

**3. The app's list is ours alone.** The public relays and the unbuilt
`nostr.openhearts.game` leave the build. The remote config can still
name relays (`relays`), which is the way back if ours ever needs help:
a config change, not a release.

**4. The jurors of last resort use the same list** (their image's
`OH_RELAYS`), so nothing of a quiet-night table touches a public relay.

## What changes for players

- **Privacy gets simpler.** Today the privacy page has to say that live
  play, pictures and results go to independent operators who may keep
  them for good, and that we cannot delete them. After this, they go to
  us, under our own retention: rooms a day, results for the ratings.
  The hands themselves are encrypted by the deal either way
  ([doc 03](03-fair-deal.md)); a relay, ours included, never sees one.
- **One provider.** If Cloudflare is down, live play is down — as it
  already is, since the licence and TURN are there too. The monitors
  (`observability/`) watch the relay.
- **Ratings start again.** The results on the public relays are from
  our own test games. They are left where they are, and the ledger
  starts empty on ours. (Copying them over is possible; it seems not
  worth it.)

## Cost

Measured: a hand with two people and two jurors' bots, everything over
the relay, is about 450 messages in (0.5 MB). Cloudflare bills incoming
messages at twenty to a request: about 180 requests a game. The Workers
Paid plan includes a million a month, so about 5,500 games a month cost
nothing beyond the plan, and after that well under a tenth of a cent
each. Tables store nothing. What is stored is the lobby: a few rows a
game, deleted after a day, and results, about 4 KB a game kept — a
million games is 4 GB, inside the 5 GB included. With four people
online most play goes between their devices directly, so real games
cost less than this.

## How it is built, in order

1. **The relay stores kind 4244** in the tag's object, with the two
   retentions and an alarm that sweeps. Tests in `service/do/` for both,
   and the existing suite run against it (`OH_RELAY=js`).
2. **The client addresses tables, signalling, the waiting room, rooms
   and results by tag** on our relay, and the build's list becomes ours.
   The local rig and the simulator follow (the Dart relay ignores the
   path, so a local build keeps working).
3. **The jurors' image** takes the same list.
4. **Proof before deploying:** the table suite, the chaos walk over the
   JavaScript relay, the browser flows, and `bench_check` with the
   jurors' image against our relay object rather than a public one.
5. **Deploy**, the relay first, then the app; then a live table with
   bots on openhearts.game, watched in the jurors' logs and New Relic.
6. **Docs and the privacy page** rewritten for one set of relays.

About two days of work, most of it in step 2 and its tests.

## Decided

1. **Ratings start fresh** on our relay; the test games' results on the
   public relays are left where they are.
2. **The remote config's `relays` stays**, as a way to point the app at
   another relay of ours without a release. It never names a public
   relay.
