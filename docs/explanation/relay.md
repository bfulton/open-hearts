# 08 — The relay

Live play meets on one relay, `wss://relay.openhearts.game/<tag>`, a
Cloudflare Durable Object per tag (`service/do/`). Deployed builds and
the jurors of last resort talk to no other relay: the list is a constant
of the build (`app/lib/net/relays.dart`), and the remote config may move
tables only to another host under `openhearts.game`
([doc 06](service.md)). The wire format is NIP-01-style signed
events, our own and free to change.

## One object per tag

The tag in the path names the object, so everyone on a tag reaches the
same one, wherever they are:

| Tag | Carries |
|---|---|
| a table's id | its events (kind 24242), WebRTC signalling (24243), the watch lane (24247), the players' reactions (24248) |
| `queue:…` | a pool's waiting room (24245) |
| a room code | the room's lobby events |
| `standings` | game results, which ratings are folded from |
| `online` | presence, summons, calls for a juror (24246) |

Every event's id and BIP-340 signature are checked before anything else
sees it. Sockets hibernate, carrying their subscriptions through
eviction, so an idle connection costs nothing. Per-socket limits on
message size, REQ size and publish rate are `objectLimits` for presence
(configurable, [doc 06](service.md)) and `tableLimits` elsewhere
(`service/do/relay.mjs`).

## What is kept, and for how long

Ephemeral kinds (20000–29999), which are table events, signalling,
pools, presence and the players' reactions, are forwarded and
forgotten. The table protocol's own repeats recover a dropped message.

A reaction ([doc 04](live-play.md#reactions)) is a code and the
moment it was said at, never words, and the object holds it to that: it
rides only a table's own tag, tagged with that table and nothing else,
and an object refuses one anywhere else, longer than 128 characters, or
in any other shape (`reactionRefusal`). The codes themselves are not
listed there — a screen shows only those it knows — so a new one needs
no new relay.

One kind is stored: **4244, the lobby**. That covers a room announced, a
pool's seating, a table started, a player's picture, and a game's
result. A tag's object stores 4244 only when the event's `t` tag is that
object's own tag, so nobody can write into one tag's store through
another. The `online` object stores nothing and refuses every kind that
is not ephemeral. Stored events live in the object's own storage
(`service/do/tag_store.mjs`), so they survive eviction, and a new
subscriber is sent them.

Rooms, seatings, starts and pictures are kept for **a day**, then
deleted by an hourly alarm. Results are kept **indefinitely**, since
every rating is folded from all of them; the newest 20,000 are held in
memory. A device's results can be deleted by hand on request.

## Watching a table

Anyone with a table's address can watch it without sitting at it
(`packages/table/lib/src/watch.dart`). A watcher announces itself on the
table's tag every twenty seconds under a throwaway key. The seated player
with the lowest key answers after every move with a view anyone at the
table could see: names, scores, this hand's cards played, whose turn
it is and the keys the seats are held by, until a minute after the last
watcher spoke. The watcher reads the players' reactions beside it, and
shows those of the seats' keys. A view never
includes a hand, a pass or the deal, is never stored, and proves
nothing: once the game is over, the review page verifies the full record.
