# Multiplayer without a game server

**Question.** Can four people play a real-time game of Hearts with no
game server and sub-second latency?

**Answer.** Yes, and the latency is the easy half. Cards travel over
WebRTC data channels between the players; the only thing that needs a
third party is the introduction, which [our own relay](relay.md) does.
The hard half is fairness, which has its own page,
[the fair deal](fair-deal.md). How a table is formed and how it agrees
on every turn is [live play](live-play.md).

## The shape

```
        signalling (once, at join)          play (every trick)
   ┌──────────────────────────────┐   ┌──────────────────────────┐
   │  our relay, one object a tag │   │  WebRTC data channel     │
   │  trades SDP + ICE            │   │  peer to peer, via TURN  │
   │  and is the fallback lane    │   │  every play, every event │
   └──────────────────────────────┘   └──────────────────────────┘
```

Signalling is a handful of small messages when someone joins; after
that every event travels between devices over their data channels. The mesh is the four
seats plus the hand's jurors: strangers drawn to break deadlocks and
hold bot seats ([live play](live-play.md)). A juror is introduced by a
summons over the relay and then dialled like a seat. It dials the seats,
not its fellow jurors, since what passes between jurors is a few small
events a hand.

## Latency

Rough estimates for each hop, not measurements:

| Hop | Typical | Worst realistic |
|---|---|---|
| Data channel through TURN, same continent | 20–60 ms, plus 20–80 ms for TURN | 150 ms, plus 150 ms |
| Through TURN, intercontinental | 120–200 ms, plus 20–80 ms | 300 ms, plus 150 ms |
| Via the relay lane | 150–400 ms | 800 ms |

A trick-taking game sends one message per play. Even the worst row
clears a second.

## Through TURN, never direct

A peer never learns another's address: not the players', and not the
jurors', who are strangers. Every data channel goes through Cloudflare's
TURN (`iceTransportPolicy: 'relay'`), with short-lived credentials from
the service's turn handler (`app/lib/net/turn.dart`,
[the service](service.md)), so the browser gathers no address of its own
to send. TURN is billed by the gigabyte delivered, and a game is at
most a few tens of megabytes, so carrying every channel through it costs
little. In order:

1. **TURN**: every channel, wherever the credentials are in hand.
2. **The relay lane**: while anyone a device must reach has no channel
   open, events also go to the relay as signed JSON
   (`app/lib/net/mesh_transport.dart`). A dial unanswered within the
   mesh wait (`meshAnswer`,
   [remote config](../reference/configuration.md)) is left to the lane
   and dialled again after a minute, then two, four and eight, and then
   every sixteen. A table whose channels are all up
   costs the relay its presence and signalling and nothing else. With
   no TURN credentials a device makes no channels at all, and the lane
   carries its table.

The browser suites run the same way, against a TURN server of their
own on the machine ([testing](testing.md)).

## Who is in charge

Nobody. The rules engine (`packages/engine`) is pure and deterministic,
with no Flutter imports, clock or I/O, and every device runs it. Exactly
one seat may act at a time, and every other device checks the action
against the same rules: an illegal play is not rejected by an authority,
it is accepted by nobody.

What does need deciding is membership: who is still at the table when a
phone goes into a tunnel. That is settled per turn by a majority of the
people at it, and by the jury where no majority exists
([live play](live-play.md), [table states](table-states.md)). There is no
leader to elect.

## What this does not solve

- **Collusion.** Two players sharing hands out of band cannot be stopped
  by any protocol.
- **A player running a solver.** The same problem every online card game
  has.
