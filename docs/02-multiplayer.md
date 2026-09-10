# 02 — Multiplayer without a server

> **Revised by [doc 04](04-live-play.md).** This document assumed players
> arrive at a table by invitation. They don't — they are matched with
> whoever wants a game right now. Presence and matchmaking ride the same
> relays as signalling, so the conclusion below survives whole: there is
> no game server, and a table under way needs nothing from us. What does
> exist is a handful of stateless handlers for sign-in, entitlement and
> TURN credentials, described in [doc 06](06-service.md). TURN itself is
> Cloudflare's; signalling is public Nostr relays, unchanged.

**Question.** Can four people play a real-time game of Hearts with no
game server, no hosting bill, and sub-second latency?

**Answer.** Yes, and the latency is the easy half. The transport is
WebRTC data channels between the four players; the only thing that ever
needs a third party is the introduction, and public relays do that for
free. The hard half is fairness, which gets its own document
([03 — A deal nobody can rig](03-fair-deal.md)).

The stack is off-the-shelf: [Trystero](https://github.com/dmotz/trystero)
over public Nostr relays for signalling, WebRTC data channels for the
interior. It is a well-trodden path, not a technique to invent.

## The shape

```
        signalling (once, at join)          play (every trick)
   ┌──────────────────────────────┐   ┌──────────────────────────┐
   │  public Nostr relays         │   │  WebRTC data channel     │
   │  ~200-800 ms, free, volunteer│   │  direct peer to peer     │
   │  used to trade SDP + ICE     │   │  20-150 ms typical RTT   │
   └──────────────────────────────┘   └──────────────────────────┘
```

Signalling is how two browsers that have never met exchange the
connection offers WebRTC needs. It is a handful of small messages, once,
when someone joins a table. After that the relays are out of the path
entirely and every card played travels directly between players.

Four players is a 6-edge mesh — three connections each. There is no
scaling problem to solve here at all.

## Latency, honestly

| Hop | Typical | Worst realistic |
|---|---|---|
| Direct data channel, same continent | 20–60 ms | 150 ms |
| Direct, intercontinental | 120–200 ms | 300 ms |
| Via TURN relay | +20–80 ms | +150 ms |
| Via a Nostr relay lane (fallback) | 150–400 ms | 800 ms |

A trick-taking game asks for one message per play. Even the worst row
clears a second. Latency is not the risk.

## The one thing that costs money, and how to avoid it

STUN gets a direct connection through most NATs. Roughly 10–20% of
connection *pairs* sit behind symmetric NAT or restrictive corporate
firewalls and need a **TURN relay**, which is a real server relaying real
bytes, and therefore a real bill. STUN itself is free (Google's public
STUN servers, among others); TURN is not.

Three ways out, in the order they should be tried:

1. **Take the free path when it works.** 80–90% of tables never need
   TURN at all.
2. **Fall back to a relay lane.** When ICE fails, keep playing over the
   signalling relays: encrypt each game event to the table and publish it
   as a relay message. Adds a couple of hundred milliseconds, costs
   nothing, and Hearts is turn-based enough not to care. The same relays
   are already open for signalling, so the lane is a use of the transport
   rather than a new one.
3. **Only then, paid TURN.** Cloudflare Realtime sells TURN with a free
   monthly allowance. Worth keeping as an option; not worth building on.

The honest caveat about (2): public Nostr relays are volunteer
infrastructure with rate limits and no uptime promise. Depending on them
for the *fallback* path is a reasonable bet. Depending on them for the
*primary* path would not be — which is why the primary path is a direct
connection that needs nobody.

## Who is in charge

There is no leader to elect, and this is worth being precise about,
because it is the usual reason people reach for a server.

The rules engine (`app/lib/engine/`) is pure and deterministic. Every
player runs it. At any moment exactly one seat may legally act, and every
other player can check the action against the same rules that produced
it. A play that is not legal is not rejected by an authority — it is
simply not accepted by anybody, because nobody's copy of the rules
accepts it. That is why the engine has no Flutter imports, no clock, and
no I/O: so it can be the shared referee.

What genuinely needs an owner is **membership** — who is at the table,
and what happens when someone's phone goes into a tunnel. That does not
need an election protocol either. The player who created the table owns
membership; if they drop, ownership falls to the surviving player with
the lowest peer id. Deterministic, unanimous, and no votes.

## What this does not solve

- **Collusion.** Two players on a phone call, sharing hands, cannot be
  stopped by any protocol. Private tables among people you know are the
  real answer; for public play, the answer is statistics after the fact.
- **A player who quits mid-hand.** A protocol problem, not a crypto one:
  timeouts, and a rule for scoring an abandoned hand.
- **A player running a solver.** Also unsolvable, also not new — it is
  the same problem every online card game has.

## Sequencing

1. Local play against bots — **done**.
2. Two devices, one table, direct WebRTC, with the shared rules engine as
   the only referee. The spike that proves the transport and the
   shared-referee model.
3. The verifiable deal from [doc 03](03-fair-deal.md).
4. Matchmaking and the rendezvous service ([doc 04](04-live-play.md)).
5. The relay-lane fallback.

Steps 2 and 3 are independent of 4: a hand-wired table between two
devices proves everything about the transport without anyone needing to
be matched.
