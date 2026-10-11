# The relay

Live play meets on one relay, Open Hearts' own, at
`relay.openhearts.game`: one Cloudflare Durable Object per tag
(`service/do/`). This page explains why it is built that way and what
it keeps. Its tags, event kinds, limits and retention are in the
[relay reference](../reference/relay.md).

## One relay, ours

Deployed builds and the backup jurors talk to no other relay. The list
is a constant of the build (`app/lib/net/relays.dart`), and the remote
config may move tables only to another host under `openhearts.game`
([remote config](service.md#remote-config)). The wire format is
NIP-01-style signed events, our own and free to change.

## One object per tag

The tag in the path names the object, so everyone on a tag reaches the
same object wherever they are, and nothing has to be passed between
machines. Every event's id and BIP-340 signature are checked before
anything else sees it. Sockets hibernate, carrying their subscriptions
through eviction, so an idle connection costs nothing.

Each socket is held to limits on message size, request size and
publishing rate. A table's limits are looser than presence's: a deal
sends its steps in bursts of tens of kilobytes, while presence is a
small message every few seconds from every device online.

## What is kept, and why

Most of what the relay carries is forwarded and forgotten: a table's
events, signalling, pools, presence and the players' reactions. The
table protocol repeats what is unsettled, so a dropped message is
recovered without the relay keeping it.

One kind is stored, the lobby: a room announced, a pool's seating, a
table started, a player's picture, a game's result. A tag's object
stores a lobby event only when the event is tagged with that object's
own tag, so nobody can write into one tag's store through another.
Stored events live in the object's own storage, so they survive
eviction, and a new subscriber is sent them. That is how a device
arriving at a room code finds the room that was announced before it got
there.

Rooms, seatings, starts and pictures are kept only as long as a room
can be in use (`KEPT_MS` in `service/do/tag_store.mjs`). Results are
kept for good, under the tag every result carries (`GameResult.tag` in
`packages/table/lib/src/results.dart`), because every rating is folded
from all of them ([ratings](live-play.md#ratings)). An account's results
can be deleted on request
([Delete an account's data](../how-to/delete-an-accounts-data.md)).

## Reactions

A [reaction](live-play.md#reactions) is a code and the moment it was
said at, never words, and the relay holds it to that. It rides only a
table's own tag, and an object refuses one anywhere else or in any other
shape. The codes themselves are not listed in the relay, since a screen
shows only the codes it knows, so a new reaction needs no new relay.

## Watching a table

A watcher's ask and a seated player's answer ride the table's own tag.
The relay forwards both and stores neither, like the rest of a table's
traffic ([watching a live game](live-play.md#watching-a-live-game)).
