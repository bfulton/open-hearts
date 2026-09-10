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

That is the whole product decision and everything below follows from it.
Hearts is played in the gaps of a day, and anything that puts a waiting
room between the intent and the cards loses to the app that doesn't.

Matchmaking waits about ten seconds for other people. When the window
closes, bots take whatever seats are still empty and the deal runs. Four
seats, always.

## The empty room

At the start almost every table will be one human and three bots, because
that is what low liquidity looks like. The usual fix is to hide it — give
the bots plausible usernames and let people assume.

**We don't, ever.** A bot seat says it is a bot, where a person's name
would go. This is not a scruple, it is the product: what distinguishes
this app is that it does not lie to you about what is happening at the
table, and an app that fakes its opponents has already conceded the
argument it exists to win.

Tables keep filling. Arriving players take bot seats at hand boundaries,
so a table that starts at one human and three bots may be three and one
by the fourth hand. The state is always on screen — how many seats are
bots, and a note when somebody sits down.

## Filling and emptying seats

**A human joining takes a bot's seat at the next hand boundary, never
mid-hand.** Mid-hand they would inherit a position shaped by decisions
they did not make and — worse — inherit knowledge of thirteen cards from
whoever was holding that seat.

**A human leaving is replaced by a bot immediately, mid-hand.** The
opposite rule for the opposite reason: three people should not lose a
game because a fourth got on a train.

## Leaving, through three doors

Strangers leave. That is not misbehaviour, it is the medium, and the
design assumes it rather than penalising it.

**Explicit.** A Leave button, and the event is signed by the leaver so
nobody can forge one for someone else, and relayed by whoever receives it
so a partial delivery still converges.

A graceful leave does something the other two doors cannot: the leaver
takes part in one final re-share before disconnecting, handing their
seat's future to the survivors directly instead of leaving them to
reconstruct it. That is a real reason to make Leave easy and obvious
rather than buried — the polite exit is also the cheap one.

**Boot.** Fifteen seconds after a turn begins, a Boot button appears next
to that seat. The first person to press it removes the player.

The button is a **trigger, not a vote.** The condition is objective — the
turn began at a known game state and fifteen seconds elapsed — and every
peer runs the same clock derived from that state rather than from wall
time. So a boot broadcast is countersigned by the others in milliseconds,
because they already agree. First press wins, and the protocol underneath
is still unanimous.

A peer that holds a signed play for that seat and turn must **rebroadcast
the play instead of countersigning.** That covers the case where the
player did act and one peer missed it, and it makes the boot attempt the
repair mechanism for a dropped message. Same rule gives the tiebreak for
a play at 14.9 seconds: a valid signed play for turn T voids any boot for
turn T.

The player being booted sees their own countdown. Someone on a bad
connection who is genuinely present deserves to know.

**Timeout.** Transport-level disconnects (WebRTC surfaces these within a
few seconds) plus an application heartbeat for the connected-but-wedged
case, which is usually a backgrounded tab.

This one matters more than it looks. A silent player who has not yet been
evicted **blocks the table even when it is not their turn**, because they
are a required party to the computation that plays the bot seats. Someone
pocketing their phone during another player's turn is enough to wedge
things. The timeout is what prevents that, so it is load-bearing rather
than hygiene.

Longer than the boot clock — say thirty seconds of silence against
fifteen on-turn — so an active table always resolves through the visible,
explicable path and the timeout only catches what boot cannot see.

All three doors produce the same event: **"seat N is out as of game state
S,"** signed by the surviving set. One code path for the consequences,
three ways in.

There is no rejoining. Without persistent identity there is nothing to
rejoin as, so a removed player goes back to matchmaking.

## Agreeing that somebody left

Hearts is turn-based, and that dissolves most of what would otherwise be
a hard problem. Exactly one seat may act at a time and the order comes
from the rules, not from who spoke first — so there is no ordering
ambiguity to resolve and no race to arbitrate.

The only genuinely concurrent question is whether someone has gone, which
is why it gets the machinery above and nothing else does.

Belt and braces: the game state is hash-chained. Every play appends to a
log and each player signs the resulting hash, so a peer whose hash
diverges knows immediately and halts rather than playing on into a fork.
Since turn order is fixed by the rules, a mismatch means a genuine fault
and is worth stopping for.

## Playing a seat nobody holds

A bot seat holds thirteen secret cards. Somebody must be able to open
them or the bot cannot play — and nobody may learn them.

Both are satisfied by **secure multi-party computation**, and the
distinction that makes it work is that computing on a secret is not the
same as reconstructing one. At the deal, each player secret-shares their
own decryption key among the others. The fragments are never reassembled;
they go in as inputs, and the computation internally reconstructs the
key, decrypts the hand, runs the bot policy and outputs one card. Only
that card leaves, and it was going face up anyway.

