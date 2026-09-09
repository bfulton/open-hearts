# 04 — Live play

The design of the multiplayer game. How the deal stays honest is
[doc 03](03-fair-deal.md); how the bytes move is
[doc 02](02-multiplayer.md).

Solo play against bots is free on every platform. Live play requires a
purchase, and everyone at a live table has made it — there is no guest
seat and no free tier to design around.

## The shape of it

You open the app, tap **Play**, and you are in a game. Not a lobby, not a
list of rooms, not an invite to send. Seconds, not minutes.

That is the whole product decision, and everything below follows from it.
Hearts is a game people play in the gaps of a day; anything that puts a
waiting room between the intent and the cards loses to the app that
doesn't.

Four seats. Humans as they arrive, bots for the rest.

## The empty room

At the start almost every table will be one human and three bots, because
that is what low liquidity looks like. The usual fix is to hide it —
give the bots plausible usernames and let people assume.

**We don't, ever.** A bot seat says it is a bot, in the same place a
person's name would be. This is not a scruple, it is the product: the
thing that distinguishes this app is that it does not lie to you about
what is happening at the table, and an app that fakes its opponents has
already conceded the argument it is trying to win.

Being honest here is cheaper than it looks. The bots are decent, a game
that starts instantly beats a lobby that never fills, and "three bots,
right now" is a better offer than most of the category manages. As
liquidity grows the bots recede on their own.

## Filling and emptying seats

**A human joining takes a bot's seat at the next hand boundary, never
mid-hand.** Mid-hand, they would inherit a position and a hand shaped by
decisions they did not make, and — worse — inherit knowledge of thirteen
cards from whoever was holding that seat.

**A human leaving is replaced by a bot immediately, mid-hand.** The
opposite rule, for the opposite reason: three people should not lose a
game because a fourth got on a train.

## Abandonment

Strangers leave. That is not misbehaviour, it is the medium.

Each turn has a clock. On timeout the bot plays that seat's card, and the
player can pick the seat straight back up. Miss enough turns in a row and
the bot keeps the seat and the player is out of the table.

No penalties, no reputation, no ranked ladder. All of that needs
persistent identity, which we do not have and have not decided to want.

## Who runs the bots

This is the one place where "fill empty seats with bots" and "nobody can
see anyone else's cards" genuinely collide, and it is worth stating
plainly before it is built.

A bot seat holds thirteen secret cards. Under the verifiable deal, some
party must hold the key to open them, or the bot cannot play. If that
party is one of the players, that player sees a hand they should not —
in a four-handed game where thirteen cards is a quarter of the
information, that is not a rounding error.

The resolution is that **bot seats are held by the rendezvous service,
which does not play.** It is the only neutral party available in a
four-seat game, and the arrangement is narrow enough to be safe:

- it holds bot hands only, so it cannot see a human's cards;
- the bot's policy is deterministic and public, so its play can be checked;
- each bot hand is revealed when the hand ends, and anyone can replay it
  against the published policy and see that the bot played what the
  policy says.

So the service cannot learn anything private and cannot help anyone
without leaving evidence. This needs validating against the protocol
before it is relied on, but it is the shape we expect.

## What the rendezvous service is

[Doc 02](02-multiplayer.md) argued for zero hosting, and the argument
holds for the part that matters: **gameplay stays peer to peer.** Cards
travel directly between players, which is where the latency and the
bandwidth bill would otherwise be, and the verifiable deal means no
server is a trust anchor.

But matchmaking is not signalling. It needs presence — who is waiting,
right now — and that is a poor fit for public relays, which are
volunteer infrastructure with rate limits. Live play also has to be
purchased on the web, which needs somewhere to receive a payment
webhook.

So there is a small service. It does three things:

1. puts four players who want a game into the same table;
2. holds the bot seats, as above;
3. records who has bought live play.

It never sees a human's cards, never decides whether a play is legal,
and never holds game state. A table already in progress survives it going
down.

That is a smaller claim than "no servers at all," and it is the honest
one. The p2p architecture is still doing the work it was chosen for; it
is not being asked to do rendezvous out of principle.

## Still open

- **Identity.** Matchmaking among strangers wants some persistence —
  to reconnect to your own table, at minimum. Accounts were ruled out.
  What the smallest thing is that reconnects a player without becoming
  an account is not settled.
- **Chat.** None in the first version. Any text between strangers is a
  moderation surface, and Hearts does not need one. Whether a fixed set
  of table gestures earns its place is worth revisiting.
- **Collusion.** Two players sharing hands out of band beat every
  protocol here. With nothing at stake it is a small problem; it becomes
  a real one only if the game ever acquires stakes, which is a reason not
  to give it any.
