# 02 — Multiplayer without a game server

**Question.** Can four people play a real-time game of Hearts with no
game server and sub-second latency?

**Answer.** Yes, and the latency is the easy half. Cards travel over
WebRTC data channels between the players; the only thing that needs a
third party is the introduction, which our own relay
(`relay.openhearts.game`, [doc 08](08-own-relays.md)) does. The hard
half is fairness, which has its own document
([03 — A deal nobody can rig](03-fair-deal.md)). How a table is formed
and how it agrees on every turn is [doc 04](04-live-play.md).

## The shape

```
        signalling (once, at join)          play (every trick)
   ┌──────────────────────────────┐   ┌──────────────────────────┐
   │  our relay, one object a tag │   │  WebRTC data channel     │
   │  trades SDP + ICE            │   │  direct peer to peer     │
   │  and is the fallback lane    │   │  20-150 ms typical RTT   │
   └──────────────────────────────┘   └──────────────────────────┘
```

Signalling is a handful of small messages when someone joins; after
that every event travels directly between devices. The mesh is the four
seats plus the hand's jurors — strangers drawn to break deadlocks and
hold bot seats ([doc 04](04-live-play.md)). A juror is introduced by a
summons over the relay and then dialled like a seat. It dials the seats,
not its fellow jurors, since what passes between jurors is a few small
events a hand.

## Latency

| Hop | Typical | Worst realistic |
|---|---|---|
| Direct data channel, same continent | 20–60 ms | 150 ms |
| Direct, intercontinental | 120–200 ms | 300 ms |
| Via TURN | +20–80 ms | +150 ms |
| Via the relay lane | 150–400 ms | 800 ms |

A trick-taking game sends one message per play. Even the worst row
clears a second.

## When a direct connection fails

STUN gets a direct connection through most NATs. Roughly 10–20% of
connection pairs sit behind symmetric NAT or a strict firewall and need
TURN, which relays real bytes and so costs money. In order:

1. **Direct, when it works** — most pairs.
2. **TURN** — Cloudflare's, with short-lived credentials from the
   service's turn handler (`app/lib/net/turn.dart`,
   [doc 06](06-service.md)). Without credentials, a STUN server still
   gives every peer its public address.
3. **The relay lane** — while anyone a device must reach has no channel
   open, events also go to the relay as signed JSON
   (`app/lib/net/mesh_transport.dart`). A dial unanswered in twenty
   seconds is left to the lane and retried after a minute, then two,
   four, up to a quarter of an hour. A table whose channels are all up
   costs the relay its presence and signalling and nothing else.

## Who is in charge

Nobody. The rules engine (`packages/engine`) is pure and deterministic,
with no Flutter imports, clock or I/O, and every device runs it. Exactly
one seat may act at a time, and every other device checks the action
against the same rules: an illegal play is not rejected by an authority,
it is accepted by nobody.

What does need deciding is membership: who is still at the table when a
phone goes into a tunnel. That is settled per turn by a majority of the
people at it, and by the jury where no majority exists
([doc 04](04-live-play.md), [doc 07](07-states.md)). There is no
leader to elect.

## What this does not solve

- **Collusion.** Two players sharing hands out of band cannot be stopped
  by any protocol.
- **A player running a solver.** The same problem every online card game
  has.
