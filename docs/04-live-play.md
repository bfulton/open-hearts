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
S."** One code path for the consequences, three ways in.

They differ in what backs the event. A signed Leave is evidence and
needs nobody's agreement. Boot and timeout are *inferences* about
someone's absence, and an inference needs **a strict majority of the
last agreed participant set** behind it — three of four, two of three.
At two humans no majority exists among the players, and that case goes
to the jury, below.

There is no rejoining. Without persistent identity there is nothing to
rejoin as, so a removed player goes back to matchmaking.

## Agreeing that somebody left

Hearts is turn-based, and that dissolves most of what would otherwise be
a hard problem. Exactly one seat may act at a time and the order comes
from the rules, not from who spoke first — so there is no ordering
ambiguity to resolve and no race to arbitrate.

The only genuinely concurrent question is whether someone has gone, which
is why it gets the machinery above and nothing else does.

The majority rule is what stops a partition becoming a fork. Split a
four-human table 2–2 and each half sees the other as silent — but each
half holds two of four, neither has a majority, neither evicts anyone,
and neither reconstructs anything. Both halves wait. That is the right
outcome for a genuinely symmetric event: nobody left, so nobody is
replaced. Split it 3–1 and the three proceed correctly.

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
same as reconstructing one. The hand goes in as fragments that are never
reassembled; the computation runs the bot policy over them and outputs
one card. Only that card leaves, and it was going face up anyway. So the
survivors collectively hold a departed hand and individually know
nothing about it.

**What goes in.** Not the ciphertexts. Decrypting inside the computation
would mean elliptic-curve arithmetic gate by gate — hundreds of millions
of gates per card — and the count below is what rules that out. Instead,
at the deal, once a player has opened their thirteen cards, they
secret-share the *plaintext* — which card sits at each of their thirteen
positions — among the other three, alongside a share of their decryption
key. The hand shares feed the policy. The key shares let the survivors
open a position in public, each contributing its part of the decryption
without anyone reassembling the key. The policy answers with a position,
the survivors open it, and the card that appears is the play.

A leaver who shared a false hand is caught, not accommodated. The bot
plays from what it was given, the opened card is what was really there,
and at the end of the hand — when every hand is revealed for the audit
[doc 03](03-fair-deal.md) describes — the two disagree, provably,
against a player who already took the rating loss for leaving. Until
then the worst case is one bot playing the cheater's own seat a little
wrong.

**The policy as a circuit.** `packages/engine/lib/src/oblivious.dart` is
the bot rewritten without a branch on secret data, and its test proves
it picks the same card as the bot on every decision of forty games.
Counted, in AND gates — what a garbled circuit costs; XOR is free:

| | AND gates |
|---|---|
| one play, legality included | 1,234 |
| the same, hand in as thirteen dealt positions and position out | 2,313 |
| one pass | 8,796 |
| a bot seat for a whole hand: one pass and thirteen plays | 38,865 |

At two ciphertexts per gate a play is about 75 KB and a whole hand about
1.2 MB; malicious security multiplies that by a small constant. Small
enough that the material for a hand travels while the previous one is
played, and that the precomputation below is seconds of background work.

**The parties are the humans at the table, and only them.** Adding the
service as a third party would buy a cheaper protocol — honest-majority
protocols are far faster — but it would also mean the service colluding
with one player could defeat another, and that coalition excludes someone
who gets hurt. Keeping the parties to the humans means any coalition able
to open a hand contains every human at the table, and then there is
nobody left to defraud. That is the same guarantee the deal itself makes.

The parties shrink with the table, down to a floor of two:

| Table | Who must not see bot hands | Parties |
|---|---|---|
| 4 humans | no bots exist | — |
| 3 humans + 1 bot | each human | the three humans |
| 2 humans + 2 bots | each human | the two humans |
| 1 human + 3 bots | the human | the human **and the foreman** |

A lone human is never a lone party. The foreman — a stranger drawn at
random from elsewhere, with no stake in the table — takes the departed
player's place as a computing party, so the survivor never holds a bot
hand and cannot see one, however their client has been modified. That
is what makes [doc 03](03-fair-deal.md)'s guarantee unconditional.

Departures require re-sharing among the survivors, and the material for
the next configuration is precomputed one hop ahead so a departure does
not stall the table. Preprocessing is input-independent — it reveals
nothing and cannot be opened — so it is safe to distribute in advance,
which a hand would not be. The hand shares themselves are re-shared one
hop ahead too, and the extra share goes to the jury, never to a
survivor: two survivors holding enough between them to carry on without
a third could open the hand without them as well. If two people go
inside the same window the table pauses for a beat while it catches up;
that is a moment to design, not an error.

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

## The jury

Two of the cases above cannot be settled by the players alone. At **two
humans**, a silent player leaves the other with one vote of two — no
majority, and from the inside a rage quit and a partition look the same.
At **one human**, there is nobody to be the second MPC party. Both need
one thing: a party with no stake in the table.

So every hand seats a **jury**: a small number of players drawn at random
from whoever is online at other tables. Each juror holds a share of the
hand's key material — useless alone — and connects to all four seats at
the start of the hand. One is **foreman**, chosen by the deal's own
randomness (which every party has already verified), with the others in
a deterministic order behind them.

**Random, not ranked.** Any selection criterion an attacker can optimise
becomes a lever, and uptime or latency are trivially optimised by running
a node. Random draw from purchase-backed identities offers no lever; a
juror with a bad connection is simply disqualified and redrawn. Random
selection across unrelated networks also keeps juror failures
independent, which the sizing below depends on.

