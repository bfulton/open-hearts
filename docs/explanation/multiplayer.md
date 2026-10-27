# Multiplayer through a referee

**Question.** How do four devices, anywhere, play one game of Hearts
in real time, with nobody able to change what happened?

**Answer.** Each device holds one connection to the table's referee, an
object of its own on [our relay](relay.md), which puts everything said
at the table in one order and stamps it with one clock. Every device
applies the same rules to that log, so they all come to the same
table, and nothing they could say to each other could make them come to
another. The latency is the easy half. The hard half is fairness, which
has its own page, [the fair deal](fair-deal.md). How a table is formed,
how its turns go and what happens when people leave is
[live play](live-play.md).

## The shape

```
   a person's device ──┐
   a person's device ──┤      ┌──────────────────────────────┐
   a person's device ──┼──────│  the table's referee          │
   a person's device ──┤      │  one object, one log, one     │
             the house ┘      │  clock: numbers and stamps    │
                              │  what each side says, sends   │
                              │  every entry to every side    │
                              └──────────────────────────────┘
```

A table is its referee's log. Each side, a person's device or the
house, says what it says to the referee and reads the log back, from
the first entry it has not had, on one socket. The referee checks only
who said an event and that it is said once; the rules every side runs
decide what it means. There is no connection between devices, and no
device learns another's address.

Outside the table the relay carries what every live player shares: the
pools where devices wait to be seated, friends' rooms, who is online,
the results the ratings are folded from, and the pictures and names a
table shows ([the relay](relay.md)).

## Latency

Rough estimates for each hop, not measurements:

| Hop | Typical | Worst realistic |
|---|---|---|
| A device to the table's object, same continent | 20–60 ms | 150 ms |
| A device to the table's object, another continent | 100–200 ms | 400 ms |

A card is two hops: the player's device to the referee, and the
referee to everybody else. A trick-taking game sends one event per
play, so even the worst row clears a second. The object lives where the
table first connected to it, and every side reaches that one place.

## Who is in charge

The rules. The engine (`packages/engine`) is pure and deterministic,
with no Flutter imports, clock or I/O, and so are the table's rules
over the log (`packages/table`, `rules.dart`); every side runs them.
Exactly one seat may act at a time, and every side checks each event
against the same rules: an illegal play is not rejected by an
authority, it is taken by nobody, and stays in the log changing
nothing.

What a table cannot do without somebody is order what happens and keep
time, which is the referee's whole job: it decides nothing else. And a
sealed table's bots need somebody to hold their secret cards who is not
a player: that is the house, the operator's own side at every table
([the house](live-play.md#the-house)). The referee and the house are
ours, so a table needs our service while it is played. Neither can
change a card: every event is signed by the side that said it, and
anyone can check a kept game, every entry of its log, after the fact.

## Through TURN, never direct

Nothing of a game goes over WebRTC. Voice and video among friends are
planned (`ROADMAP.md`), and the pieces for them are kept: a call will
go between devices over WebRTC through Cloudflare's TURN and nowhere
else (`iceTransportPolicy: 'relay'`), so that nobody on a call learns
another's address. The credentials are short-lived, from the service's
turn handler (`app/lib/net/turn.dart`, [the service](service.md#turn)).
TURN is billed by the gigabyte delivered, and carrying every byte of a
call through it costs little.

## What this does not solve

- **Collusion.** Two players sharing hands out of band cannot be stopped
  by any protocol.
- **A player running a solver.** The same problem every online card game
  has.