So the survivors collectively hold a departed hand and individually know
nothing about it.

**The parties are the humans at the table, and only them.** Adding the
service as a third party would buy a cheaper protocol — honest-majority
protocols are far faster — but it would also mean the service colluding
with one player could defeat another, and that coalition excludes someone
who gets hurt. Keeping the parties to the humans means any coalition able
to open a hand contains every human at the table, and then there is
nobody left to defraud. That is the same guarantee the deal itself makes.

The requirement falls away as the table empties:

| Table | Who must not see bot hands | What runs |
|---|---|---|
| 4 humans | no bots exist | nothing |
| 3 humans + 1 bot | each human, individually | 3-party MPC |
| 2 humans + 2 bots | each human, individually | 2-party MPC |
| 1 human + 3 bots | nobody — see below | plain local computation |

The floor needs no protection because there is no second human to
disadvantage. Which also means a cascade of departures lands in the
configuration that needs no cryptography at all — fast, multiple
departures make this easier rather than harder.

Departures require re-sharing among the survivors, and the material for
the next configuration is precomputed one hop ahead so a departure does
not stall the table. Preprocessing is input-independent — it reveals
nothing and cannot be opened — so it is safe to distribute in advance,
which a hand would not be. If two people go inside the same window the
table pauses for a beat while it catches up; that is a moment to design,
not an error.

## Why there is no service in any of this

The bot is deterministic and its policy is public. The deal is committed
at shuffle time — the encrypted deck and the seat assignments are public
and signed by all four players — so every hand is fixed and unforgeable
from the deal onward even while hidden.

Together those mean **a bot's play is a computable consequence, not a
claim anyone has to be believed about.** When the hands are revealed at
the end of a hand, anyone can recompute every bot play and check it.

The same argument covers human plays: each must be a card from a
committed hand and legal under the rules. So the whole game record
verifies end to end, by anyone, against the committed deal. A forged
chain does not need to be prevented — it fails the check.

Which is why there is no witness, no arbiter and no server in the game.
Not as a principle we are defending, but because the determinism of the
bot and the commitment of the deal make one unnecessary.

## The one thing that cannot be prevented

A player left alone with three bots holds every hand, because there is no
second party to hold anything with. They can see the bot cards.

No human's cards are ever visible to another human — the three seats they
can see are bots — so the privacy guarantee between players is intact.
But that player can play the rest of the game with information a real
opponent would not have, and under the scoring rules below, a win moves
other people's ratings.

There is no fix for this that survives contact. Computational cost does
not work, because the advantage is informational and free. Proving plays
happened in real time does not work, because the advantage is used at
normal speed. Denying the information needs a second party we removed on
purpose. And every scheme that scores the game early to avoid the state
lets a *winning* player leave and bank it.

So it stands, disclosed: **if you would rather the last player standing
did not have that, do not leave.** What bounds it in practice is that
exploiting it means writing a modified client, and it only pays in games
that drained to one human before ending — which should be instrumented
rather than assumed.

## Scoring

Each game produces a record: the committed deal, every signed play, and
the revealed hands. Ratings are computed from that record by anyone; no
authority holds them.

Two rules:

- **A bot in the winning seat means nobody's rating moves.** A win by a
  seat its owner abandoned is not evidence about anybody, and the players
  who stayed should not be marked down because a bot beat them.
- **A live player winning moves everyone**, up for them and down for the
  other three, including anyone who left.

Leaving is therefore never an escape and never an upside. There is no
abandonment penalty to calibrate, which matters because **a rage-quit and
a dead battery are indistinguishable** and any explicit penalty would
land on both.

Nobody needs to sign a result. The scores are a deterministic function of
the signed play chain, so there is no end-of-game ceremony for a leaver
to withhold — which would have handed a veto to exactly the player most
motivated to use it.

## What the service does

Matchmaking, and recording who has bought live play on the web.

It never holds a card, never signs a play, never adjudicates anything,
and is not required by a table already in progress.

## Still open

- **Identity.** Matchmaking among strangers wants some persistence, and
  ratings need it. A device keypair is the shape; keys are cheap, which
  makes ratings work (you keep a good one) and bans useless (you discard
  a bad one). What the smallest useful thing is has not been settled.
- **Chat.** None. Text between strangers is a moderation surface and
  Hearts does not need one. Whether a fixed set of table gestures earns
  its place is worth revisiting.
- **Collusion.** Two players sharing hands out of band beat everything
  here. With nothing at stake it is small; it is a reason not to give the
  game stakes.