**Per hand, not per game.** The deck is resealed every hand, so shares
are per-hand and a juror's whole obligation is one hand — p50 a minute,
p90 two. Short enough to ask of a stranger, and short enough that an
attacker who does get selected has a couple of minutes of relevance.

**The tiebreak.** At two humans, A reports that B has gone silent. The
foreman checks for itself: it connected to B at the start of the hand and
knows whether that route still works. If B is reachable, A is told to
wait — it is a partition, not a departure. If not, B is gone. A rage quit
is offline from every juror's perspective, so every juror agrees and the
survivor continues. Only a partition that also splits the jury can
produce two answers, and that degrades to a detectable fork rather than a
silent one.

**The second party.** At one human, the foreman steps into the MPC in
the departed player's place. Survivor and foreman compute each bot move
together, for the rest of the hand, and neither sees a card. If the
foreman drops, the next juror in order already holds the share and takes
over at the next move.

**Size.** The jury fails only if every juror leaves inside one
replacement window — the ten seconds or so it takes to notice a drop,
redraw, and distribute a share. With sessions of one game and a p90
two-minute hand, four jurors put that around 10⁻⁵ per hand; with
players staying for two or three games it is nearer 10⁻⁶. **k = 4**,
and the number to make small is the replacement window, which enters
as (λT)ᵏ. Halving it is worth more than a fifth juror.

**If the jury is lost anyway**, the table pauses, says so, and resumes
when one is rebuilt. Nobody at the table controls whether strangers
elsewhere go offline, so the pause is not a lever.

**Juror of last resort.** When a table cannot draw a jury — because too
few people are online — it says so, and a client we manage comes online
to serve. It is the same code every other juror runs, holds the same
kind of share, does the same one hand, and knows nothing else. Its cost
scales inversely with the player base: it runs when the room is empty
and never otherwise. This is the only place a gameplay event reaches
anything of ours, and what it carries is "a table needs a juror."

**The draw is verifiable.** The four at the table agree a snapshot of
who is online, and apply the deal's own randomness to it. Nobody at the
table can steer the draw, and nobody outside it can either.

## What the jury does not change

Everything a juror holds is a share. A juror alone can open nothing.
Together with a player at the table, a juror can help play a seat that
seat's owner abandoned — and that is the whole of it. To break a hand
you need a juror colluding with a player at that specific table, which
means being drawn at random for it, for the one hand it matters, and
having arranged the collusion in advance. Bounded, and expensive to
target.

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

## Presence and matchmaking

There is no presence server. Every online client publishes a signed,
short-lived event to a well-known relay topic every few seconds —
*identity, status, region* — and everyone subscribes. At hundreds online
that is a few dozen tiny events per second per client.

**Forming a table** is the one place eventual consistency bites: seekers
see each other through relays that deliver in different orders, so two
seekers can compute different groupings. The rule is time-windowed
batching. Everyone who announced in the same short window groups
deterministically by sorted identity. No rounds, no votes. If your
group-mates saw a different set, the connection fails and you fall
through to bots — a split brain degrades to "you got bots" rather than
to a hang. Costs a second or two inside the ten-second window.

**One device at a time** is cooperative here: a newer attestation
appears on the topic and the older device signs itself out. An honest
client does; a modified one could ignore it and be at two tables at
once, which random matchmaking makes hard to turn into anything.

What decentralising presence buys is that the game keeps working if we
vanish. What it costs is the second or two above and the honour-system
device rule. Fairness was never at stake either way — a presence server
could refuse to match you, but never see a card.

## Identity

An identity is a keypair generated on the device, in Nostr's format. The
public key is what appears in every public record — plays, ratings, jury
draws. It is opaque, and nothing links it to who you are.

**Sign-in attests it.** Live play needs Sign in with Apple or Google.
The service verifies the token, checks that this provider account is not
already bound to a different key, and issues a signed attestation:
*"this key is backed by a provider account."* Not which one. The
provider's identifier never leaves the service, and no email is stored
at all — neither of our uses needs one.

**Losing a device is a supersession.** Sign in on the new one, generate
a fresh key, and the service — seeing the same provider account — signs
*"new key supersedes old."* Ratings and entitlement attach to the chain,
so everything follows you. Within a platform the key syncs through the
keychain and nothing is needed; a cross-platform move is a supersession.

The player sees none of this. Sign in, and you have an identity. There
is no key to look at and no export — the word Nostr appears nowhere in
the app.

## What the service does

Five stateless handlers and a small key-value store:

| | |
|---|---|
| attest | verify a sign-in token, enforce one provider account per key, sign the attestation |
| supersede | same sign-in, sign the supersession link |
| entitle | receive the purchase webhook, mark the key entitled, issue a signed licence |
| turn-creds | mint short-lived TURN credentials |
| last-resort | bring a juror online when a table reports it could not draw one |

It never holds a card, never signs a play, never adjudicates anything,
never sees who is at which table, and is not required by a table already
in progress. Every handler is a point lookup and a signature.
[Doc 06](06-service.md) has the storage, the local mode, and the layout.

## Still open

- **Chat.** None. Text between strangers is a moderation surface and
  Hearts does not need one. Whether a fixed set of table gestures earns
  its place is worth revisiting.
- **Collusion.** Two players sharing hands out of band beat everything
  here. With nothing at stake it is small; it is a reason not to give the
  game stakes.
